const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const http = @import("http");
const errors = @import("errors");
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
                        // Phase 2: enforce per-connection active request cap (if configured)
                        if (self.config.max_active_requests_per_conn > 0) {
                            const cur = conn.active_requests;
                            if (cur >= self.config.max_active_requests_per_conn) {
                                server_logging.warnf(self, "503: per-conn request cap reached (cur={}, cap={})\n", .{ cur, self.config.max_active_requests_per_conn });
                                // Respond 503 and do not create stream state
                                try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 503);
                                continue;
                            }
                        }
                        const state = try self.allocator.create(RequestState);
                        state.* = .{
                            .arena = std.heap.ArenaAllocator.init(self.allocator),
                            .request = undefined,
                            .response = undefined,
                            .handler = undefined,
                            .body_complete = false,
                            .handler_invoked = false,
                            .is_streaming = false,
                            .is_download = false,
                        };
                        errdefer {
                            state.arena.deinit();
                            self.allocator.destroy(state);
                        }

                        const arena_allocator = state.arena.allocator();
                        const headers = try h3.collectHeaders(arena_allocator, result.raw_event);

                        // Validate headers before processing (Phase 4)
                        // Check header count limit
                        if (headers.len > self.config.max_header_count) {
                            server_logging.warnf(self, "Header validation failed: HeaderCountExceeded ({}), returning 431\n", .{headers.len});
                            try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 431);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            continue;
                        }

                        // Validate individual headers
                        var validation_failed = false;
                        for (headers) |header| {
                            // Validate all header names (validateHeaderName already handles pseudo-headers correctly)
                            http.header_validation.validateHeaderName(header.name, &self.config) catch |err| {
                                const status_code: u16 = switch (err) {
                                    error.HeaderNameTooLong => 431,
                                    error.HeaderNameInvalid => 400,
                                    else => 400,
                                };
                                server_logging.warnf(self, "Header name validation failed for '{s}': {s}, returning {}\n", .{ header.name, @errorName(err), status_code });
                                try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, status_code);
                                validation_failed = true;
                                break;
                            };

                            // Validate all header values to prevent CR/LF injection and control characters
                            http.header_validation.validateHeaderValue(header.value, &self.config) catch |err| {
                                const status_code: u16 = switch (err) {
                                    error.HeaderValueTooLong => 431,
                                    error.CRLFInjectionDetected, error.ControlCharacterDetected => 400,
                                    error.HeaderValueInvalid => 400,
                                    else => 400,
                                };
                                server_logging.warnf(self, "Header value validation failed for '{s}': {s}, returning {}\n", .{ header.name, @errorName(err), status_code });
                                try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, status_code);
                                validation_failed = true;
                                break;
                            };
                        }

                        if (validation_failed) {
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            continue;
                        }

                        const req_info = h3.parseRequestHeaders(headers);

                        if (req_info.method == null or req_info.path == null) {
                            try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 400);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            continue;
                        }

                        const method_str = req_info.method.?;
                        const path_raw = req_info.path.?;
                        server_logging.infof(self, "→ HTTP/3 request: {s} {s}\n", .{ method_str, path_raw });

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
                        const clen = state.request.contentLength() orelse 0;
                        server_logging.debugf(self, "  headers parsed: content-length={}, path-decoded={s}\n", .{ clen, state.request.path_decoded });

                        // If a matcher is provided, try it first; otherwise, use dynamic router
                        {
                            const routing = @import("routing");
                            var mr: routing.MatchResult = .NotFound;
                            _ = self.matcher.vtable.match_fn(self.matcher.ctx, method, state.request.path_decoded, &mr);
                            switch (mr) {
                                .Found => |f| {
                                    server_logging.debugf(self, "  route Found; params={d}, streaming? {}\n", .{ f.params.len, (f.route.on_headers != null or f.route.on_body_chunk != null or f.route.on_body_complete != null) });
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
                                    server_logging.debugf(self, "  route NotFound\n", .{});
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
                                // Install streaming limiter callback to enforce download caps
                                state.response.setStreamingLimiter(self, responseStreamingGate);

                                try self.stream_states.put(.{ .conn = conn, .stream_id = result.stream_id }, state);
                                conn.active_requests += 1;
                                if (state.on_h3_dgram != null) {
                                    const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(result.stream_id);
                                    try self.h3.dgram_flows.put(.{ .conn = conn, .flow_id = flow_id }, state);
                                }

                                if (!state.is_streaming) {
                                    const clen2 = state.request.contentLength() orelse 0;
                                    const requires_body = (method == .POST or method == .PUT or method == .PATCH) or (clen2 > 0);
                                    if (requires_body) {
                                        server_logging.debugf(self, "  deferring non-streaming handler until body complete (clen={d})\n", .{clen2});
                                        // Handler will be invoked on .Finished after body is drained
                                    } else {
                                        server_logging.debugf(self, "  invoking non-streaming handler for {s} {s} (no body)\n", .{ method_str, state.request.path_decoded });
                                        invokeHandler(self, state) catch |err| {
                                            const mapped = http.errorToStatus(@errorCast(err));
                                            sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, mapped) catch {};
                                        };
                                    }
                                } else if (state.on_headers) |cb| {
                                    server_logging.debugf(self, "  streaming on_headers for {s} {s}\n", .{ method_str, state.request.path_decoded });
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
                                invokeHandler(self, state) catch |err| {
                                    const status = http.errorToStatus(@errorCast(err));
                                    sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, status) catch {};
                                };
                            }

                            if (state.response.isEnded() and state.response.partial_response == null) {
                                cleanupStreamState(self, conn, result.stream_id, state);
                            } else {
                                server_logging.tracef(self, "  Keeping stream {} alive for ongoing response\n", .{result.stream_id});
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

        // Locate the connection pointer from a quiche.Connection pointer by scanning the table.
        fn findConnByQuichePtr(self: *Self, q: *quiche.Connection) ?*connection.Connection {
            var it = self.connections.map.iterator();
            while (it.next()) |e| {
                if (&e.value_ptr.*.conn == q) return e.value_ptr.*;
            }
            return null;
        }

        // Streaming gate: invoked by Response before starting a file/generator partial.
        fn responseStreamingGate(ctx: *anyopaque, q_conn: *quiche.Connection, stream_id: u64, source_kind: u8) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.config.max_active_downloads_per_conn == 0) return true;

            const conn = findConnByQuichePtr(self, q_conn) orelse return true; // If unknown, allow

            const current = conn.active_downloads;
            if (current >= self.config.max_active_downloads_per_conn) {
                server_logging.warnf(self, "503: per-conn download cap reached (cur={}, cap={})\n", .{ current, self.config.max_active_downloads_per_conn });
                return false; // reject new download stream
            }

            // Mark the state as a download if we can find it
            if (self.stream_states.get(.{ .conn = conn, .stream_id = stream_id })) |st| {
                if ((source_kind == 1 or source_kind == 2) and !st.is_download) {
                    st.is_download = true;
                    conn.active_downloads += 1;
                }
            }
            return true;
        }

        fn readAvailableBody(self: *Self, h3_conn: *h3.H3Connection, conn: *connection.Connection, stream_id: u64, state: *RequestState) void {
            var buf: [16384]u8 = undefined;
            while (true) {
                const res = h3_conn.recvBody(&conn.conn, stream_id, &buf);
                if (res) |bytes_read| {
                    if (bytes_read == 0) break;
                    server_logging.tracef(self, "  DATA recv: {} bytes (streaming={} totalBuffered={})\n", .{ bytes_read, state.is_streaming, state.request.getBodySize() });
                    if (state.is_streaming) {
                        if (state.on_body_chunk) |cb| {
                            cb(&state.request, &state.response, buf[0..bytes_read]) catch |err| {
                                sendErrorResponse(self, h3_conn, &conn.conn, stream_id, http.errorToStatus(err)) catch {};
                            };
                        }
                    } else {
                        state.request.appendBody(buf[0..bytes_read], self.config.max_non_streaming_body_bytes) catch |err| {
                            const status = http.errorToStatus(@errorCast(err));
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
            // Prevent double invocation (quietly return if already invoked)
            if (state.handler_invoked) return;
            state.handler_invoked = true;

            state.handler(&state.request, &state.response) catch |err| {
                // Gracefully handle backpressure / done signals
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
            self.updateTimer(conn, timeout_ms);
        }

        pub fn sendErrorResponse(self: *Self, h3_conn: *h3.H3Connection, quic_conn: *quiche.Connection, stream_id: u64, status_code: u16) !void {
            _ = self;
            var status_buf: [4]u8 = undefined;
            const status_str = try http.StatusStrings.getWithFallback(status_code, &status_buf);
            const headers = [_]quiche.h3.Header{
                .{ .name = ":status", .name_len = 7, .value = status_str.ptr, .value_len = status_str.len },
                .{ .name = "content-length", .name_len = 14, .value = "0", .value_len = 1 },
            };
            try h3_conn.sendResponse(quic_conn, stream_id, headers[0..], true);
        }

        pub fn sendErrorResponseWithAllow(self: *Self, h3_conn: *h3.H3Connection, quic_conn: *quiche.Connection, stream_id: u64, status_code: u16, allow: []const u8) !void {
            _ = self;
            var status_buf: [4]u8 = undefined;
            const status_str = try http.StatusStrings.getWithFallback(status_code, &status_buf);
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
            if (conn.active_requests > 0) conn.active_requests -= 1;
            if (state.is_download and conn.active_downloads > 0) conn.active_downloads -= 1;
            state.response.deinit();
            state.arena.deinit();
            self.allocator.destroy(state);
        }
    };
}
