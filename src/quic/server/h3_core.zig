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
        const RequestState = @import("mod.zig").RequestState;

        fn onDatagramSentForward(ctx: *anyopaque, _bytes: usize) void {
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
                            try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 400);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            continue;
                        }

                        const method_str = req_info.method.?;
                        const path_raw = req_info.path.?;
                        if (server_logging.appDebug(self)) {
                            std.debug.print("→ HTTP/3 request: {s} {s}\n", .{ method_str, path_raw });
                        }

                        const method = http.Method.fromString(method_str) orelse {
                            try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 405);
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
                        if (server_logging.appDebug(self)) {
                            const clen = state.request.contentLength() orelse 0;
                            std.debug.print("  headers parsed: content-length={}, path-decoded={s}\n", .{clen, state.request.path_decoded});
                        }

                        // If a matcher is provided, try it first; otherwise, use dynamic router
                        {
                            const routing = @import("routing");
                            var mr: routing.MatchResult = .NotFound;
                            _ = self.matcher.vtable.match_fn(self.matcher.ctx, method, state.request.path_decoded, &mr);
                            switch (mr) {
                                .Found => |f| {
                                    if (server_logging.appDebug(self)) {
                                        std.debug.print("  route Found; params={d}, streaming? {}\n", .{ f.params.len, (f.route.on_headers != null or f.route.on_body_chunk != null or f.route.on_body_complete != null) });
                                    }
                                    // Build params into request map (copy strings to arena to ensure they persist)
                                    var params = std.StringHashMapUnmanaged([]const u8){};
                                    for (f.params) |p| {
                                        const name_copy = state.arena.allocator().dupe(u8, p.name) catch continue;
                                        const value_copy = state.arena.allocator().dupe(u8, p.value) catch continue;
                                        params.put(state.arena.allocator(), name_copy, value_copy) catch {};
                                    }
                                    state.request.params = params;

                                    // Install handler/callbacks
                                    if (f.route.on_h3_dgram) |cb| state.on_h3_dgram = cb;
                                    if (f.route.on_headers != null or f.route.on_body_chunk != null or f.route.on_body_complete != null) {
                                        state.is_streaming = true;
                                        state.on_headers = f.route.on_headers;
                                        state.on_body_chunk = f.route.on_body_chunk;
                                        state.on_body_complete = f.route.on_body_complete;
                                    } else if (f.route.handler) |h| {
                                        state.handler = h;
                                    } else {
                                        // No handler and no streaming callbacks → 500
                                        try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 500);
                                        state.arena.deinit();
                                        self.allocator.destroy(state);
                                        continue;
                                    }
                                },
                                .PathMatched => |pm| {
                                    // Build Allow header and respond 405
                                    const allow_heap = http.formatAllowFromEnumSet(self.allocator, pm.allowed) catch "";
                                    defer if (allow_heap.len > 0) self.allocator.free(allow_heap);
                                    try sendErrorResponseWithAllow(self, h3_conn, &conn.conn, result.stream_id, 405, allow_heap);
                                    state.arena.deinit();
                                    self.allocator.destroy(state);
                                    continue;
                                },
                                .NotFound => {
                                    // fall through to dynamic router
                                    if (server_logging.appDebug(self)) {
                                        std.debug.print("  route NotFound\n", .{});
                                    }
                                },
                            }
                            if (mr != .NotFound) {
                                // Initialize Response (same as below) and proceed
                                state.response = http.Response.init(
                                    self.allocator,
                                    h3_conn,
                                    &conn.conn,
                                    result.stream_id,
                                    method == .HEAD,
                                );

                                try self.stream_states.put(.{ .conn = conn, .stream_id = result.stream_id }, state);
                                if (state.on_h3_dgram != null) {
                                    const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(result.stream_id);
                                    try self.h3.dgram_flows.put(.{ .conn = conn, .flow_id = flow_id }, state);
                                }

                                if (!state.is_streaming) {
                                    const clen = state.request.contentLength() orelse 0;
                                    const requires_body = (method == .POST or method == .PUT or method == .PATCH) or (clen > 0);
                                    if (requires_body) {
                                        if (server_logging.appDebug(self)) {
                                            std.debug.print("  deferring non-streaming handler until body complete (clen={d})\n", .{clen});
                                        }
                                        // Handler will be invoked on .Finished after body is drained
                                    } else {
                                        if (server_logging.appDebug(self)) {
                                            std.debug.print("  invoking non-streaming handler for {s} {s} (no body)\n", .{ method_str, state.request.path_decoded });
                                        }
                                        invokeHandler(self, state) catch |err| {
                                            const status = switch (err) {
                                                error.StreamBlocked, error.Done => @as(u16, 503),
                                                else => @as(u16, 500),
                                            };
                                            sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, status) catch {};
                                        };
                                    }
                                } else if (state.on_headers) |cb| {
                                    if (server_logging.appDebug(self)) {
                                        std.debug.print("  streaming on_headers for {s} {s}\n", .{ method_str, state.request.path_decoded });
                                    }
                                    cb(&state.request, &state.response) catch |err| {
                                        sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                    };
                                }
                                continue;
                            }
                        }
                        // No match from matcher → NotFound (the legacy router switch is removed)
                        try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 404);
                        state.arena.deinit();
                        self.allocator.destroy(state);
                        continue;
                    },
                    .Data => {
                        if (self.stream_states.get(.{ .conn = conn, .stream_id = result.stream_id })) |state| {
                            readAvailableBody(self, h3_conn, conn, result.stream_id, state);
                        }
                    },
                    .Finished => {
                        if (self.stream_states.get(.{ .conn = conn, .stream_id = result.stream_id })) |state| {
                            state.body_complete = true;
                            if (state.is_streaming) {
                                if (state.on_body_complete) |cb| {
                                    cb(&state.request, &state.response) catch |err| {
                                        sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                    };
                                }
                            } else if (!state.handler_invoked) {
                                // Ensure any remaining body bytes are drained for non-streaming handlers
                                readAvailableBody(self, h3_conn, conn, result.stream_id, state);
                                invokeHandler(self, state) catch {
                                    sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 500) catch {};
                                };
                            }

                            if (state.response.isEnded() and state.response.partial_response == null) {
                                cleanupStreamState(self, conn, result.stream_id, state);
                            } else {
                                std.debug.print("  Keeping stream {} alive for ongoing response\n", .{result.stream_id});
                            }
                        }
                    },
                    .GoAway, .Reset => {
                        std.debug.print("  Stream {} closed ({})\n", .{ result.stream_id, result.event_type });
                        if (self.stream_states.fetchRemove(.{ .conn = conn, .stream_id = result.stream_id })) |entry| {
                            cleanupStreamState(self, conn, result.stream_id, entry.value);
                        }
                    },
                    .PriorityUpdate => {},
                }
            }
        }

        fn readAvailableBody(self: *Self, h3_conn: *h3.H3Connection, conn: *connection.Connection, stream_id: u64, state: *RequestState) void {
            var buf: [16384]u8 = undefined;
            while (true) {
                const res = h3_conn.recvBody(&conn.conn, stream_id, &buf);
                if (res) |bytes_read| {
                    if (bytes_read == 0) break;
                    if (server_logging.appDebug(self)) {
                        std.debug.print("  DATA recv: {} bytes (streaming={} totalBuffered={})\n", .{ bytes_read, state.is_streaming, state.request.getBodySize() });
                    }
                    if (state.is_streaming) {
                        if (state.on_body_chunk) |cb| {
                            cb(&state.request, &state.response, buf[0..bytes_read]) catch |err| {
                                sendErrorResponse(self, h3_conn, &conn.conn, stream_id, http.errorToStatus(err)) catch {};
                            };
                        }
                    } else {
                        state.request.appendBody(buf[0..bytes_read], 1 * 1024 * 1024) catch |err| {
                            const status: u16 = if (err == error.PayloadTooLarge) 413 else 500;
                            sendErrorResponse(self, h3_conn, &conn.conn, stream_id, status) catch {};
                        };
                    }
                    continue;
                } else |e| {
                    // Stop on would-block conditions; keep other errors quiet for now
                    switch (e) {
                        quiche.h3.Error.Done, quiche.h3.Error.StreamBlocked => return,
                        else => return,
                    }
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
