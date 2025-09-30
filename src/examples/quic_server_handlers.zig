// Shared handlers for the QUIC server examples (static and dynamic)
const std = @import("std");
const http = @import("http");
const event_loop = @import("event_loop");
const QuicServer = @import("server").QuicServer;
const RequestState = QuicServer.RequestStateType;

// Global configuration for handlers
pub var g_files_dir: []const u8 = ".";

pub fn indexHandler(_: *http.Request, res: *http.Response) http.HandlerError!void {
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>QUIC/HTTP3 Server</title></head>
        \\<body>
        \\<h1>Welcome to Zig QUIC/HTTP3 Server!</h1>
        \\<ul>
        \\  <li><a href=\"/api/users\">/api/users</a> - List users</li>
        \\  <li><a href=\"/api/users/123\">/api/users/123</a> - Get user by ID</li>
        \\  <li><a href=\"/files/test.txt\">/files/test.txt</a> - Wildcard route</li>
        \\  <li><a href=\"/slow\">/slow</a> - Slow response (default 1s delay)</li>
        \\  <li><a href=\"/slow?delay=3000\">/slow?delay=3000</a> - Slow response (3s delay)</li>
        \\</ul>
        \\</body>
        \\</html>
    ;
    res.header(http.Headers.ContentType, http.MimeTypes.TextHtml) catch return error.InternalServerError;
    res.writeAll(html) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
    res.end(null) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

pub fn listUsersHandler(_: *http.Request, res: *http.Response) http.HandlerError!void {
    const users = [_]struct { id: u32, name: []const u8 }{
        .{ .id = 1, .name = "Alice" },
        .{ .id = 2, .name = "Bob" },
        .{ .id = 3, .name = "Charlie" },
    };
    res.jsonValue(users) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

pub fn getUserHandler(req: *http.Request, res: *http.Response) http.HandlerError!void {
    const id = req.getParam("id") orelse return error.BadRequest;
    const user = struct { id: []const u8, name: []const u8 }{
        .id = id,
        .name = try std.fmt.allocPrint(req.arena.allocator(), "User {s}", .{id}),
    };
    res.jsonValue(user) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

pub fn filesHandler(req: *http.Request, res: *http.Response) http.HandlerError!void {
    const wildcard_path = req.getParam("*") orelse "";
    const response = struct { requested_file: []const u8, note: []const u8 }{
        .requested_file = wildcard_path,
        .note = "This is a wildcard route demo",
    };
    res.jsonValue(response) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

pub fn echoHandler(req: *http.Request, res: *http.Response) http.HandlerError!void {
    const body = try req.readAll(1024 * 1024);
    const content_type = req.contentType() orelse "text/plain";
    const response = struct {
        received_bytes: usize,
        content_type: []const u8,
        echo: []const u8,
    }{ .received_bytes = body.len, .content_type = content_type, .echo = body };
    res.jsonValue(response) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

pub fn createUserHandler(req: *http.Request, res: *http.Response) http.HandlerError!void {
    const body = try req.readAll(1024 * 1024); // 1MB max
    std.debug.print("[server] received body len={d} data={s}", .{ body.len, body });

    if (body.len > 0) {
        res.status(@intFromEnum(http.Status.Created)) catch return error.InternalServerError;
        const response = struct {
            message: []const u8,
            received: []const u8,
        }{
            .message = "User created",
            .received = body,
        };
        res.jsonValue(response) catch |err| switch (err) {
            error.StreamBlocked => return error.StreamBlocked,
            else => return error.InternalServerError,
        };
    } else {
        res.jsonError(400, "Request body required") catch |err| switch (err) {
            error.StreamBlocked => return error.StreamBlocked,
            else => return error.InternalServerError,
        };
    }
}

// --- Streaming upload echo (callbacks) ---
pub fn uploadEchoOnHeaders(_: *http.Request, res: *http.Response) http.StreamingError!void {
    res.status(200) catch return error.InvalidState;
    res.header(http.Headers.ContentType, "text/plain") catch return error.InvalidState;
}

pub fn uploadEchoOnChunk(_: *http.Request, res: *http.Response, chunk: []const u8) http.StreamingError!void {
    res.writeAll(chunk) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InvalidState,
    };
}

pub fn uploadEchoOnComplete(_: *http.Request, res: *http.Response) http.StreamingError!void {
    res.end(null) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InvalidState,
    };
}

pub fn h3dgramEchoHandler(_: *http.Request, res: *http.Response) http.HandlerError!void {
    res.status(200) catch return error.InvalidState;
    res.writeAll(
        \\H3 DATAGRAM Echo Endpoint
        \\=========================
        \\
        \\Send HTTP/3 DATAGRAMs to this request's flow_id to receive echo responses.
        \\The flow_id for this request is the stream_id.
        \\H3 DATAGRAMs will be echoed back using Response.sendH3Datagram().
        \\
    ) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
    res.end(null) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

pub fn h3dgramEchoCallback(req: *http.Request, res: *http.Response, payload: []const u8) http.DatagramError!void {
    if (payload.len == 0) return;

    res.sendH3Datagram(payload) catch |err| {
        if (err == error.WouldBlock) {
            if (g_quic_server) |server| {
                if (req.state_ptr) |state_any| {
                    const state = @as(*RequestState, @ptrCast(@alignCast(state_any)));
                    server.queueH3Datagram(state, payload) catch return;
                    server.requestFlush();
                }
            }
            return;
        }
        if (err == error.DatagramTooLarge or err == error.H3DatagramNotEnabled) return;
        return error.ConnectionClosed;
    };

    if (g_quic_server) |server| {
        server.requestFlush();
    }
}

pub fn wtConnectInfoHandler(_: *http.Request, res: *http.Response) http.HandlerError!void {
    res.status(@intFromEnum(http.Status.BadRequest)) catch return error.InternalServerError;
    res.header(http.Headers.ContentType, http.MimeTypes.TextPlain) catch return error.InternalServerError;
    res.writeAll(
        "WebTransport requires Extended CONNECT requests with :protocol = webtransport\n",
    ) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
    res.end(null) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

pub fn wtEchoSessionHandler(_: *http.Request, session_ptr: *anyopaque) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);
    std.debug.print(
        "[server] wtEchoSessionHandler enable_streams={s} enable_bidi={s} wt_enabled={s}\n",
        .{
            if (session.server.wt.enable_streams) "true" else "false",
            if (session.server.wt.enable_bidi) "true" else "false",
            if (session.server.wt.enabled) "true" else "false",
        },
    );

    session.setDatagramHandler(wtEchoDatagram);

    if (session.server.wt.enable_streams) {
        session.setStreamDataHandler(wtEchoStreamData) catch |err| switch (err) {
            error.InvalidState => {},
            else => return err,
        };
        session.setStreamClosedHandler(wtStreamClosed) catch |err| switch (err) {
            error.InvalidState => {},
            else => return err,
        };
        session.setUniOpenHandler(wtUniOpen) catch |err| switch (err) {
            error.InvalidState => {},
            else => return err,
        };
        if (session.server.wt.enable_bidi) {
            session.setBidiOpenHandler(wtBidiOpen) catch |err| switch (err) {
                error.InvalidState => {},
                else => return err,
            };
        }
    }

    try session.accept(.{});
}

fn wtEchoDatagram(session_ptr: *anyopaque, payload: []const u8) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);
    if (payload.len == 0) return;
    try session.sendDatagram(payload);
}

pub fn wtCloseSessionHandler(_: *http.Request, session_ptr: *anyopaque) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);
    try session.accept(.{});
    session.close(.{ .code = 0x10, .reason = "server closing" }) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };
}

pub fn wtRejectSessionHandler(_: *http.Request, session_ptr: *anyopaque) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);
    try session.reject(.{ .status = 403 });
}

fn wtRejectDatagram(session_ptr: *anyopaque, payload: []const u8) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);
    std.debug.print(
        "[server] wtRejectDatagram payload_len={d} session={d}\n",
        .{ payload.len, session.sessionId() },
    );
    return error.StreamBlocked;
}

pub fn wtRejectDatagramSessionHandler(_: *http.Request, session_ptr: *anyopaque) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);
    try session.accept(.{});
    session.setDatagramHandler(wtRejectDatagram);
}

fn wtUniOpen(_: *anyopaque, _: *anyopaque) http.WebTransportStreamError!void {
    // No-op: stream data handler handles echoing.
    return;
}

fn wtBidiOpen(_: *anyopaque, _: *anyopaque) http.WebTransportStreamError!void {
    return;
}

fn wtEchoStreamData(stream_ptr: *anyopaque, data: []const u8, fin: bool) http.WebTransportStreamError!void {
    const stream = QuicServer.WebTransportStream.fromOpaque(stream_ptr);
    std.debug.print(
        "[server] wtEchoStreamData stream={d} session={d} recv_len={d} fin={s} pending_before={d}\n",
        .{
            stream.id(),
            stream.stream.session_id,
            data.len,
            if (fin) "true" else "false",
            stream.stream.pending.items.len,
        },
    );
    if (data.len > 0) {
        _ = stream.send(data, false) catch |err| switch (err) {
            error.WouldBlock => {
                std.debug.print(
                    "[server] wtEchoStreamData would block stream={d} session={d} pending_now={d}\n",
                    .{ stream.id(), stream.stream.session_id, stream.stream.pending.items.len },
                );
                stream.server.requestFlush();
                return error.WouldBlock;
            },
            else => return err,
        };
        stream.server.requestFlush();
    }
    if (fin) {
        _ = stream.send(&[_]u8{}, true) catch |err| switch (err) {
            error.WouldBlock => {
                std.debug.print(
                    "[server] wtEchoStreamData fin would block stream={d} session={d} pending_now={d}\n",
                    .{ stream.id(), stream.stream.session_id, stream.stream.pending.items.len },
                );
                stream.server.requestFlush();
                return;
            },
            else => return err,
        };
        stream.server.requestFlush();
    }
}

fn wtStreamClosed(stream_ptr: *anyopaque) void {
    const stream = QuicServer.WebTransportStream.fromOpaque(stream_ptr);
    std.debug.print("[server] WT stream {d} closed\n", .{stream.id()});
}

pub fn registerEventLoop(loop: *event_loop.EventLoop) void {
    g_event_loop = loop;
}

var g_event_loop: ?*event_loop.EventLoop = null;
var g_quic_server: ?*QuicServer = null;

pub fn registerServer(server: *QuicServer) void {
    g_quic_server = server;
}

const SlowTimerContext = struct {
    loop: *event_loop.EventLoop,
    allocator: std.mem.Allocator,
    timer: event_loop.TimerHandle,
    response: *http.Response,
    cancelled: bool = false,
};

const slow_body = "Slow response completed\n";

fn slowTimerCancel(ctx_ptr: ?*anyopaque) void {
    if (ctx_ptr == null) return;
    const ctx = @as(*SlowTimerContext, @ptrCast(@alignCast(ctx_ptr.?)));
    ctx.cancelled = true;
    ctx.loop.stopTimer(ctx.timer);
    ctx.loop.destroyTimer(ctx.timer);
    std.debug.print("[slowTimer] cancel for stream {d}\n", .{ctx.response.stream_id});
    ctx.allocator.destroy(ctx);
}

fn slowTimerFire(ctx_ptr: ?*anyopaque) void {
    if (ctx_ptr == null) return;
    const ctx = @as(*SlowTimerContext, @ptrCast(@alignCast(ctx_ptr.?)));
    defer ctx.allocator.destroy(ctx);

    if (ctx.cancelled) {
        ctx.loop.destroyTimer(ctx.timer);
        return;
    }

    ctx.loop.destroyTimer(ctx.timer);

    const res = ctx.response;
    res.clearCleanup();

    res.enableAutoEnd();

    std.debug.print("[slowTimer] firing for stream {d}\n", .{res.stream_id});

    const body_copy = res.allocator.dupe(u8, slow_body) catch {
        std.debug.print("[slowTimer] stream {d} failed to dup body\n", .{res.stream_id});
        return;
    };

    res.partial_response = http.streaming.PartialResponse.initMemory(res.allocator, body_copy, true) catch {
        res.allocator.free(body_copy);
        std.debug.print("[slowTimer] stream {d} failed to init partial response\n", .{res.stream_id});
        return;
    };

    res.processPartialResponse() catch |err| switch (err) {
        error.StreamBlocked => {
            std.debug.print("[slowTimer] stream {d} initial process blocked\n", .{res.stream_id});
        },
        else => {
            std.debug.print("[slowTimer] stream {d} process error {s}\n", .{ res.stream_id, @errorName(err) });
            return;
        },
    };

    if (g_quic_server) |server| {
        server.requestFlush();
    }
}

// === Slow response handler (for testing concurrency) ===
pub fn slowStreamOnHeaders(req: *http.Request, res: *http.Response) http.StreamingError!void {
    // Reuse logic from blocking handler but without blocking the event loop when available
    const delay_ms = if (req.query.get("delay")) |d|
        std.fmt.parseUnsigned(u64, d, 10) catch 1000
    else
        1000;

    try res.status(200);
    try res.header("content-type", "text/plain");

    if (g_event_loop) |loop| {
        const ctx = loop.allocator.create(SlowTimerContext) catch return error.OutOfMemory;
        ctx.* = .{
            .loop = loop,
            .allocator = loop.allocator,
            .timer = undefined,
            .response = res,
            .cancelled = false,
        };

        const timer = loop.createTimer(slowTimerFire, ctx) catch {
            loop.allocator.destroy(ctx);
            return error.InvalidState;
        };
        ctx.timer = timer;
        res.onCleanup(ctx, slowTimerCancel);
        const after_s = @as(f64, @floatFromInt(delay_ms)) / 1000.0;
        loop.startTimer(timer, after_s, 0);
        res.deferEnd();
        std.debug.print("[slowHandler] scheduled timer stream {d} delay_ms={d}\n", .{ res.stream_id, delay_ms });
        return;
    }

    std.Thread.sleep(delay_ms * std.time.ns_per_ms);

    res.writeAll(slow_body) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        error.ResponseEnded => return error.ResponseEnded,
        else => return error.InvalidState,
    };
    res.end(null) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        error.ResponseEnded => return error.ResponseEnded,
        else => return error.InvalidState,
    };
}

// === File download handler ===
pub fn downloadHandler(req: *http.Request, res: *http.Response) http.HandlerError!void {
    const file_path = req.getParam("*") orelse "";

    // Build absolute path (safely, avoiding path traversal)
    const allocator = req.arena.allocator();

    // Enhanced safety checks
    if (req.path_decoded.len >= 11 and
        std.mem.startsWith(u8, req.path_decoded, "/download/") and
        req.path_decoded[10] == '/')
    {
        res.jsonError(404, "File not found") catch |err| switch (err) {
            error.StreamBlocked => return error.StreamBlocked,
            else => return error.InternalServerError,
        };
        return;
    }

    if (std.mem.indexOf(u8, file_path, "..") != null) {
        res.jsonError(404, "File not found") catch |err| switch (err) {
            error.StreamBlocked => return error.StreamBlocked,
            else => return error.InternalServerError,
        };
        return;
    }

    if (std.fs.path.isAbsolute(file_path)) {
        res.jsonError(404, "File not found") catch |err| switch (err) {
            error.StreamBlocked => return error.StreamBlocked,
            else => return error.InternalServerError,
        };
        return;
    }

    if (file_path.len == 0) {
        res.jsonError(400, "File path required") catch |err| switch (err) {
            error.StreamBlocked => return error.StreamBlocked,
            else => return error.InternalServerError,
        };
        return;
    }

    // Get absolute path of files directory
    const files_dir_abs = std.fs.cwd().realpathAlloc(allocator, g_files_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InternalServerError,
    };
    defer allocator.free(files_dir_abs);

    // Join with the requested file path
    const full_path = std.fs.path.join(allocator, &.{ files_dir_abs, file_path }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    const file = std.fs.openFileAbsolute(full_path, .{}) catch |open_err| {
        switch (open_err) {
            error.FileNotFound => {
                res.jsonError(404, "File not found") catch |e| switch (e) {
                    error.StreamBlocked => return error.StreamBlocked,
                    else => return error.InternalServerError,
                };
                return;
            },
            error.AccessDenied => {
                res.jsonError(403, "Access denied") catch |e| switch (e) {
                    error.StreamBlocked => return error.StreamBlocked,
                    else => return error.InternalServerError,
                };
                return;
            },
            else => {
                res.jsonError(500, "Internal server error") catch |e| switch (e) {
                    error.StreamBlocked => return error.StreamBlocked,
                    else => return error.InternalServerError,
                };
                return;
            },
        }
    };
    errdefer file.close();

    const stat = file.stat() catch |err| switch (err) {
        error.SystemResources => return error.InternalServerError,
        error.AccessDenied => return error.Forbidden,
        error.Unexpected => return error.InternalServerError,
        error.PermissionDenied => return error.Forbidden,
    };
    const file_size = stat.size;

    res.setAcceptRangesBytes() catch return error.InternalServerError;

    const range_header = req.getHeader(http.Headers.Range);

    if (range_header) |range_str| {
        const range_spec = http.range.parseRange(range_str, file_size) catch |parse_err| {
            switch (parse_err) {
                error.Unsatisfiable => {
                    res.status(@intFromEnum(http.Status.RangeNotSatisfiable)) catch return error.InternalServerError;
                    res.setContentRangeUnsatisfied(file_size) catch return error.InternalServerError;
                    res.header(http.Headers.ContentLength, "0") catch return error.InternalServerError;
                    res.end(null) catch |e| switch (e) {
                        error.StreamBlocked => return error.StreamBlocked,
                        else => return error.InternalServerError,
                    };
                    file.close();
                    return;
                },
                error.MultiRange, error.NonBytesUnit, error.Malformed => {
                    try sendFullFile(res, file, file_size, full_path);
                    return;
                },
            }
        };

        res.status(@intFromEnum(http.Status.PartialContent)) catch return error.InternalServerError;
        res.setContentRange(range_spec.start, range_spec.end, file_size) catch return error.InternalServerError;

        const range_length = range_spec.end - range_spec.start + 1;
        res.setContentLength(range_length) catch return error.InternalServerError;

        setContentTypeFromPath(res, full_path) catch return error.InternalServerError;

        if (res.is_head_request) {
            res.end(null) catch |e| switch (e) {
                error.StreamBlocked => return error.StreamBlocked,
                else => return error.InternalServerError,
            };
            file.close();
            return;
        }

        const chunk_sz = http.streaming.getDefaultChunkSize();
        res.partial_response = http.streaming.PartialResponse.initFileRange(res.allocator, file, file_size, @intCast(range_spec.start), @intCast(range_spec.end), chunk_sz, true) catch |err| switch (err) {
            error.InvalidRange => return error.BadRequest,
            error.OutOfMemory => return error.OutOfMemory,
        };

        res.processPartialResponse() catch return error.InternalServerError;
    } else {
        try sendFullFile(res, file, file_size, full_path);
    }
}

fn sendFullFile(res: *http.Response, file: std.fs.File, file_size: u64, full_path: []const u8) http.HandlerError!void {
    res.setContentLength(file_size) catch return error.InternalServerError;
    setContentTypeFromPath(res, full_path) catch return error.InternalServerError;

    if (res.is_head_request) {
        res.end(null) catch |e| switch (e) {
            error.StreamBlocked => return error.StreamBlocked,
            else => return error.InternalServerError,
        };
        file.close();
        return;
    }

    const chunk_sz = http.streaming.getDefaultChunkSize();
    res.partial_response = try http.streaming.PartialResponse.initFile(res.allocator, file, file_size, chunk_sz, true);

    res.processPartialResponse() catch return error.InternalServerError;
}

fn setContentTypeFromPath(res: *http.Response, file_path: []const u8) http.HandlerError!void {
    const ext = std.fs.path.extension(file_path);
    if (std.mem.eql(u8, ext, ".html")) {
        res.header(http.Headers.ContentType, http.MimeTypes.TextHtml) catch return error.InternalServerError;
    } else if (std.mem.eql(u8, ext, ".css")) {
        res.header(http.Headers.ContentType, http.MimeTypes.TextCss) catch return error.InternalServerError;
    } else if (std.mem.eql(u8, ext, ".js")) {
        res.header(http.Headers.ContentType, http.MimeTypes.TextJavascript) catch return error.InternalServerError;
    } else if (std.mem.eql(u8, ext, ".json")) {
        res.header(http.Headers.ContentType, http.MimeTypes.ApplicationJson) catch return error.InternalServerError;
    } else {
        res.header(http.Headers.ContentType, http.MimeTypes.ApplicationOctetStream) catch return error.InternalServerError;
    }
}

// === Streaming handlers ===

const OneGBContext = struct {
    pattern: []const u8,
    total_written: usize,
    total_size: usize,
};

fn generate1GB(ctx: *anyopaque, buf: []u8) http.GeneratorError!usize {
    const context = @as(*OneGBContext, @ptrCast(@alignCast(ctx)));

    if (context.total_written >= context.total_size) {
        return 0; // Done generating
    }

    var written: usize = 0;
    while (written < buf.len and context.total_written < context.total_size) {
        const pattern_offset = context.total_written % context.pattern.len;
        const to_copy = @min(context.pattern.len - pattern_offset, buf.len - written, context.total_size - context.total_written);

        @memcpy(buf[written..][0..to_copy], context.pattern[pattern_offset..][0..to_copy]);
        written += to_copy;
        context.total_written += to_copy;
    }

    return written;
}

pub fn stream1GBHandler(req: *http.Request, res: *http.Response) http.HandlerError!void {
    const allocator = req.arena.allocator();

    const ctx = try allocator.create(OneGBContext);
    ctx.* = .{
        .pattern = "0123456789ABCDEF",
        .total_written = 0,
        .total_size = 1024 * 1024 * 1024, // 1GB
    };

    res.header(http.Headers.ContentType, "application/octet-stream") catch return error.InternalServerError;
    res.header(http.Headers.ContentLength, "1073741824") catch return error.InternalServerError; // 1GB

    const chunk_sz = http.streaming.getDefaultChunkSize();
    res.partial_response = try http.streaming.PartialResponse.initGenerator(allocator, ctx, generate1GB, chunk_sz, 1024 * 1024 * 1024, true);

    res.processPartialResponse() catch return error.InternalServerError;
}

pub fn streamTestHandler(req: *http.Request, res: *http.Response) http.HandlerError!void {
    const allocator = req.arena.allocator();
    const test_size = 10 * 1024 * 1024; // 10MB

    const data = try allocator.alloc(u8, test_size);
    for (data, 0..) |*byte, i| {
        byte.* = @truncate(i % 256);
    }

    // Compute SHA-256 hash
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    // Format as hex string
    var checksum_buf: [64]u8 = undefined;
    for (&hash, 0..) |byte, i| {
        _ = std.fmt.bufPrint(checksum_buf[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch return error.InternalServerError;
    }

    res.header(http.Headers.ContentType, "application/octet-stream") catch return error.InternalServerError;
    res.header(http.Headers.ContentLength, "10485760") catch return error.InternalServerError;
    res.header("X-Checksum", &checksum_buf) catch return error.InternalServerError;

    res.partial_response = http.streaming.PartialResponse.initMemory(allocator, data, true) catch return error.InternalServerError;
    res.processPartialResponse() catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

pub fn trailersDemoHandler(req: *http.Request, res: *http.Response) http.HandlerError!void {
    _ = req;
    res.header(http.Headers.ContentType, "text/plain") catch return error.InternalServerError;
    const body = "Hello, trailers!\n";
    res.setContentLength(body.len) catch |err| switch (err) {
        error.NoSpaceLeft => return error.InternalServerError,
        else => return error.InternalServerError,
    };
    res.writeAll(body) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };

    const trailers = [_]http.Response.Trailer{
        .{ .name = "x-demo-trailer", .value = "finished" },
    };
    res.sendTrailers(&trailers) catch return error.InternalServerError;
}

// === Upload streaming callbacks ===

const UploadContext = struct {
    hasher: std.crypto.hash.sha2.Sha256,
    bytes_received: usize,
    start_time: i64,
    compute_hash: bool,
};

pub var g_disable_hash = false;
pub var g_enable_progress_log = false;

pub fn uploadStreamOnHeaders(req: *http.Request, res: *http.Response) http.StreamingError!void {
    _ = res;
    const content_length = req.contentLength();

    const ctx = try req.arena.allocator().create(UploadContext);
    ctx.* = .{
        .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        .bytes_received = 0,
        .start_time = std.time.milliTimestamp(),
        .compute_hash = !g_disable_hash,
    };

    req.user_data = @ptrCast(ctx);

    if (content_length) |len| {
        std.debug.print("Upload starting: {} bytes expected\n", .{len});
    } else {
        std.debug.print("Upload starting: chunked transfer\n", .{});
    }
}

pub fn uploadStreamOnChunk(req: *http.Request, res: *http.Response, chunk: []const u8) http.StreamingError!void {
    _ = res;

    const ctx = if (req.user_data) |ptr|
        @as(*UploadContext, @ptrCast(@alignCast(ptr)))
    else {
        std.debug.print("Missing upload context in chunk handler\n", .{});
        return;
    };

    if (ctx.compute_hash) {
        ctx.hasher.update(chunk);
    }
    ctx.bytes_received += chunk.len;

    if (g_enable_progress_log) {
        if (ctx.bytes_received % (1024 * 1024) == 0) {
            std.debug.print("Upload progress: {} MB\n", .{ctx.bytes_received / (1024 * 1024)});
        }
    }
}

pub fn uploadStreamOnComplete(req: *http.Request, res: *http.Response) http.StreamingError!void {
    const ctx = if (req.user_data) |ptr|
        @as(*UploadContext, @ptrCast(@alignCast(ptr)))
    else {
        res.jsonError(500, "Missing upload context") catch |err| switch (err) {
            error.StreamBlocked => return error.StreamBlocked,
            else => return error.InvalidState,
        };
        return;
    };

    const elapsed_ms = std.time.milliTimestamp() - ctx.start_time;

    var hash_hex_buf: [64]u8 = undefined;
    var hash_hex: []const u8 = "disabled";

    if (ctx.compute_hash) {
        var hash: [32]u8 = undefined;
        ctx.hasher.final(&hash);

        for (&hash, 0..) |byte, i| {
            _ = std.fmt.bufPrint(hash_hex_buf[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch return error.InvalidState;
        }
        hash_hex = &hash_hex_buf;
    }

    const response = struct {
        bytes_received: usize,
        sha256: []const u8,
        elapsed_ms: i64,
        throughput_mbps: f64,
    }{
        .bytes_received = ctx.bytes_received,
        .sha256 = hash_hex,
        .elapsed_ms = elapsed_ms,
        .throughput_mbps = if (elapsed_ms > 0)
            @as(f64, @floatFromInt(ctx.bytes_received)) * 8.0 / (@as(f64, @floatFromInt(elapsed_ms)) * 1000.0)
        else
            0.0,
    };

    res.jsonValue(response) catch |err| switch (err) {
        error.StreamBlocked => return error.StreamBlocked,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidState,
    };
    std.debug.print("Upload complete: {} bytes, SHA-256: {s}\n", .{ ctx.bytes_received, hash_hex });
}
