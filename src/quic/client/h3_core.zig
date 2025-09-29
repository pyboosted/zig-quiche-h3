const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const h3_datagram = h3.datagram;
const client_mod = @import("mod.zig");
const client_state = @import("state.zig");
const client_errors = @import("errors.zig");

const ClientError = client_errors.ClientError;
const FetchState = client_mod.FetchState;
const FetchOptions = client_state.FetchOptions;
const FetchResponse = client_state.FetchResponse;
const ResponseEvent = client_state.ResponseEvent;
const HeaderPair = client_state.HeaderPair;

pub fn Impl(comptime ClientType: type) type {
    return struct {
        const Self = ClientType;

        pub fn ensureH3(self: *Self) !void {
            if (self.h3_conn != null) return;
            const conn = try self.requireConn();
            const h3_conn = h3.H3Connection.newWithTransport(self.allocator, conn, &self.h3_config) catch {
                return ClientError.H3Error;
            };
            self.h3_conn = h3_conn;
        }

        pub fn ensureH3DatagramNegotiated(self: *Self) ClientError!void {
            var conn = try self.requireConn();
            try self.ensureH3();
            var h3_conn = &self.h3_conn.?;
            if (h3_conn.dgramEnabledByPeer(conn)) return;

            var attempts: usize = 0;
            while (attempts < 5) : (attempts += 1) {
                self.event_loop.runOnce();
                self.afterQuicProgress();

                conn = try self.requireConn();
                h3_conn = &self.h3_conn.?;

                if (h3_conn.dgramEnabledByPeer(conn)) return;
                if (conn.isClosed()) return ClientError.ConnectionClosed;
            }

            return ClientError.DatagramNotEnabled;
        }

        pub fn loadNextBodyChunk(self: *Self, state: *FetchState) !void {
            const provider = state.body_provider orelse return;
            while (true) {
                const result = provider.next(provider.ctx, self.allocator) catch {
                    return ClientError.H3Error;
                };

                switch (result) {
                    .finished => {
                        state.provider_done = true;
                        state.body_buffer = &.{};
                        state.body_sent = 0;
                        state.body_owned = false;
                        state.body_finished = true;
                        return;
                    },
                    .chunk => |data| {
                        if (data.len == 0) continue;
                        state.body_buffer = data;
                        state.body_sent = 0;
                        state.body_owned = true;
                        state.body_finished = false;
                        return;
                    },
                }
            }
        }

        pub fn trySendBody(self: *Self, stream_id: u64, state: *FetchState) ClientError!bool {
            const conn = try self.requireConn();
            var h3_conn = self.h3_conn orelse return ClientError.InvalidState;
            var wrote_any = false;

            while (state.hasPendingBody()) {
                if (state.body_buffer.len == state.body_sent and !state.provider_done) {
                    if (state.body_owned and state.body_buffer.len > 0) {
                        self.allocator.free(@constCast(state.body_buffer));
                        state.body_owned = false;
                    }
                    state.body_buffer = &.{};
                    state.body_sent = 0;
                    state.body_finished = true;
                    try self.loadNextBodyChunk(state);
                    if (state.body_buffer.len == 0 and state.provider_done) break;
                }

                const buf_len = state.body_buffer.len;
                if (state.body_sent >= buf_len) {
                    if (!state.provider_done) continue;
                    break;
                }

                const remaining = buf_len - state.body_sent;
                const chunk_len = @min(remaining, self.send_buf.len);
                if (chunk_len == 0) break;

                const end_index = state.body_sent + chunk_len;
                const chunk = state.body_buffer[state.body_sent..end_index];
                const fin = end_index == state.body_buffer.len and state.provider_done;

                const written = h3_conn.sendBody(conn, stream_id, chunk, fin) catch |err| switch (err) {
                    quiche.h3.Error.StreamBlocked, quiche.h3.Error.Done => break,
                    else => return ClientError.H3Error,
                };

                if (written == 0) break;
                state.body_sent += written;
                wrote_any = true;

                if (state.body_sent == buf_len) {
                    if (state.body_owned and buf_len > 0) {
                        self.allocator.free(@constCast(state.body_buffer));
                        state.body_owned = false;
                    }
                    state.body_buffer = &.{};
                    state.body_sent = 0;
                    state.body_finished = true;
                    if (!state.provider_done) {
                        try self.loadNextBodyChunk(state);
                        continue;
                    }
                }

                if (written < chunk_len) break;
            }

            if (state.body_sent == state.body_buffer.len) {
                state.body_finished = true;
            }

            return wrote_any;
        }

        pub fn emitEvent(self: *Self, state: *FetchState, event: ResponseEvent) bool {
            if (state.response_callback) |cb| {
                cb(event, state.response_ctx) catch |err| {
                    self.failFetch(state.stream_id, err);
                    return false;
                };
            }
            return true;
        }

        pub fn sendPendingBodies(self: *Self) void {
            if (self.requests.count() == 0) return;
            var wrote_any = false;
            var it = self.requests.iterator();
            while (it.next()) |entry| {
                const stream_id = entry.key_ptr.*;
                const state = entry.value_ptr.*;
                if (!state.hasPendingBody()) continue;
                const wrote = self.trySendBody(stream_id, state) catch |err| {
                    self.failFetch(stream_id, err);
                    continue;
                };
                if (wrote) wrote_any = true;
            }

            if (wrote_any) {
                self.flushSend() catch |err| {
                    self.failAll(err);
                };
            }
        }

        pub fn finalizeFetch(self: *Self, stream_id: u64) ClientError!FetchResponse {
            const state = self.requests.get(stream_id) orelse return ClientError.ResponseIncomplete;
            const keep_state_for_wt = blk: {
                if (!state.is_webtransport) break :blk false;
                if (state.err != null) break :blk false;
                const status = state.status orelse break :blk false;
                break :blk status == 200;
            };

            defer {
                if (keep_state_for_wt) {
                    // Keep state for WebTransport session lifecycle
                } else {
                    if (state.is_webtransport) {
                        if (self.wt_sessions.get(stream_id)) |session| {
                            if (session.state != .established) {
                                self.cleanupWebTransportSession(stream_id);
                            }
                        }
                    }
                    _ = self.requests.remove(stream_id);
                    state.destroy();
                }
            }

            if (state.err) |fetch_err| {
                return fetch_err;
            }

            if (!state.finished or state.status == null) {
                return ClientError.ResponseIncomplete;
            }

            const body = state.takeBody() catch {
                return ClientError.H3Error;
            };
            const headers = state.headers.toOwnedSlice() catch {
                return ClientError.H3Error;
            };
            const trailers = state.trailers.toOwnedSlice() catch {
                return ClientError.H3Error;
            };

            return FetchResponse{
                .status = state.status.?,
                .body = body,
                .headers = headers,
                .trailers = trailers,
            };
        }

        pub fn prepareRequestHeaders(self: *Self, options: FetchOptions) ClientError![]quiche.h3.Header {
            const authority = self.server_authority orelse return ClientError.NoAuthority;
            if (options.method.len == 0) return ClientError.InvalidRequest;
            const scheme: []const u8 = "https";
            const user_agent: []const u8 = "zig-quiche-h3-client/0.1";

            const base_count: usize = 5;
            const total = base_count + options.headers.len;
            var headers = self.allocator.alloc(quiche.h3.Header, total) catch {
                return ClientError.H3Error;
            };
            headers[0] = makeHeader(":method", options.method);
            headers[1] = makeHeader(":scheme", scheme);
            headers[2] = makeHeader(":authority", authority);
            headers[3] = makeHeader(":path", options.path);
            headers[4] = makeHeader("user-agent", user_agent);

            var idx: usize = base_count;
            for (options.headers) |h| {
                headers[idx] = makeHeader(h.name, h.value);
                idx += 1;
            }
            return headers;
        }

        fn makeHeader(name_literal: []const u8, value_slice: []const u8) quiche.h3.Header {
            const name = name_literal;
            return .{
                .name = name.ptr,
                .name_len = name.len,
                .value = value_slice.ptr,
                .value_len = value_slice.len,
            };
        }

        pub fn startRequest(self: *Self, allocator: std.mem.Allocator, options: FetchOptions) ClientError!client_mod.FetchHandle {
            if (self.state != .established) return ClientError.NoConnection;
            if (self.server_authority == null) return ClientError.NoAuthority;
            if (options.path.len == 0) return ClientError.InvalidRequest;

            if (self.goaway_received) {
                return ClientError.ConnectionGoingAway;
            }

            const conn = try self.requireConn();
            try self.ensureH3();
            const h3_conn = &self.h3_conn.?;

            var state = FetchState.init(allocator) catch {
                return ClientError.H3Error;
            };
            var state_cleanup = true;
            defer if (state_cleanup) state.destroy();

            state.collect_body = options.on_event == null;
            state.response_callback = options.on_event;
            state.response_ctx = options.event_ctx;
            state.timeout_override_ms = options.timeout_override_ms;

            if (options.body_provider) |provider| {
                state.body_provider = provider;
                state.provider_done = false;
                try self.loadNextBodyChunk(state);
            } else if (options.body.len > 0) {
                state.body_buffer = self.allocator.dupe(u8, options.body) catch {
                    return ClientError.H3Error;
                };
                state.body_owned = true;
                state.body_finished = false;
            }

            const headers = try self.prepareRequestHeaders(options);
            defer self.allocator.free(headers);

            const has_body = state.body_buffer.len > 0 or !state.provider_done;
            const stream_id = h3_conn.sendRequest(conn, headers, !has_body) catch {
                return ClientError.H3Error;
            };
            state.stream_id = stream_id;

            self.last_request_stream_id = stream_id;

            self.requests.put(stream_id, state) catch {
                state.destroy();
                return ClientError.H3Error;
            };
            state_cleanup = false;

            if (has_body) {
                _ = self.trySendBody(stream_id, state) catch |err| {
                    _ = self.requests.remove(stream_id);
                    state.destroy();
                    return err;
                };
            }

            self.flushSend() catch |err| {
                _ = self.requests.remove(stream_id);
                state.destroy();
                return err;
            };
            self.afterQuicProgress();

            return client_mod.FetchHandle{ .client = self, .stream_id = stream_id };
        }
    };
}
