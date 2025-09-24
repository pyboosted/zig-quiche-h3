const std = @import("std");
const h3 = @import("h3");
const h3_datagram = @import("h3").datagram;
const connection = @import("connection");
const errors = @import("errors");
const server_logging = @import("logging.zig");
const conn_state = @import("connection_state.zig");

pub fn Impl(comptime S: type) type {
    return struct {
        const Self = S;
        const ServerOnDatagram = *const fn (server: *Self, conn: *connection.Connection, payload: []const u8, user: ?*anyopaque) errors.DatagramError!void;

        /// Register a QUIC DATAGRAM handler
        pub fn onDatagram(self: *Self, cb: ServerOnDatagram, user: ?*anyopaque) void {
            self.on_datagram = cb;
            self.on_datagram_user = user;
        }

        /// Send a QUIC DATAGRAM on a connection, tracking counters
        pub fn sendDatagram(self: *Self, conn: *connection.Connection, data: []const u8) errors.DatagramError!void {
            if (conn.conn.dgramMaxWritableLen()) |maxw| {
                if (data.len > maxw) return error.DatagramTooLarge;
            }
            _ = conn.conn.dgramSend(data) catch |err| {
                if (err == error.Done) {
                    self.datagram.dropped_send += 1;
                    return error.WouldBlock;
                }
                // Map non-Done errors to a conservative ConnectionClosed
                return error.ConnectionClosed;
            };
            self.datagram.sent += 1;
        }

        /// Try to read and dispatch QUIC/H3 DATAGRAMs for a connection
        pub fn processDatagrams(self: *Self, conn: *connection.Connection) !void {
            while (true) {
                const hint = conn.conn.dgramRecvFrontLen();
                var buf: []u8 = conn.datagram_buf[0..];
                var use_heap = false;
                if (hint) |h| {
                    if (h > conn.datagram_buf.len) {
                        buf = try std.heap.c_allocator.alloc(u8, h);
                        use_heap = true;
                    } else {
                        buf = conn.datagram_buf[0..h];
                    }
                }

                const read = conn.conn.dgramRecv(buf) catch |err| {
                    if (use_heap) std.heap.c_allocator.free(buf);
                    if (err == error.Done) return; // no more
                    server_logging.debugPrint(self, "[DEBUG] dgramRecv error: {}\n", .{err});
                    return err;
                };

                const payload = buf[0..read];
                self.datagram.received += 1;

                if (server_logging.appDebug(self)) {
                    std.debug.print("[DEBUG] DATAGRAM recv len={d}, first bytes: ", .{payload.len});
                    for (payload[0..@min(16, payload.len)]) |b| std.debug.print("{x:0>2} ", .{b});
                    std.debug.print("\n", .{});
                }

                var handled_as_h3 = false;
                if (conn.http3) |h3_ptr| {
                    const h3_conn = @as(*h3.H3Connection, @ptrCast(@alignCast(h3_ptr)));
                    const h3_enabled = h3_conn.dgramEnabledByPeer(&conn.conn);
                    server_logging.debugPrint(self, "[DEBUG] H3 connection exists, dgramEnabledByPeer={}\n", .{h3_enabled});
                    if (h3_enabled) {
                        handled_as_h3 = processH3Datagram(self, conn, payload) catch |err| blk: {
                            server_logging.debugPrint(self, "[DEBUG] H3 DATAGRAM parse error: {}, falling back to QUIC\n", .{err});
                            break :blk false;
                        };
                        server_logging.debugPrint(self, "[DEBUG] Handled as H3 DATAGRAM: {}\n", .{handled_as_h3});
                    }
                } else {
                    server_logging.debugPrint(self, "[DEBUG] No H3 connection for this QUIC connection\n", .{});
                }

                if (!handled_as_h3 and self.on_datagram != null) {
                    if (self.on_datagram) |cb| {
                        cb(self, conn, payload, self.on_datagram_user) catch |e| {
                            std.debug.print("onDatagram error: {}\n", .{e});
                        };
                    }
                }
                if (use_heap) std.heap.c_allocator.free(buf);
            }
        }

        /// Process H3 DATAGRAM payload (with varint flow_id prefix)
        /// Returns true if successfully handled as H3 DATAGRAM, false if should fall back to QUIC
        pub fn processH3Datagram(self: *Self, conn: *connection.Connection, payload: []const u8) !bool {
            server_logging.debugPrint(self, "[DEBUG] processH3Datagram: attempting to decode varint from {} bytes\n", .{payload.len});
            const varint_result = h3_datagram.decodeVarint(payload) catch |err| {
                server_logging.debugPrint(self, "[DEBUG] Failed to decode varint: {}\n", .{err});
                return false;
            };
            const flow_id = varint_result.value;
            const payload_offset = varint_result.consumed;
            server_logging.debugPrint(self, "[DEBUG] Decoded flow_id={}, consumed {} bytes\n", .{ flow_id, payload_offset });
            if (payload_offset >= payload.len) {
                server_logging.debugPrint(self, "[DEBUG] Empty H3 DATAGRAM payload after flow_id\n", .{});
                self.h3.dgrams_received += 1;
                return true;
            }
            const h3_payload = payload[payload_offset..];
            server_logging.debugPrint(self, "[DEBUG] H3 DATAGRAM payload size: {} bytes\n", .{h3_payload.len});

            const flow_key = conn_state.FlowKey{ .conn = conn, .flow_id = flow_id };
            server_logging.debugPrint(self, "[DEBUG] Looking up flow_key: conn={*}, flow_id={}\n", .{ conn, flow_id });

            if (self.h3.dgram_flows.get(flow_key)) |state| {
                server_logging.debugPrint(self, "[DEBUG] Found flow mapping for flow_id={}\n", .{flow_id});
                self.h3.dgrams_received += 1;
                if (state.on_h3_dgram) |callback| {
                    server_logging.debugPrint(self, "[DEBUG] H3 DGRAM recv flow={d} len={d}, invoking callback\n", .{ flow_id, h3_payload.len });
                    callback(&state.request, &state.response, h3_payload) catch |err| {
                        if (err == error.WouldBlock) {
                            self.h3.would_block += 1;
                            server_logging.debugPrint(self, "[DEBUG] H3 DATAGRAM callback returned WouldBlock\n", .{});
                        } else {
                            server_logging.debugPrint(self, "[DEBUG] H3 DATAGRAM callback error: {}\n", .{err});
                        }
                    };
                    server_logging.debugPrint(self, "[DEBUG] H3 DATAGRAM callback completed\n", .{});
                } else {
                    server_logging.debugPrint(self, "[DEBUG] H3 DGRAM recv flow={d} len={d} - no callback registered\n", .{ flow_id, h3_payload.len });
                }
                return true;
            }

            if (Self.WithWT and self.wt.dgram_map.get(flow_key) != null) {
                const session_state = self.wt.dgram_map.get(flow_key).?;
                server_logging.debugPrint(self, "[DEBUG] Found WebTransport session for flow_id={}\n", .{flow_id});
                self.wt.dgrams_received += 1;
                if (session_state.on_datagram) |callback| {
                    server_logging.debugPrint(self, "[DEBUG] WT DGRAM recv session={d} len={d}, invoking callback\n", .{ flow_id, h3_payload.len });
                    const sess_arg: *anyopaque = if (session_state.session.user_data) |ptr| ptr else if (session_state.session_ctx) |ctx| ctx else @ptrCast(session_state.session);
                    callback(sess_arg, h3_payload) catch |err| {
                        if (err == error.WouldBlock) {
                            self.wt.dgrams_would_block += 1;
                            server_logging.debugPrint(self, "[DEBUG] WebTransport DATAGRAM callback returned WouldBlock\n", .{});
                        } else {
                            server_logging.debugPrint(self, "[DEBUG] WebTransport DATAGRAM callback error: {}\n", .{err});
                        }
                    };
                    server_logging.debugPrint(self, "[DEBUG] WebTransport DATAGRAM callback completed\n", .{});
                }
                return true;
            } else {
                self.h3.unknown_flow += 1;
                server_logging.debugPrint(self, "[DEBUG] H3 DGRAM recv unknown flow_id={d} len={d} - dropped\n", .{ flow_id, h3_payload.len });
                if (server_logging.appDebug(self)) {
                    std.debug.print("[DEBUG] Registered flow_ids for conn={*}:\n", .{conn});
                    var it = self.h3.dgram_flows.iterator();
                    while (it.next()) |entry| {
                        if (entry.key_ptr.conn == conn) std.debug.print("[DEBUG]   flow_id={}\n", .{entry.key_ptr.flow_id});
                    }
                }
                return true;
            }
        }

        pub fn incrementH3DatagramSent(self: *Self) void {
            self.h3.dgrams_sent += 1;
        }
    };
}
