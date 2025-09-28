const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const client_mod = @import("mod.zig");
const client_state = @import("state.zig");
const client_errors = @import("errors.zig");
const webtransport = @import("webtransport.zig");
const http = @import("http");
const wt_capsules = http.webtransport_capsules;

const ClientError = client_errors.ClientError;
const FetchState = client_mod.FetchState;

pub fn Impl(comptime ClientType: type) type {
    return struct {
        const Self = ClientType;

        pub fn openWebTransport(self: *Self, path: []const u8) ClientError!*webtransport.WebTransportSession {
            if (self.state != .established) return ClientError.NoConnection;
            if (self.server_authority == null) return ClientError.NoAuthority;
            if (path.len == 0) return ClientError.InvalidRequest;

            try Self.ensureH3DatagramNegotiated(self);
            const conn = try self.requireConn();
            const h3_conn = &self.h3_conn.?;

            if (!h3_conn.extendedConnectEnabledByPeer()) {
                return ClientError.H3Error;
            }

            const headers = webtransport.buildWebTransportHeaders(
                self.allocator,
                self.server_authority.?,
                path,
                &.{},
            ) catch {
                return ClientError.H3Error;
            };
            defer self.allocator.free(headers);

            const stream_id = h3_conn.sendRequest(conn, headers, false) catch {
                return ClientError.H3Error;
            };
            self.last_request_stream_id = stream_id;

            const session = self.allocator.create(webtransport.WebTransportSession) catch {
                return ClientError.H3Error;
            };

            const path_copy = self.allocator.dupe(u8, path) catch {
                self.allocator.destroy(session);
                return ClientError.H3Error;
            };

            session.* = .{
                .session_id = stream_id,
                .client = self,
                .state = .connecting,
                .path = path_copy,
                .datagram_queue = std.ArrayListUnmanaged([]u8){},
                .pending_datagrams = std.ArrayListUnmanaged([]u8){},
                .capsule_buffer = std.ArrayListUnmanaged(u8){},
                .streams = std.AutoHashMap(u64, *webtransport.WebTransportSession.Stream).init(self.allocator),
            };

            self.wt_sessions.put(stream_id, session) catch {
                for (session.datagram_queue.items) |buf| self.allocator.free(buf);
                session.datagram_queue.deinit(self.allocator);
                for (session.pending_datagrams.items) |buf| self.allocator.free(buf);
                session.pending_datagrams.deinit(self.allocator);
                session.capsule_buffer.deinit(self.allocator);
                session.streams.deinit();
                self.allocator.free(path_copy);
                self.allocator.destroy(session);
                return ClientError.H3Error;
            };

            var state = FetchState.init(self.allocator) catch {
                _ = self.wt_sessions.remove(stream_id);
                for (session.datagram_queue.items) |buf| self.allocator.free(buf);
                session.datagram_queue.deinit(self.allocator);
                for (session.pending_datagrams.items) |buf| self.allocator.free(buf);
                session.pending_datagrams.deinit(self.allocator);
                session.capsule_buffer.deinit(self.allocator);
                session.streams.deinit();
                self.allocator.free(path_copy);
                self.allocator.destroy(session);
                return ClientError.H3Error;
            };

            state.stream_id = stream_id;
            state.is_webtransport = true;
            state.wt_session = session;
            state.collect_body = false;

            self.requests.put(stream_id, state) catch {
                state.destroy();
                _ = self.wt_sessions.remove(stream_id);
                for (session.datagram_queue.items) |buf| self.allocator.free(buf);
                session.datagram_queue.deinit(self.allocator);
                for (session.pending_datagrams.items) |buf| self.allocator.free(buf);
                session.pending_datagrams.deinit(self.allocator);
                session.capsule_buffer.deinit(self.allocator);
                session.streams.deinit();
                self.allocator.free(path_copy);
                self.allocator.destroy(session);
                return ClientError.H3Error;
            };

            self.flushSend() catch |err| {
                _ = self.requests.remove(stream_id);
                state.destroy();
                _ = self.wt_sessions.remove(stream_id);
                for (session.datagram_queue.items) |buf| self.allocator.free(buf);
                session.datagram_queue.deinit(self.allocator);
                for (session.pending_datagrams.items) |buf| self.allocator.free(buf);
                session.pending_datagrams.deinit(self.allocator);
                session.capsule_buffer.deinit(self.allocator);
                session.streams.deinit();
                self.allocator.free(path_copy);
                self.allocator.destroy(session);
                return err;
            };

            self.afterQuicProgress();
            return session;
        }

        pub fn markWebTransportSessionClosed(self: *Self, stream_id: u64) void {
            if (self.wt_sessions.get(stream_id)) |session| {
                session.state = .closed;
            }
        }

        pub fn cleanupWebTransportSession(self: *Self, stream_id: u64) void {
            if (self.wt_sessions.get(stream_id)) |session| {
                session.state = .closed;
                for (session.datagram_queue.items) |dgram| {
                    self.allocator.free(dgram);
                }
                session.datagram_queue.deinit(self.allocator);
                for (session.pending_datagrams.items) |buf| {
                    self.allocator.free(buf);
                }
                session.pending_datagrams.deinit(self.allocator);
                session.capsule_buffer.deinit(self.allocator);
                var stream_it_cleanup = session.streams.iterator();
                while (stream_it_cleanup.next()) |entry| {
                    _ = self.wt_streams.remove(entry.key_ptr.*);
                }
                session.streams.deinit();
                self.allocator.free(session.path);
                _ = self.wt_sessions.remove(stream_id);
                self.allocator.destroy(session);
            }
        }

        pub fn ensureStreamWritable(self: *Self, stream_id: u64, hint: usize) void {
            const conn = self.requireConn() catch return;
            _ = conn.streamWritable(stream_id, hint) catch {};
        }

        pub fn allocLocalStreamId(
            self: *Self,
            dir: h3.WebTransportSession.StreamDir,
        ) ClientError!u64 {
            switch (dir) {
                .uni => {
                    if (self.next_wt_uni_stream_id == 0) {
                        self.next_wt_uni_stream_id = deriveNextUniStreamId(self);
                    }
                    const stream_id = self.next_wt_uni_stream_id;
                    self.next_wt_uni_stream_id += 4;
                    return stream_id;
                },
                .bidi => {
                    if (self.next_wt_bidi_stream_id == 0) {
                        self.next_wt_bidi_stream_id = deriveNextBidiStreamId(self);
                    }
                    const stream_id = self.next_wt_bidi_stream_id;
                    self.next_wt_bidi_stream_id += 4;
                    return stream_id;
                },
            }
        }

        pub fn updateStreamIndicesFor(self: *Self, stream_id: u64) void {
            switch (stream_id & 0x3) {
                0 => {
                    const next = stream_id + 4;
                    if (self.next_wt_bidi_stream_id <= stream_id) {
                        self.next_wt_bidi_stream_id = next;
                    }
                },
                2 => {
                    const next = stream_id + 4;
                    if (self.next_wt_uni_stream_id <= stream_id) {
                        self.next_wt_uni_stream_id = next;
                    }
                },
                else => {},
            }
        }

        fn deriveNextUniStreamId(self: *Self) u64 {
            var next: u64 = 14;
            var it = self.wt_streams.iterator();
            while (it.next()) |entry| {
                const stream_id = entry.key_ptr.*;
                if ((stream_id & 0x3) == 2) {
                    const candidate = stream_id + 4;
                    if (candidate > next) next = candidate;
                }
            }
            return next;
        }

        fn deriveNextBidiStreamId(self: *Self) u64 {
            var next: u64 = if (self.last_request_stream_id) |last|
                last + 4
            else
                0;
            var it = self.wt_streams.iterator();
            while (it.next()) |entry| {
                const stream_id = entry.key_ptr.*;
                if ((stream_id & 0x3) == 0) {
                    const candidate = stream_id + 4;
                    if (candidate > next) next = candidate;
                }
            }
            return next;
        }

        pub fn recordLegacySessionAcceptReceived(self: *Self) void {
            self.wt_legacy_session_accept_received += 1;
        }

        pub fn recordCapsuleReceived(self: *Self, capsule: wt_capsules.CapsuleType) void {
            self.wt_capsules_received_total += 1;
            switch (capsule) {
                .close_session => self.wt_capsules_received.close_session += 1,
                .drain_session => self.wt_capsules_received.drain_session += 1,
                .wt_max_streams_bidi => self.wt_capsules_received.wt_max_streams_bidi += 1,
                .wt_max_streams_uni => self.wt_capsules_received.wt_max_streams_uni += 1,
                .wt_streams_blocked_bidi => self.wt_capsules_received.wt_streams_blocked_bidi += 1,
                .wt_streams_blocked_uni => self.wt_capsules_received.wt_streams_blocked_uni += 1,
                .wt_max_data => self.wt_capsules_received.wt_max_data += 1,
                .wt_data_blocked => self.wt_capsules_received.wt_data_blocked += 1,
            }
        }

        pub fn recordCapsuleSent(self: *Self, capsule: wt_capsules.Capsule) void {
            self.wt_capsules_sent_total += 1;
            switch (capsule) {
                .close_session => self.wt_capsules_sent.close_session += 1,
                .drain_session => self.wt_capsules_sent.drain_session += 1,
                .max_streams => |info| {
                    if (info.dir == .bidi) {
                        self.wt_capsules_sent.wt_max_streams_bidi += 1;
                    } else {
                        self.wt_capsules_sent.wt_max_streams_uni += 1;
                    }
                },
                .streams_blocked => |info| {
                    if (info.dir == .bidi) {
                        self.wt_capsules_sent.wt_streams_blocked_bidi += 1;
                    } else {
                        self.wt_capsules_sent.wt_streams_blocked_uni += 1;
                    }
                },
                .max_data => self.wt_capsules_sent.wt_max_data += 1,
                .data_blocked => self.wt_capsules_sent.wt_data_blocked += 1,
            }
        }

        pub fn processReadableWtStreams(self: *Self) void {
            const conn = if (self.conn) |*conn_ref| conn_ref else return;

            var it = self.wt_streams.iterator();
            while (it.next()) |entry| {
                const stream_id = entry.key_ptr.*;
                const wt_stream = entry.value_ptr.*;

                var buf: [4096]u8 = undefined;
                while (true) {
                    const res = conn.streamRecv(stream_id, &buf) catch |err| {
                        if (err == quiche.QuicheError.Done) break;
                        if (self.config.enable_debug_logging) {
                            std.debug.print(
                                "[client] WT stream recv error stream={d} err={s}\n",
                                .{ stream_id, @errorName(err) },
                            );
                        }
                        break;
                    };

                    if (res.n > 0 or res.fin) {
                        std.debug.print(
                            "[client] WT recv result stream={d} n={d} fin={s} \n",
                            .{ stream_id, res.n, if (res.fin) "true" else "false" },
                        );
                    }

                    if (res.n == 0 and !res.fin) {
                        break;
                    }

                    if (res.n > 0 or res.fin) {
                        const slice = buf[0..res.n];
                        wt_stream.handleIncoming(slice, res.fin) catch |err| {
                            std.debug.print(
                                "[client] WT handleIncoming error stream={d} err={s}\n",
                                .{ stream_id, @errorName(err) },
                            );
                        };
                    }

                    if (res.fin) break;
                }
            }
        }

        pub fn processWritableWtStreams(self: *Self) void {
            const conn = if (self.conn) |*conn_ref| conn_ref else return;

            while (conn.streamWritableNext()) |stream_id| {
                if (self.wt_streams.get(stream_id)) |stream| {
                    std.debug.print("[client] WT writable stream={d}\n", .{stream_id});
                    stream.writable = true;
                    if (stream.pending_fin) {
                        _ = stream.send(&.{}, true) catch {
                            stream.pending_fin = true;
                            continue;
                        };
                    }
                }
            }
        }
    };
}
