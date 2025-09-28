const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const h3_datagram = h3.datagram;
const client_mod = @import("mod.zig");
const client_state = @import("state.zig");
const client_errors = @import("errors.zig");

const ClientError = client_errors.ClientError;
const ResponseEvent = client_state.ResponseEvent;

pub fn Impl(comptime ClientType: type) type {
    return struct {
        const Self = ClientType;

        pub fn sendH3Datagram(self: *Self, stream_id: u64, payload: []const u8) ClientError!void {
            try self.ensureH3DatagramNegotiated();

            const conn = try self.requireConn();
            const h3_conn = &self.h3_conn.?;
            if (!h3_conn.dgramEnabledByPeer(conn)) return ClientError.DatagramNotEnabled;

            const flow_id = h3_datagram.flowIdForStream(stream_id);
            const overhead = h3_datagram.varintLen(flow_id);
            const total_len = overhead + payload.len;

            if (conn.dgramMaxWritableLen()) |maxw| {
                if (total_len > maxw) return ClientError.DatagramTooLarge;
            }

            var stack_buf: [2048]u8 = undefined;
            var buf: []u8 = stack_buf[0..];
            var use_heap = false;
            if (total_len <= stack_buf.len) {
                buf = stack_buf[0..total_len];
            } else {
                buf = self.allocator.alloc(u8, total_len) catch {
                    return ClientError.H3Error;
                };
                use_heap = true;
            }
            defer if (use_heap) self.allocator.free(buf);

            const written = h3_datagram.encodeVarint(buf, flow_id) catch {
                return ClientError.H3Error;
            };
            @memcpy(buf[written..][0..payload.len], payload);

            const sent = conn.dgramSend(buf) catch |err| switch (err) {
                error.Done => return ClientError.DatagramSendFailed,
                else => return ClientError.DatagramSendFailed,
            };

            if (sent != buf.len) return ClientError.DatagramSendFailed;

            self.flushSend() catch |err| return err;
            self.afterQuicProgress();
        }

        pub fn onQuicDatagram(
            self: *Self,
            cb: *const fn (client: *Self, payload: []const u8, user: ?*anyopaque) void,
            user: ?*anyopaque,
        ) void {
            self.on_quic_datagram = cb;
            self.on_quic_datagram_user = user;
        }

        pub fn sendQuicDatagram(self: *Self, payload: []const u8) ClientError!void {
            const conn = try self.requireConn();

            const max_len = conn.dgramMaxWritableLen() orelse
                return ClientError.DatagramNotEnabled;

            if (payload.len > max_len) {
                self.datagram_stats.dropped_send += 1;
                return ClientError.DatagramTooLarge;
            }

            const sent = conn.dgramSend(payload) catch |err| {
                self.datagram_stats.dropped_send += 1;
                if (err == error.Done) return ClientError.DatagramSendFailed;
                return ClientError.DatagramSendFailed;
            };

            if (sent != payload.len) {
                self.datagram_stats.dropped_send += 1;
                return ClientError.DatagramSendFailed;
            }

            self.datagram_stats.sent += 1;
            self.flushSend() catch |err| return err;
            self.afterQuicProgress();
        }

        pub fn processDatagrams(self: *Self) void {
            const conn = if (self.conn) |*conn_ref| conn_ref else return;

            while (true) {
                const hint = conn.dgramRecvFrontLen();
                var buf_slice: []u8 = self.datagram_buf[0..];
                var use_heap = false;

                if (hint) |h| {
                    if (h > self.datagram_buf.len) {
                        buf_slice = self.allocator.alloc(u8, h) catch return;
                        use_heap = true;
                    } else {
                        buf_slice = self.datagram_buf[0..h];
                    }
                }

                const read = conn.dgramRecv(buf_slice) catch |err| {
                    if (use_heap) self.allocator.free(buf_slice);
                    if (err == error.Done) return;
                    return;
                };

                const payload = buf_slice[0..read];
                self.datagram_stats.received += 1;

                var handled_as_h3 = false;

                if (self.h3_conn) |_| {
                    handled_as_h3 = processH3Datagram(self, payload) catch false;
                }

                if (!handled_as_h3 and self.on_quic_datagram != null) {
                    if (self.on_quic_datagram) |cb| {
                        cb(self, payload, self.on_quic_datagram_user);
                    }
                }

                if (use_heap) self.allocator.free(buf_slice);
            }
        }

        pub fn processH3Datagram(self: *Self, payload: []const u8) !bool {
            const varint = h3_datagram.decodeVarint(payload) catch return false;
            if (varint.consumed >= payload.len) return false;

            const id = varint.value;
            const h3_payload = payload[varint.consumed..];

            if (self.wt_sessions.get(id)) |session| {
                session.queueDatagram(h3_payload) catch {
                    return false;
                };

                if (self.requests.get(id)) |state| {
                    state.wt_datagrams_received += 1;
                }
                return true;
            }

            const stream_id = h3_datagram.streamIdForFlow(id);

            if (self.requests.get(stream_id)) |state| {
                if (state.response_callback) |_| {
                    const copy = state.allocator.dupe(u8, h3_payload) catch return false;
                    const event = ResponseEvent{ .datagram = .{ .flow_id = id, .payload = copy } };
                    _ = self.emitEvent(state, event);
                    state.allocator.free(copy);
                    return true;
                }
            }
            return false;
        }
    };
}
