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
                        // Use atomic compare-and-swap to prevent race conditions
                        if (!conn.tryAcquireRequest(self.config.max_active_requests_per_conn)) {
                            server_logging.warnf(self, "503: per-conn request cap reached\n", .{});
                            // Respond 503 and do not create stream state
                            try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 503);
                            continue;
                        }

                        // Request slot acquired atomically - release on any error path
                        errdefer conn.releaseRequest();
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
                            // Decrement counter since we're not storing state
                            conn.releaseRequest();
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
                            // Decrement counter since we're not storing state
                            conn.releaseRequest();
                            continue;
                        }

                        const req_info = h3.parseRequestHeaders(headers);

                        if (req_info.method == null or req_info.path == null) {
                            try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 400);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            // Decrement counter since we're not storing state
                            conn.releaseRequest();
                            continue;
                        }

                        const method_str = req_info.method.?;
                        const path_raw = req_info.path.?;
                        server_logging.infof(self, "→ HTTP/3 request: {s} {s}\n", .{ method_str, path_raw });

                        const method = http.Method.fromString(method_str) orelse {
                            try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 405);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                            // Decrement counter since we're not storing state
                            conn.releaseRequest();
                            continue;
                        };

                        // MILESTONE-1: Detect WebTransport CONNECT requests
                        if (Self.WithWT and method == .CONNECT) {
                            // Check for :protocol = webtransport header
                            var is_webtransport = false;
                            var datagram_flow_id: ?u64 = null;

                            for (headers) |h| {
                                if (std.mem.eql(u8, h.name, ":protocol") and
                                    std.mem.eql(u8, h.value, "webtransport")) {
                                    is_webtransport = true;
                                }
                                if (std.mem.eql(u8, h.name, "datagram-flow-id")) {
                                    // Parse the flow ID if present
                                    datagram_flow_id = std.fmt.parseInt(u64, h.value, 10) catch null;
                                }
                            }

                            if (is_webtransport) {
                                // Check if WebTransport is enabled at runtime
                                // Must check the actual runtime flag, not just build flag
                                if (!self.wt.enabled) {
                                    server_logging.warnf(self, "WebTransport CONNECT received but WT disabled at runtime (H3_WEBTRANSPORT not set)\n", .{});
                                    try sendErrorResponse(self, h3_conn, &conn.conn, result.stream_id, 501);
                                    state.arena.deinit();
                                    self.allocator.destroy(state);
                                    conn.releaseRequest();
                                    continue;
                                }

                                state.is_webtransport = true;
                                state.wt_flow_id = datagram_flow_id orelse result.stream_id;
                                server_logging.infof(self, "→ WebTransport CONNECT: path={s}, flow_id={d}\n", .{ path_raw, state.wt_flow_id.? });
                            }
                        }

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
                                    if (f.route.on_h3_dgram) |cb| {
                                        state.on_h3_dgram = cb;
                                        state.retain_for_datagram = true;
                                    }
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
                                        // Decrement counter since we're not storing state
                                        conn.releaseRequest();
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
                                    // Decrement counter since we're not storing state
                                    conn.releaseRequest();
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

                                // MILESTONE-1: Store WebTransport callback if route supports it
                                // Note: We store the callback temporarily in user_data since handler has a different signature
                                if (mr == .Found) {
                                    const route = mr.Found.route;
                                    if (route.on_wt_session != null and state.is_webtransport) {
                                        // Store the callback pointer in user_data for later invocation
                                        state.user_data = @constCast(@ptrCast(route.on_wt_session));
                                    }
                                }

                                try self.stream_states.put(.{ .conn = conn, .stream_id = result.stream_id }, state);
                                // Request counter already incremented after cap check to prevent race condition
                                // State successfully stored, cleanupStreamState will handle counter decrement

                                // MILESTONE-1: Create WebTransportSession if this is a WT CONNECT
                                if (state.is_webtransport and Self.WithWT) {
                                    // Create WebTransportSession
                                    const wt_session = try h3.WebTransportSession.init(
                                        self.allocator,
                                        result.stream_id, // session_id is the CONNECT stream ID
                                        &conn.conn,
                                        h3_conn,
                                        state.request.path_decoded,
                                    );
                                    errdefer wt_session.deinit();

                                    // Create WebTransportSessionState wrapper
                                    // Convert headers to quiche.h3.Header format
                                    // IMPORTANT: Don't free wt_headers - WebTransportSessionState owns them
                                    // The session will manage this memory through its arena
                                    const wt_headers = try self.allocator.alloc(quiche.h3.Header, headers.len);
                                    errdefer self.allocator.free(wt_headers);

                                    // Deep copy header data so it survives beyond the request arena
                                    for (headers, 0..) |h, i| {
                                        // Duplicate the header strings into persistent memory
                                        const name_copy = try self.allocator.dupe(u8, h.name);
                                        errdefer self.allocator.free(name_copy);
                                        const value_copy = try self.allocator.dupe(u8, h.value);
                                        errdefer self.allocator.free(value_copy);

                                        wt_headers[i] = .{
                                            .name = name_copy.ptr,
                                            .name_len = name_copy.len,
                                            .value = value_copy.ptr,
                                            .value_len = value_copy.len,
                                        };
                                    }

                                    const wt_state = try h3.WebTransportSessionState.init(
                                        self.allocator,
                                        wt_session,
                                        wt_headers,
                                        null, // on_datagram callback will be set by route handler if needed
                                    );
                                    errdefer wt_state.deinit(self.allocator);

                                    // Store session in server maps
                                    try self.wt.sessions.put(.{ .conn = conn, .session_id = result.stream_id }, wt_state);
                                    const flow_id = state.wt_flow_id orelse result.stream_id;
                                    try self.wt.dgram_map.put(.{ .conn = conn, .flow_id = flow_id }, wt_state);

                                    // Link session to request state
                                    state.wt_session = wt_state;
                                    wt_state.flow_id = flow_id;
                                    const session_wrapper = try Self.WTApi.createSession(self, conn, wt_state);

                                    // Update metrics
                                    self.wt.sessions_created += 1;
                                    wt_state.last_activity_ms = std.time.milliTimestamp();

                                    server_logging.infof(self, "WebTransport session created: id={d}, path={s}\n", .{ result.stream_id, state.request.path_decoded });

                                    // MILESTONE-1: Send 200 OK and invoke route callback
                                    try state.response.finishConnect(state.wt_flow_id);

                                    // Invoke the on_wt_session callback if provided by the route
                                    if (state.user_data) |callback_ptr| {
                                        // Cast user_data back to WebTransport session callback type
                                        const wt_handler = @as(http.handler.OnWebTransportSession, @ptrCast(@alignCast(callback_ptr)));
                                        wt_handler(&state.request, session_wrapper.asAnyOpaque()) catch |err| {
                                            server_logging.warnf(self, "WebTransport session handler error: {s}\n", .{@errorName(err)});
                                            // Close the session on error
                                            // TODO: Send proper error capsule
                                            _ = conn.conn.streamShutdown(result.stream_id, .write, 0) catch {};
                                        };
                                    }

                                    // WebTransport session is now active; skip normal request processing
                                    continue;
                                } else if (state.on_h3_dgram != null) {
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
                        // Decrement counter since we're not storing state
                        conn.releaseRequest();
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
            std.debug.print("[DEBUG] responseStreamingGate: stream_id={}, source_kind={}, max_downloads={}\n", .{ stream_id, source_kind, self.config.max_active_downloads_per_conn });

            // Memory streams (source_kind=0) bypass download cap checks entirely
            if (source_kind == 0) {
                std.debug.print("[DEBUG] responseStreamingGate: memory stream (source_kind=0), bypassing download cap\n", .{});
                return true;
            }

            if (self.config.max_active_downloads_per_conn == 0) return true;

            const conn = findConnByQuichePtr(self, q_conn) orelse {
                std.debug.print("[DEBUG] responseStreamingGate: conn not found, allowing\n", .{});
                return true; // If unknown, allow
            };

            // Try to acquire download slot atomically
            if (!conn.tryAcquireDownload(self.config.max_active_downloads_per_conn)) {
                const current = conn.active_downloads.load(.acquire);
                server_logging.warnf(self, "503: per-conn download cap reached (cur={}, cap={})\n", .{ current, self.config.max_active_downloads_per_conn });
                std.debug.print("[DEBUG] responseStreamingGate: REJECTING (limit reached)\n", .{});
                return false; // reject new download stream
            }

            // Mark the state as a download if we can find it (only for file/generator, not memory)
            if (self.stream_states.get(.{ .conn = conn, .stream_id = stream_id })) |st| {
                if ((source_kind == 1 or source_kind == 2) and !st.is_download) {
                    const current = conn.active_downloads.load(.acquire);
                    std.debug.print("[DEBUG] responseStreamingGate: marking stream {} as download, count is now {}\n", .{ stream_id, current });
                    st.is_download = true;
                    // Download counter already incremented atomically by tryAcquireDownload
                }
            } else {
                // If we can't find the state, release the download slot we just acquired
                conn.releaseDownload();
            }
            std.debug.print("[DEBUG] responseStreamingGate: ALLOWING stream\n", .{});
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

            if (!state.response.isEnded() and state.response.partial_response == null and state.response.shouldAutoEnd()) {
                try state.response.end(null);
            }
        }

        pub fn processWritableStreams(self: *Self, conn: *connection.Connection) !void {
            while (conn.conn.streamWritableNext()) |stream_id| {
                if (self.stream_states.get(.{ .conn = conn, .stream_id = stream_id })) |state| {
                    // First try to flush any buffered capsule data (for WebTransport)
                    if (state.response.capsule_buffer != null) {
                        state.response.flushCapsuleBuffer() catch |err| {
                            if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                                // Stream still blocked, will retry later
                            } else {
                                std.debug.print("Error flushing capsule buffer for stream {}: {}\n", .{ stream_id, err });
                            }
                        };
                    }

                    if (state.response.partial_response != null) {
                        state.response.processPartialResponse() catch |err| {
                            if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                                continue;
                            }
                            std.debug.print("Error processing partial response for stream {}: {}\n", .{ stream_id, err });
                            if (state.on_h3_dgram != null and state.retain_for_datagram and !state.datagram_detached) {
                                state.datagram_detached = true;
                                state.retain_for_datagram = false;
                                conn.releaseRequest();
                                if (state.is_download) conn.releaseDownload();
                                _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });
                            } else {
                                if (state.on_h3_dgram != null) {
                                    const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(stream_id);
                                    _ = self.h3.dgram_flows.remove(.{ .conn = conn, .flow_id = flow_id });
                                }
                                state.response.deinit();
                                state.arena.deinit();
                                self.allocator.destroy(state);
                                _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });
                            }
                        };

                        if (state.response.isEnded() and state.response.partial_response == null) {
                            if (state.on_h3_dgram != null and state.retain_for_datagram and !state.datagram_detached) {
                                state.datagram_detached = true;
                                state.retain_for_datagram = false;
                                conn.releaseRequest();
                                if (state.is_download) conn.releaseDownload();
                                _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });
                            } else {
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

            // MILESTONE-1: Handle WebTransport session cleanup
            if (state.is_webtransport and Self.WithWT) {
                if (state.wt_session) |wt_state| {
                    self.destroyWtSessionState(conn, stream_id, wt_state);
                    state.wt_session = null;
                }

                // Don't destroy the response until WT session is fully closed
                // The CONNECT stream stays open for the session lifetime
                conn.releaseRequest();
                if (state.is_download) conn.releaseDownload();
                state.response.deinit();
                state.arena.deinit();
                self.allocator.destroy(state);
                return;
            }

            if (state.on_h3_dgram != null and state.retain_for_datagram and !state.datagram_detached) {
                state.datagram_detached = true;
                state.retain_for_datagram = false;
                conn.releaseRequest();
                if (state.is_download) conn.releaseDownload();
                return;
            }
            if (state.on_h3_dgram != null) {
                const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(stream_id);
                _ = self.h3.dgram_flows.remove(.{ .conn = conn, .flow_id = flow_id });
            }
            conn.releaseRequest();
            if (state.is_download) conn.releaseDownload();
            state.response.deinit();
            state.arena.deinit();
            self.allocator.destroy(state);
        }
    };
}
