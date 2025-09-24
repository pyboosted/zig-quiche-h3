const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const h3_datagram = @import("h3").datagram;
const connection = @import("connection");

pub fn Impl(comptime S: type) type {
    return struct {
        const Self = S;

        pub const UniPreface = struct {
            buf: [32]u8 = undefined,
            len: usize = 0,
        };

        pub fn openWtUniStream(
            self: *Self,
            conn: *connection.Connection,
            sess_state: *h3.WebTransportSessionState,
        ) !*h3.WebTransportSession.WebTransportStream {
            if (!Self.WithWT) return error.FeatureDisabled;
            if (countWtStreamsForSession(self, conn, sess_state.session.session_id, .uni) >= self.config.wt_max_streams_uni) {
                return error.StreamLimit;
            }

            const stream_id = conn.allocLocalUniStreamId();
            const wt_stream = try self.allocator.create(h3.WebTransportSession.WebTransportStream);
            wt_stream.* = .{
                .stream_id = stream_id,
                .dir = .uni,
                .role = .outgoing,
                .session_id = sess_state.session.session_id,
                .allocator = self.allocator,
            };
            try self.wt.streams.put(.{ .conn = conn, .stream_id = stream_id }, wt_stream);

            var preface: [16]u8 = undefined;
            var off: usize = 0;
            off += try h3_datagram.encodeVarint(preface[off..], h3.WebTransportSession.UNI_STREAM_TYPE);
            off += try h3_datagram.encodeVarint(preface[off..], sess_state.session.session_id);

            const sent = conn.conn.streamSend(stream_id, preface[0..off], false) catch |err| {
                if (err == quiche.QuicheError.Done or err == quiche.QuicheError.FlowControl or err == quiche.QuicheError.StreamLimit) {
                    try wt_stream.pending.appendSlice(self.allocator, preface[0..off]);
                    return wt_stream;
                }
                _ = self.wt.streams.remove(.{ .conn = conn, .stream_id = stream_id });
                self.allocator.destroy(wt_stream);
                return err;
            };
            if (sent < off) {
                try wt_stream.pending.appendSlice(self.allocator, preface[sent..off]);
            }
            sess_state.last_activity_ms = std.time.milliTimestamp();
            return wt_stream;
        }

        pub fn openWtBidiStream(
            self: *Self,
            conn: *connection.Connection,
            sess_state: *h3.WebTransportSessionState,
        ) !*h3.WebTransportSession.WebTransportStream {
            if (!Self.WithWT) return error.FeatureDisabled;
            if (!self.wt.enable_bidi) return error.FeatureDisabled;
            if (countWtStreamsForSession(self, conn, sess_state.session.session_id, .bidi) >= self.config.wt_max_streams_bidi) {
                return error.StreamLimit;
            }

            const stream_id = conn.allocLocalBidiStreamId();
            const wt_stream = try self.allocator.create(h3.WebTransportSession.WebTransportStream);
            wt_stream.* = .{
                .stream_id = stream_id,
                .dir = .bidi,
                .role = .outgoing,
                .session_id = sess_state.session.session_id,
                .allocator = self.allocator,
            };
            try self.wt.streams.put(.{ .conn = conn, .stream_id = stream_id }, wt_stream);

            var preface: [16]u8 = undefined;
            var off: usize = 0;
            off += try h3_datagram.encodeVarint(preface[off..], h3.WebTransportSession.BIDI_STREAM_TYPE);
            off += try h3_datagram.encodeVarint(preface[off..], sess_state.session.session_id);

            const sent = conn.conn.streamSend(stream_id, preface[0..off], false) catch |err| {
                if (err == quiche.QuicheError.Done or err == quiche.QuicheError.FlowControl or err == quiche.QuicheError.StreamLimit) {
                    try wt_stream.pending.appendSlice(self.allocator, preface[0..off]);
                } else {
                    _ = self.wt.streams.remove(.{ .conn = conn, .stream_id = stream_id });
                    self.allocator.destroy(wt_stream);
                    return err;
                }
                sess_state.last_activity_ms = std.time.milliTimestamp();
                return wt_stream;
            };
            if (sent < off) {
                try wt_stream.pending.appendSlice(self.allocator, preface[sent..off]);
            }
            sess_state.last_activity_ms = std.time.milliTimestamp();
            return wt_stream;
        }

        pub fn processReadableWtStreams(self: *Self, conn: *connection.Connection) !void {
            if (!Self.WithWT) return;
            while (conn.conn.streamReadableNext()) |stream_id| {
                if ((stream_id & 0x2) == 1) {
                    if ((stream_id & 0x1) != 0) continue;
                    const client_uni_index = stream_id >> 2;
                    if (client_uni_index < 3) continue;
                } else {
                    if ((stream_id & 0x1) != 0) continue;
                }
                if ((stream_id & 0x1) != 0) continue;
                const client_uni_index = stream_id >> 2;
                if (client_uni_index < 3) continue;

                const sk = Self.StreamKey{ .conn = conn, .stream_id = stream_id };
                if (self.wt.streams.get(sk)) |wt_stream| {
                    var buf: [4096]u8 = undefined;
                    while (true) {
                        const res = conn.conn.streamRecv(stream_id, &buf) catch |err| {
                            if (err == quiche.QuicheError.Done) break;
                            try quiche.mapError(@intCast(0));
                            std.debug.print("WT stream recv error on {}: {}\n", .{ stream_id, err });
                            break;
                        };
                        if (res.n == 0 and !res.fin) break;
                        if (res.n > 0) {
                            deliverWtStreamData(self, conn, wt_stream, buf[0..res.n], false) catch |e| {
                                if (e != error.WouldBlock) std.debug.print("WT stream data cb error: {}\n", .{e});
                            };
                        }
                        if (res.fin) {
                            deliverWtStreamData(self, conn, wt_stream, &[_]u8{}, true) catch {};
                            closeWtStream(self, conn, wt_stream);
                            break;
                        }
                    }
                    continue;
                }

                if ((stream_id & 0x2) == 1) {
                    try tryBindIncomingUniStream(self, conn, stream_id);
                } else if (self.wt.enable_bidi) {
                    try tryBindIncomingBidiStream(self, conn, stream_id);
                }
            }
        }

        pub fn processWritableWtStreams(self: *Self, conn: *connection.Connection) !void {
            if (!Self.WithWT) return;
            var remaining: isize = @intCast(@as(i64, @min(self.config.wt_write_quota_per_tick, @as(usize, std.math.maxInt(i64)))));
            while (conn.conn.streamWritableNext()) |stream_id| {
                const sk = Self.StreamKey{ .conn = conn, .stream_id = stream_id };
                if (self.wt.streams.get(sk)) |wt_stream| {
                    if (wt_stream.pending.items.len == 0) continue;
                    const buf = wt_stream.pending.items;
                    const written = conn.conn.streamSend(stream_id, buf, wt_stream.fin_on_flush) catch |err| {
                        if (err == quiche.QuicheError.Done) continue;
                        std.debug.print("WT stream send error on {}: {}\n", .{ stream_id, err });
                        _ = self.wt.streams.remove(sk);
                        wt_stream.allocator.destroy(wt_stream);
                        continue;
                    };
                    if (written > 0) {
                        remaining -= @intCast(@as(i64, @min(@as(usize, written), @as(usize, std.math.maxInt(i64)))));
                        if (remaining <= 0) return;
                        if (written >= buf.len) {
                            wt_stream.pending.clearRetainingCapacity();
                        } else {
                            @memmove(buf[0 .. buf.len - written], buf[written..]);
                            wt_stream.pending.items = buf[0 .. buf.len - written];
                        }
                    }
                }
            }
        }

        pub fn sendWtStream(
            self: *Self,
            conn: *connection.Connection,
            stream: *h3.WebTransportSession.WebTransportStream,
            data: []const u8,
            fin: bool,
        ) !usize {
            if (!Self.WithWT) return error.FeatureDisabled;
            if (stream.pending.items.len == 0) {
                const n = conn.conn.streamSend(stream.stream_id, data, fin) catch |err| {
                    if (err == quiche.QuicheError.Done or err == quiche.QuicheError.FlowControl) {
                        if (data.len > self.config.wt_stream_pending_max) return error.WouldBlock;
                        try stream.pending.appendSlice(self.allocator, data);
                        if (fin) stream.fin_on_flush = true;
                        return error.WouldBlock;
                    }
                    return err;
                };
                if (n < data.len) {
                    const rem = data.len - n;
                    if (rem + stream.pending.items.len > self.config.wt_stream_pending_max) return error.WouldBlock;
                    try stream.pending.appendSlice(self.allocator, data[n..]);
                    if (fin) stream.fin_on_flush = true;
                }
                if (self.wt.sessions.get(.{ .conn = conn, .session_id = stream.session_id })) |st| st.last_activity_ms = std.time.milliTimestamp();
                return n;
            }
            if (data.len + stream.pending.items.len > self.config.wt_stream_pending_max) return error.WouldBlock;
            try stream.pending.appendSlice(self.allocator, data);
            if (fin) stream.fin_on_flush = true;
            if (self.wt.sessions.get(.{ .conn = conn, .session_id = stream.session_id })) |st| st.last_activity_ms = std.time.milliTimestamp();
            return error.WouldBlock;
        }

        pub fn sendWtStreamAll(
            self: *Self,
            conn: *connection.Connection,
            stream: *h3.WebTransportSession.WebTransportStream,
            data: []const u8,
            fin: bool,
        ) !void {
            if (!Self.WithWT) return;
            if (data.len == 0 and !fin) return;
            const n = sendWtStream(self, conn, stream, data, fin) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };
            if (n < data.len) return;
        }

        pub fn readWtStreamAll(
            self: *Self,
            conn: *connection.Connection,
            stream: *h3.WebTransportSession.WebTransportStream,
            out: []u8,
        ) !struct { n: usize, fin: bool } {
            if (!Self.WithWT) return .{ .n = 0, .fin = false };
            _ = self;
            var total: usize = 0;
            var saw_fin = false;
            if (out.len == 0) return .{ .n = 0, .fin = false };
            while (total < out.len) {
                const res = conn.conn.streamRecv(stream.stream_id, out[total..]) catch |err| {
                    if (err == quiche.QuicheError.Done) break;
                    return err;
                };
                if (res.n == 0 and !res.fin) break;
                total += res.n;
                if (res.fin) {
                    saw_fin = true;
                    break;
                }
                if (res.n == 0) break;
            }
            return .{ .n = total, .fin = saw_fin };
        }

        fn tryBindIncomingBidiStream(self: *Self, conn: *connection.Connection, stream_id: u64) !void {
            if (!Self.WithWT) return;
            if ((stream_id & 0x2) != 0) return;
            if ((stream_id & 0x1) != 0) return;

            const sk = Self.StreamKey{ .conn = conn, .stream_id = stream_id };
            var tmp: [64]u8 = undefined;
            const res = conn.conn.streamRecv(stream_id, &tmp) catch |err| {
                if (err == quiche.QuicheError.Done) return;
                return err;
            };

            var preface_buf: [32]u8 = undefined;
            var preface_len: usize = 0;
            if (self.wt.uni_preface.get(sk)) |p| {
                @memcpy(preface_buf[0..p.len], p.buf[0..p.len]);
                preface_len = p.len;
                _ = self.wt.uni_preface.remove(sk);
            }
            const to_copy = @min(preface_buf.len - preface_len, res.n);
            @memcpy(preface_buf[preface_len .. preface_len + to_copy], tmp[0..to_copy]);
            preface_len += to_copy;

            const v1 = h3.datagram.decodeVarint(preface_buf[0..preface_len]) catch |e| {
                if (e == error.BufferTooShort) {
                    var st = UniPreface{ .len = preface_len };
                    @memcpy(st.buf[0..preface_len], preface_buf[0..preface_len]);
                    try self.wt.uni_preface.put(sk, st);
                    return;
                }
                return;
            };
            if (v1.value != h3.WebTransportSession.BIDI_STREAM_TYPE) {
                return;
            }
            if (v1.consumed >= preface_len) return;
            const v2 = h3.datagram.decodeVarint(preface_buf[v1.consumed..preface_len]) catch |e| {
                if (e == error.BufferTooShort) {
                    var st2 = UniPreface{ .len = preface_len };
                    @memcpy(st2.buf[0..preface_len], preface_buf[0..preface_len]);
                    try self.wt.uni_preface.put(sk, st2);
                    return;
                }
                return;
            };
            const session_id = v2.value;

            if (countWtStreamsForSession(self, conn, session_id, .bidi) >= self.config.wt_max_streams_bidi) {
                const code = h3.webtransport.APP_ERR_STREAM_LIMIT;
                conn.conn.streamShutdown(stream_id, quiche.Connection.Shutdown.read, code) catch {};
                conn.conn.streamShutdown(stream_id, quiche.Connection.Shutdown.write, code) catch {};
                return;
            }
            const sess_key = Self.SessionKey{ .conn = conn, .session_id = session_id };
            const sess_state = self.wt.sessions.get(sess_key) orelse {
                const code = h3.webtransport.APP_ERR_INVALID_STREAM;
                conn.conn.streamShutdown(stream_id, quiche.Connection.Shutdown.read, code) catch {};
                conn.conn.streamShutdown(stream_id, quiche.Connection.Shutdown.write, code) catch {};
                return;
            };

            const wt_stream = try self.allocator.create(h3.WebTransportSession.WebTransportStream);
            wt_stream.* = .{
                .stream_id = stream_id,
                .dir = .bidi,
                .role = .incoming,
                .session_id = session_id,
                .allocator = self.allocator,
            };
            try self.wt.streams.put(sk, wt_stream);
            if (sess_state.on_bidi_open) |cb| {
                const sess_ptr: *anyopaque = if (sess_state.session_ctx) |ctx| ctx else @ptrCast(sess_state.session);
                const stream_ptr: *anyopaque = if (sess_state.session_ctx) |ctx| stream_blk: {
                    const session_wrapper = Self.WTApi.sessionFromOpaque(ctx);
                    const wrapper = session_wrapper.ensureStreamWrapper(wt_stream) catch |err| {
                        std.debug.print("WT bidi ensure wrapper error: {}\\n", .{err});
                        break :stream_blk @ptrCast(wt_stream);
                    };
                    break :stream_blk wrapper.asAnyOpaque();
                } else @ptrCast(wt_stream);
                cb(sess_ptr, stream_ptr) catch |err| {
                    std.debug.print("WT bidi open cb error: {}\\n", .{err});
                };
            }
            if (res.n > (v1.consumed + v2.consumed)) {
                const extra = tmp[v1.consumed + v2.consumed .. res.n];
                deliverWtStreamData(self, conn, wt_stream, extra, res.fin) catch {};
            }
            if (res.fin) closeWtStream(self, conn, wt_stream);
        }

        fn tryBindIncomingUniStream(self: *Self, conn: *connection.Connection, stream_id: u64) !void {
            if (!Self.WithWT) return;
            if ((stream_id & 0x2) == 0) return;
            if ((stream_id & 0x1) != 0) return;
            if ((stream_id >> 2) < 3) return;
            const sk = Self.StreamKey{ .conn = conn, .stream_id = stream_id };
            var tmp: [64]u8 = undefined;
            const res = conn.conn.streamRecv(stream_id, &tmp) catch |err| {
                if (err == quiche.QuicheError.Done) return;
                return err;
            };

            var preface_buf: [32]u8 = undefined;
            var preface_len: usize = 0;
            if (self.wt.uni_preface.get(sk)) |p| {
                @memcpy(preface_buf[0..p.len], p.buf[0..p.len]);
                preface_len = p.len;
                _ = self.wt.uni_preface.remove(sk);
            }
            const to_copy = @min(preface_buf.len - preface_len, res.n);
            @memcpy(preface_buf[preface_len .. preface_len + to_copy], tmp[0..to_copy]);
            preface_len += to_copy;

            const parsed = h3.WebTransportSession.parseUniPreface(preface_buf[0..preface_len]) catch |e| {
                if (e == error.BufferTooShort) {
                    var st = UniPreface{ .len = preface_len };
                    @memcpy(st.buf[0..preface_len], preface_buf[0..preface_len]);
                    try self.wt.uni_preface.put(sk, st);
                    return;
                }
                std.debug.print("Ignoring unknown unidirectional stream {} (not WT)\n", .{stream_id});
                return;
            };

            const sess_key = Self.SessionKey{ .conn = conn, .session_id = parsed.session_id };
            const sess_state = self.wt.sessions.get(sess_key) orelse {
                std.debug.print("WT uni stream {} references unknown session {}\n", .{ stream_id, parsed.session_id });
                const code = h3.webtransport.APP_ERR_INVALID_STREAM;
                conn.conn.streamShutdown(stream_id, quiche.Connection.Shutdown.read, code) catch {};
                conn.conn.streamShutdown(stream_id, quiche.Connection.Shutdown.write, code) catch {};
                return;
            };
            if (countWtStreamsForSession(self, conn, parsed.session_id, .uni) >= self.config.wt_max_streams_uni) {
                std.debug.print("WT uni stream limit reached for session {}\n", .{parsed.session_id});
                const code = h3.webtransport.APP_ERR_STREAM_LIMIT;
                conn.conn.streamShutdown(stream_id, quiche.Connection.Shutdown.read, code) catch {};
                conn.conn.streamShutdown(stream_id, quiche.Connection.Shutdown.write, code) catch {};
                return;
            }

            const wt_stream = try self.allocator.create(h3.WebTransportSession.WebTransportStream);
            wt_stream.* = .{
                .stream_id = stream_id,
                .dir = .uni,
                .role = .incoming,
                .session_id = parsed.session_id,
                .allocator = self.allocator,
            };
            try self.wt.streams.put(sk, wt_stream);

            if (sess_state.on_uni_open) |cb| {
                const sess_ptr: *anyopaque = if (sess_state.session_ctx) |ctx| ctx else @ptrCast(sess_state.session);
                const stream_ptr: *anyopaque = if (sess_state.session_ctx) |ctx| stream_blk: {
                    const session_wrapper = Self.WTApi.sessionFromOpaque(ctx);
                    const wrapper = session_wrapper.ensureStreamWrapper(wt_stream) catch |err| {
                        std.debug.print("WT uni ensure wrapper error: {}\n", .{err});
                        break :stream_blk @ptrCast(wt_stream);
                    };
                    break :stream_blk wrapper.asAnyOpaque();
                } else @ptrCast(wt_stream);
                cb(sess_ptr, stream_ptr) catch |err| {
                    std.debug.print("WT uni open callback error: {}\n", .{err});
                };
            }

            if (res.n > parsed.consumed) {
                const leftover = tmp[parsed.consumed..res.n];
                deliverWtStreamData(self, conn, wt_stream, leftover, res.fin) catch |err| {
                    if (err != error.WouldBlock) std.debug.print("WT stream data cb error: {}\n", .{err});
                };
                if (res.fin) closeWtStream(self, conn, wt_stream);
            } else if (res.fin) {
                deliverWtStreamData(self, conn, wt_stream, &[_]u8{}, true) catch {};
                closeWtStream(self, conn, wt_stream);
            }
        }

        fn countWtStreamsForSession(self: *Self, conn: *connection.Connection, session_id: u64, dir: h3.WebTransportSession.StreamDir) usize {
            var count: usize = 0;
            var it = self.wt.streams.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.conn == conn and entry.value_ptr.*.session_id == session_id and entry.value_ptr.*.dir == dir) {
                    count += 1;
                }
            }
            return count;
        }

        fn deliverWtStreamData(self: *Self, conn: *connection.Connection, stream: *h3.WebTransportSession.WebTransportStream, data: []const u8, fin: bool) !void {
            if (!Self.WithWT) return error.FeatureDisabled;
            if (self.wt.sessions.get(.{ .conn = conn, .session_id = stream.session_id })) |st| {
                st.last_activity_ms = std.time.milliTimestamp();
                if (st.on_stream_data) |cb| {
                    var stream_ptr: *anyopaque = if (stream.user_data) |ptr| ptr else @ptrCast(stream);
                    if (stream.user_data == null and st.session_ctx) |ctx| {
                        const session_wrapper = Self.WTApi.sessionFromOpaque(ctx);
                        const wrapper = session_wrapper.ensureStreamWrapper(stream) catch |err| {
                            std.debug.print("WT ensure wrapper during data error: {}\\n", .{err});
                            return err;
                        };
                        stream_ptr = wrapper.asAnyOpaque();
                    }
                    cb(stream_ptr, data, fin) catch |err| return err;
                }
            }
        }

        fn closeWtStream(self: *Self, conn: *connection.Connection, stream: *h3.WebTransportSession.WebTransportStream) void {
            if (!Self.WithWT) return;
            var it = self.wt.sessions.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.conn == conn and entry.key_ptr.session_id == stream.session_id) {
                    const stream_ptr: *anyopaque = if (stream.user_data) |ptr| ptr else @ptrCast(stream);
                    if (entry.value_ptr.*.on_stream_closed) |cb| cb(stream_ptr);
                    break;
                }
            }
            _ = self.wt.streams.remove(.{ .conn = conn, .stream_id = stream.stream_id });
            Self.WTApi.destroyStreamWrapper(self, stream);
            stream.allocator.destroy(stream);
        }

        pub fn expireIdleWtSessions(self: *Self, conn: *connection.Connection, now_ms: i64) !void {
            if (!Self.WithWT) return;
            var to_remove = std.ArrayList(Self.SessionKey){};
            defer to_remove.deinit(self.allocator);
            var it = self.wt.sessions.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.conn != conn) continue;
                const st = entry.value_ptr.*;
                if (st.last_activity_ms == 0) continue;
                const idle = now_ms - st.last_activity_ms;
                if (idle >= @as(i64, @intCast(self.config.wt_session_idle_ms))) {
                    _ = st.session.h3_conn.sendBody(&conn.conn, st.session.session_id, "", true) catch {};
                    to_remove.append(self.allocator, key) catch {};
                }
            }
            for (to_remove.items) |k| {
                if (self.wt.sessions.fetchRemove(k)) |kv| {
                    _ = self.wt.dgram_map.remove(.{ .conn = conn, .flow_id = k.session_id });
                    kv.value.deinit(self.allocator);
                    self.wt.sessions_closed += 1;
                }
            }
        }
    };
}
