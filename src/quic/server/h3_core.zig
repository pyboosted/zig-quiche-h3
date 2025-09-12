const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const http = @import("http");
const connection = @import("connection");
const h3_datagram = @import("h3").datagram;
const server_logging = @import("logging.zig");

pub fn Impl(comptime S: type) type {
    return struct {
        const Self = S;
        const RequestState = S.RequestState;

        fn onDatagramSentForward(ctx: *anyopaque, _bytes: usize) callconv(.c) void {
            _ = _bytes;
            const s: *Self = @ptrCast(@alignCast(ctx));
            if (!Self.WithWT) return;
            s.wt.dgrams_sent += 1;
        }

        pub fn processH3(self: *Self, conn: *connection.Connection) !void {
            const h3_ptr = conn.http3 orelse return;
            const h3_conn = @as(*h3.H3Connection, @ptrCast(@alignCast(h3_ptr)));

            while (true) {
                var result = h3_conn.poll(&conn.conn) orelse break;
                defer result.deinit();

                switch (result.event_type) {
                    .Headers => {
                        const state = try self.allocator.create(RequestState);
                        state.* = .{
                            .arena = std.heap.ArenaAllocator.init(self.allocator),
                            .request = undefined,
                            .response = undefined,
                            .handler = undefined,
                            .body_complete = false,
                            .handler_invoked = false,
                        };
                        errdefer {
                            state.arena.deinit();
                            self.allocator.destroy(state);
                        }

                        const arena_allocator = state.arena.allocator();
                        const headers = try h3.collectHeaders(arena_allocator, result.raw_event);

                        const req_info = h3.parseRequestHeaders(headers);

                        if (req_info.method == null or req_info.path == null) {
                            try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 400);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            continue;
                        }

                        const method_str = req_info.method.?;
                        const path_raw = req_info.path.?;
                        std.debug.print("→ HTTP/3 request: {s} {s}\n", .{ method_str, path_raw });

                        const method = http.Method.fromString(method_str) orelse {
                            try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 405);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            continue;
                        };

                        const req_headers = try arena_allocator.alloc(http.Header, headers.len);
                        for (headers, 0..) |h, i| {
                            req_headers[i] = .{ .name = h.name, .value = h.value };
                        }

                        state.request = try http.Request.init(
                            &state.arena,
                            method,
                            path_raw,
                            req_info.authority,
                            req_headers,
                            result.stream_id,
                        );
                        state.request.user_data = state.user_data;

                        const match_result = try self.router.match(
                            arena_allocator,
                            method,
                            state.request.path_decoded,
                        );

                        switch (match_result) {
                            .Found => |found| {
                                state.request.params = found.params;
                                if (found.route.is_streaming) {
                                    state.is_streaming = true;
                                    state.handler = undefined;
                                    state.on_headers = found.route.on_headers;
                                    state.on_body_chunk = found.route.on_body_chunk;
                                    state.on_body_complete = found.route.on_body_complete;
                                } else {
                                    if (found.route.handler) |hnd| {
                                        state.handler = hnd;
                                    } else {
                                        self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 500) catch {};
                                        state.arena.deinit();
                                        self.allocator.destroy(state);
                                        continue;
                                    }
                                }

                                state.on_h3_dgram = found.route.on_h3_dgram;

                                if (Self.WithWT and found.route.is_webtransport and method == .CONNECT) {
                                    const protocol = state.request.h3Protocol();
                                    if (protocol != null and std.mem.eql(u8, protocol.?, "webtransport")) {
                                        if (!h3_conn.extendedConnectEnabledByPeer()) {
                                            try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 421);
                                            _ = self.stream_states.remove(.{ .conn = conn, .stream_id = result.stream_id });
                                            state.arena.deinit();
                                            self.allocator.destroy(state);
                                            continue;
                                        }

                                        const session_id = result.stream_id;
                                        const h3_conn_ptr: *h3.H3Connection = @ptrCast(@alignCast(h3_ptr));
                                        const wt_session = try h3.WebTransportSession.init(
                                            self.allocator,
                                            session_id,
                                            &conn.conn,
                                            h3_conn_ptr,
                                            state.request.path_decoded,
                                        );
                                        wt_session.on_datagram_sent = onDatagramSentForward;
                                        wt_session.on_datagram_ctx = self;

                                        var session_state = try h3.WebTransportSessionState.init(
                                            self.allocator,
                                            wt_session,
                                            &[_]quiche.h3.Header{},
                                            found.route.on_wt_datagram,
                                        );
                                        session_state.on_uni_open = found.route.on_wt_uni_open;
                                        session_state.on_bidi_open = found.route.on_wt_bidi_open;
                                        session_state.on_stream_data = found.route.on_wt_stream_data;
                                        session_state.on_stream_closed = found.route.on_wt_stream_closed;

                                        const sess_alloc = session_state.arena.allocator();
                                        const wt_headers = try sess_alloc.alloc(quiche.h3.Header, headers.len + 1);
                                        wt_headers[0] = .{ .name = ":status", .name_len = 7, .value = "200", .value_len = 3 };
                                        for (headers, 0..) |h, i| wt_headers[i + 1] = h;

                                        session_state.headers = wt_headers;
                                        try self.wt.sessions.put(.{ .conn = conn, .session_id = session_id }, &session_state);
                                        try h3_conn.sendResponse(&conn.conn, result.stream_id, wt_headers, false);
                                        server_logging.debugPrint(self, "[WT] session established id={} path={s}\n", .{ session_id, state.request.path_decoded });
                                    }
                                }

                                // Initialize Response
                                state.response = try http.Response.init(
                                    self.allocator,
                                    &conn.conn,
                                    h3_conn,
                                    result.stream_id,
                                    method == .HEAD,
                                );

                                try self.stream_states.put(.{ .conn = conn, .stream_id = result.stream_id }, state);

                                // Register H3 DATAGRAM flow mapping when needed
                                if (state.on_h3_dgram != null) {
                                    const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(result.stream_id);
                                    try self.h3.dgram_flows.put(.{ .conn = conn, .flow_id = flow_id }, state);
                                }

                                if (!state.is_streaming) {
                                    self.invokeHandler(state) catch |err| {
                                        try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err));
                                    };
                                } else {
                                    if (state.on_headers) |cb| {
                                        cb(&state.request, &state.response) catch |err| {
                                            self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                        };
                                    }
                                }
                            },
                            .NotFound => {
                                try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 404);
                                state.arena.deinit();
                                self.allocator.destroy(state);
                            },
                            .MethodNotAllowed => |allow| {
                                try self.sendErrorResponseWithAllow(h3_conn, &conn.conn, result.stream_id, 405, allow);
                                state.arena.deinit();
                                self.allocator.destroy(state);
                            },
                        }
                    },
                    .Data => {
                        if (self.stream_states.get(.{ .conn = conn, .stream_id = result.stream_id })) |state| {
                            if (state.is_streaming) {
                                if (state.on_body_chunk) |cb| {
                                    const body_chunk = h3.bodyChunk(result.raw_event);
                                    if (body_chunk.len > 0) {
                                        cb(&state.request, &state.response, body_chunk) catch |err| {
                                            self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                        };
                                    }
                                }
                            }
                        }
                    },
                    .Finished => {
                        if (self.stream_states.get(.{ .conn = conn, .stream_id = result.stream_id })) |state| {
                            state.body_complete = true;
                            if (state.is_streaming) {
                                if (state.on_body_complete) |cb| {
                                    cb(&state.request, &state.response) catch |err| {
                                        self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                    };
                                }
                            } else if (!state.handler_invoked) {
                                self.invokeHandler(state) catch |err| {
                                    self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                };
                            }

                            if (state.response.isEnded() and state.response.partial_response == null) {
                                self.cleanupStreamState(conn, result.stream_id, state);
                            } else {
                                std.debug.print("  Keeping stream {} alive for ongoing response\n", .{result.stream_id});
                            }
                        }
                    },
                    .GoAway, .Reset => {
                        std.debug.print("  Stream {} closed ({})\n", .{ result.stream_id, result.event_type });
                        if (self.stream_states.fetchRemove(.{ .conn = conn, .stream_id = result.stream_id })) |entry| {
                            self.cleanupStreamState(conn, result.stream_id, entry.value);
                        }
                    },
                    .PriorityUpdate => {},
                }
            }
        }

        fn invokeHandler(self: *Self, state: *RequestState) !void {
            _ = self;
            // Prevent double invocation
            if (state.handler_invoked) return;
            state.handler_invoked = true;

            state.handler(&state.request, &state.response) catch |err| {
                if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                    return;
                }
                return err;
            };

            if (!state.response.isEnded() and state.response.partial_response == null) {
                try state.response.end(null);
            }
        }

        pub fn processWritableStreams(self: *Self, conn: *connection.Connection) !void {
            while (conn.conn.streamWritableNext()) |stream_id| {
                if (self.stream_states.get(.{ .conn = conn, .stream_id = stream_id })) |state| {
                    if (state.response.partial_response != null) {
                        state.response.processPartialResponse() catch |err| {
                            if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                                continue;
                            }
                            std.debug.print("Error processing partial response for stream {}: {}\n", .{ stream_id, err });
                            if (state.on_h3_dgram != null) {
                                const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(stream_id);
                                _ = self.h3.dgram_flows.remove(.{ .conn = conn, .flow_id = flow_id });
                            }
                            state.response.deinit();
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });
                        };

                        if (state.response.isEnded() and state.response.partial_response == null) {
                            if (state.on_h3_dgram != null) {
                                const flow_id2 = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(stream_id);
                                _ = self.h3.dgram_flows.remove(.{ .conn = conn, .flow_id = flow_id2 });
                            }
                            state.response.deinit();
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });
                        }
                    }
                }
            }

            try self.drainEgress(conn);
            const timeout_ms = conn.conn.timeoutAsMillis();
            try self.updateTimer(conn, timeout_ms);
        }

        pub fn sendErrorResponse(self: *Self, h3_conn: *h3.H3Connection, quic_conn: *quiche.Connection, stream_id: u64, status_code: u16) !void {
            _ = self;
            var status_buf: [4]u8 = undefined;
            const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{status_code});
            const headers = [_]quiche.h3.Header{
                .{ .name = ":status", .name_len = 7, .value = status_str.ptr, .value_len = status_str.len },
                .{ .name = "content-length", .name_len = 14, .value = "0", .value_len = 1 },
            };
            try h3_conn.sendResponse(quic_conn, stream_id, headers[0..], true);
        }

        pub fn sendErrorResponseWithAllow(self: *Self, h3_conn: *h3.H3Connection, quic_conn: *quiche.Connection, stream_id: u64, status_code: u16, allow: []const u8) !void {
            _ = self;
            var status_buf: [4]u8 = undefined;
            const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{status_code});
            const headers = [_]quiche.h3.Header{
                .{ .name = ":status", .name_len = 7, .value = status_str.ptr, .value_len = status_str.len },
                .{ .name = "allow", .name_len = 5, .value = allow.ptr, .value_len = allow.len },
                .{ .name = "content-length", .name_len = 14, .value = "0", .value_len = 1 },
            };
            try h3_conn.sendResponse(quic_conn, stream_id, headers[0..], true);
        }

        pub fn cleanupStreamState(self: *Self, conn: *connection.Connection, stream_id: u64, state: *RequestState) void {
            _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });
            if (state.on_h3_dgram != null) {
                const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(stream_id);
                _ = self.h3.dgram_flows.remove(.{ .conn = conn, .flow_id = flow_id });
            }
            state.response.deinit();
            state.arena.deinit();
            self.allocator.destroy(state);
        }
    };
}
