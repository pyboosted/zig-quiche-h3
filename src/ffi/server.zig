const std = @import("std");
const config_mod = @import("config");
const server_pkg = @import("server");
const routing_dynamic = @import("routing_dynamic");
const http = @import("http");
const errors = @import("errors");

const Allocator = std.mem.Allocator;
const QuicServer = server_pkg.QuicServer;
const Method = http.Method;
const FfiError = error{ InvalidMethod, InvalidState };
const WTSession = QuicServer.WTApi.Session;
pub const LogCallback = ?*const fn (user: ?*anyopaque, line: [*:0]const u8) callconv(.c) void;

pub const ZigServerConfig = extern struct {
    cert_path: ?[*:0]const u8 = null,
    key_path: ?[*:0]const u8 = null,
    bind_addr: ?[*:0]const u8 = null,
    bind_port: u16 = 0,
    enable_dgram: u8 = 0,
    enable_webtransport: u8 = 0,
    qlog_dir: ?[*:0]const u8 = null,
    log_level: u8 = 0,
};

pub const ZigHeader = extern struct {
    name: ?[*]const u8 = null,
    name_len: usize = 0,
    value: ?[*]const u8 = null,
    value_len: usize = 0,
};

pub const ZigRequest = extern struct {
    method: ?[*]const u8 = null,
    method_len: usize = 0,
    path: ?[*]const u8 = null,
    path_len: usize = 0,
    authority: ?[*]const u8 = null,
    authority_len: usize = 0,
    headers: ?[*]const ZigHeader = null,
    headers_len: usize = 0,
    stream_id: u64 = 0,
    conn_id: ?[*]const u8 = null,
    conn_id_len: usize = 0,
};

comptime {
    if (@sizeOf(ZigHeader) != @sizeOf(http.Header)) {
        @compileError("ZigHeader must match http.Header layout");
    }
}

pub const ZigResponse = opaque {};
pub const ZigServer = opaque {};
pub const ZigWebTransportSession = opaque {};

pub const RequestCallback = ?*const fn (user: ?*anyopaque, req: *const ZigRequest, resp: *ZigResponse) callconv(.c) void;
pub const DatagramCallback = ?*const fn (user: ?*anyopaque, req: *const ZigRequest, resp: *ZigResponse, data: ?[*]const u8, data_len: usize) callconv(.c) void;
pub const WTSessionCallback = ?*const fn (user: ?*anyopaque, req: *const ZigRequest, session: *ZigWebTransportSession) callconv(.c) void;
pub const BodyChunkCallback = ?*const fn (user: ?*anyopaque, conn_id: ?[*]const u8, conn_id_len: usize, stream_id: u64, chunk: ?[*]const u8, chunk_len: usize) callconv(.c) void;
pub const BodyCompleteCallback = ?*const fn (user: ?*anyopaque, conn_id: ?[*]const u8, conn_id_len: usize, stream_id: u64) callconv(.c) void;
pub const StreamCloseCallback = ?*const fn (user: ?*anyopaque, conn_id: ?[*]const u8, conn_id_len: usize, stream_id: u64, aborted: u8) callconv(.c) void;
pub const ConnectionCloseCallback = ?*const fn (user: ?*anyopaque, conn_id: ?[*]const u8, conn_id_len: usize) callconv(.c) void;

const RouteContext = struct {
    server: *ServerHandle,
    callback: RequestCallback,
    datagram_callback: DatagramCallback,
    wt_session_callback: WTSessionCallback,
    body_chunk_callback: BodyChunkCallback = null,
    body_complete_callback: BodyCompleteCallback = null,
    user_data: ?*anyopaque,
};

const ServerState = enum { created, running, stopped };

const ServerHandle = struct {
    allocator: Allocator,
    config: config_mod.ServerConfig,
    builder: routing_dynamic.Builder,
    matcher: ?*routing_dynamic.DynMatcher = null,
    server: ?*QuicServer = null,
    thread: ?std.Thread = null,
    state: ServerState = .created,
    route_contexts: std.ArrayListUnmanaged(*RouteContext) = .{},
    session_handles: std.ArrayListUnmanaged(*WebTransportSessionHandle) = .{},
    owned_strings: std.ArrayListUnmanaged([]u8) = .{},
    force_webtransport: bool = false,
    log_callback: LogCallback = null,
    log_user: ?*anyopaque = null,
    stream_close_callback: StreamCloseCallback = null,
    stream_close_user: ?*anyopaque = null,
    connection_close_callback: ConnectionCloseCallback = null,
    connection_close_user: ?*anyopaque = null,

    fn deinit(self: *ServerHandle) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.server) |srv| {
            srv.deinit();
            self.server = null;
        }
        if (self.matcher) |m| {
            m.deinit();
            self.allocator.destroy(m);
            self.matcher = null;
        }
        for (self.route_contexts.items) |ctx| {
            self.allocator.destroy(ctx);
        }
        self.route_contexts.deinit(self.allocator);
        for (self.session_handles.items) |sess_handle| {
            sess_handle.*.clear();
            self.allocator.destroy(sess_handle);
        }
        self.session_handles.deinit(self.allocator);
        for (self.owned_strings.items) |s| {
            self.allocator.free(s);
        }
        self.owned_strings.deinit(self.allocator);
        self.builder.deinit();
        self.allocator.destroy(self);
    }
};

fn asHandle(server_ptr: ?*ZigServer) ?*ServerHandle {
    if (server_ptr) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    return null;
}

fn asResponse(resp_ptr: ?*ZigResponse) ?*ResponseHandle {
    if (resp_ptr) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    return null;
}

const ResponseHandle = struct {
    response: *http.Response,
};

const WebTransportSessionHandle = struct {
    ctx: *RouteContext,
    session: *WTSession,

    fn asOpaque(self: *WebTransportSessionHandle) *ZigWebTransportSession {
        return @ptrCast(@alignCast(self));
    }

    fn clear(self: *WebTransportSessionHandle) void {
        self.session.state.session.user_data = null;
    }
};

fn sessionHandleFromOpaque(ptr: ?*ZigWebTransportSession) ?*WebTransportSessionHandle {
    if (ptr) |raw| return @ptrCast(@alignCast(raw));
    return null;
}

fn ensureSessionHandle(ctx: *RouteContext, session: *WTSession) errors.WebTransportError!*WebTransportSessionHandle {
    if (session.state.session.user_data) |existing| {
        return @ptrCast(@alignCast(existing));
    }

    const handle = ctx.server.allocator.create(WebTransportSessionHandle) catch {
        return errors.WebTransportError.OutOfMemory;
    };
    handle.* = .{ .ctx = ctx, .session = session };
    session.state.session.user_data = handle;
    ctx.server.session_handles.append(ctx.server.allocator, handle) catch {
        session.state.session.user_data = null;
        ctx.server.allocator.destroy(handle);
        return errors.WebTransportError.OutOfMemory;
    };
    return handle;
}

fn removeSessionHandle(server: *ServerHandle, target: *WebTransportSessionHandle) void {
    var i: usize = 0;
    while (i < server.session_handles.items.len) : (i += 1) {
        if (server.session_handles.items[i] == target) {
            _ = server.session_handles.swapRemove(i);
            return;
        }
    }
}

fn logMessage(handle: ?*ServerHandle, comptime fmt: []const u8, args: anytype) void {
    if (handle) |h| {
        if (h.log_callback) |cb| {
            var buf: [512:0]u8 = undefined;
            const line = std.fmt.bufPrintZ(&buf, fmt ++ "\n", args) catch {
                cb(h.log_user, "log formatting error");
                return;
            };
            cb(h.log_user, line.ptr);
            return;
        }
    }
    std.log.err(fmt ++ "\n", args);
}

fn logError(handle: ?*ServerHandle, comptime fmt: []const u8, args: anytype) void {
    logMessage(handle, fmt, args);
}

fn toOptionalPtr(slice: []const u8) ?[*]const u8 {
    return if (slice.len == 0) null else slice.ptr;
}

fn toZigHeaderSlice(headers: []const http.Header) []const ZigHeader {
    if (headers.len == 0) return &[_]ZigHeader{};
    const ptr: [*]const ZigHeader = @ptrCast(headers.ptr);
    return ptr[0..headers.len];
}

fn buildRequestView(req: *http.Request) ZigRequest {
    const method_slice = req.method.toString();
    const path_slice = req.path_decoded;
    const authority_slice = req.authority orelse &[_]u8{};
    const headers_slice = toZigHeaderSlice(req.headers);
    const conn_id_slice = req.conn_id orelse &[_]u8{};

    return ZigRequest{
        .method = toOptionalPtr(method_slice),
        .method_len = method_slice.len,
        .path = toOptionalPtr(path_slice),
        .path_len = path_slice.len,
        .authority = toOptionalPtr(authority_slice),
        .authority_len = authority_slice.len,
        .headers = if (headers_slice.len == 0) null else headers_slice.ptr,
        .headers_len = headers_slice.len,
        .stream_id = req.stream_id,
        .conn_id = toOptionalPtr(conn_id_slice),
        .conn_id_len = conn_id_slice.len,
    };
}

fn applyForcedWebTransport(handle: *ServerHandle, server: *QuicServer) void {
    if (!handle.force_webtransport) return;
    server.config.enable_dgram = true;
    server.wt.enabled = true;
    server.wt.enable_streams = true;
    server.wt.enable_bidi = true;
}

fn applyForcedWebTransportConfig(handle: *ServerHandle) void {
    if (handle.force_webtransport) {
        handle.config.enable_dgram = true;
    }
}

fn cStringDup(allocator: Allocator, list: *std.ArrayListUnmanaged([]u8), cstr: ?[*:0]const u8) ![]u8 {
    if (cstr) |ptr| {
        const bytes = std.mem.span(ptr);
        const duped = try allocator.dupe(u8, bytes);
        try list.append(allocator, duped);
        return duped;
    }
    return &.{};
}

fn applyConfigDefaults(handle: *ServerHandle, cfg_src: ?*const ZigServerConfig) !void {
    if (cfg_src == null) return;
    const cfg = cfg_src.?;

    if (cfg.bind_addr) |addr_ptr| {
        const duped = try handle.allocator.dupe(u8, std.mem.span(addr_ptr));
        try handle.owned_strings.append(handle.allocator, duped);
        handle.config.bind_addr = duped;
    }
    if (cfg.bind_port != 0) {
        handle.config.bind_port = cfg.bind_port;
    }
    if (cfg.cert_path) |path_ptr| {
        const duped = try handle.allocator.dupe(u8, std.mem.span(path_ptr));
        try handle.owned_strings.append(handle.allocator, duped);
        handle.config.cert_path = duped;
    }
    if (cfg.key_path) |path_ptr| {
        const duped = try handle.allocator.dupe(u8, std.mem.span(path_ptr));
        try handle.owned_strings.append(handle.allocator, duped);
        handle.config.key_path = duped;
    }
    if (cfg.qlog_dir) |dir_ptr| {
        const duped = try handle.allocator.dupe(u8, std.mem.span(dir_ptr));
        try handle.owned_strings.append(handle.allocator, duped);
        handle.config.qlog_dir = duped;
    }
    if (cfg.enable_dgram != 0) {
        handle.config.enable_dgram = true;
    }
    if (cfg.enable_webtransport != 0) {
        handle.config.enable_dgram = true;
        handle.force_webtransport = true;
    }
}

fn mapHandlerError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => -500,
        else => blk: {
            const status = errors.errorToStatus(@errorCast(err));
            break :blk -@as(i32, @intCast(status));
        },
    };
}

fn requestHandler(req: *http.Request, res: *http.Response) errors.HandlerError!void {
    std.debug.print("requestHandler invoked? user_data={any}\n", .{req.user_data});
    const ctx_ptr = req.user_data orelse {
        logError(null, "requestHandler missing user_data", .{});
        return errors.HandlerError.InternalServerError;
    };
    const ctx = @as(*RouteContext, @ptrCast(@alignCast(ctx_ptr)));
    if (ctx.callback) |callback| {
        const request_view = buildRequestView(req);
        var resp_wrapper = ResponseHandle{ .response = res };
        const resp_ptr: *ZigResponse = @ptrCast(@alignCast(&resp_wrapper));
        callback(ctx.user_data, &request_view, resp_ptr);
    } else {
        logError(ctx.server, "requestHandler missing callback", .{});
        return errors.HandlerError.InternalServerError;
    }
}

fn datagramHandler(req: *http.Request, res: *http.Response, payload: []const u8) errors.DatagramError!void {
    const ctx_ptr = req.user_data orelse return;
    const ctx = @as(*RouteContext, @ptrCast(@alignCast(ctx_ptr)));
    if (ctx.datagram_callback) |callback| {
        const request_view = buildRequestView(req);
        var resp_wrapper = ResponseHandle{ .response = res };
        const resp_ptr: *ZigResponse = @ptrCast(@alignCast(&resp_wrapper));
        const data_ptr: ?[*]const u8 = if (payload.len == 0) null else payload.ptr;
        callback(ctx.user_data, &request_view, resp_ptr, data_ptr, payload.len);
    }
}

fn wtSessionHandler(req: *http.Request, session_ptr: *anyopaque) errors.WebTransportError!void {
    const ctx_ptr = req.user_data orelse return errors.WebTransportError.InvalidState;
    const ctx = @as(*RouteContext, @ptrCast(@alignCast(ctx_ptr)));
    const callback = ctx.wt_session_callback orelse return errors.WebTransportError.InvalidState;
    const session_wrapper = WTSession.fromOpaque(session_ptr);
    const handle = try ensureSessionHandle(ctx, session_wrapper);
    const request_view = buildRequestView(req);
    callback(ctx.user_data, &request_view, handle.asOpaque());
}

fn bodyChunkHandler(req: *http.Request, res: *http.Response, chunk: []const u8) errors.StreamingError!void {
    _ = res; // Unused in FFI layer
    const ctx_ptr = req.user_data orelse return;
    const ctx = @as(*RouteContext, @ptrCast(@alignCast(ctx_ptr)));
    if (ctx.body_chunk_callback) |callback| {
        // Get connection ID from request
        const conn_id = req.conn_id orelse &[_]u8{};
        const chunk_ptr: ?[*]const u8 = if (chunk.len == 0) null else chunk.ptr;
        callback(ctx.user_data, conn_id.ptr, conn_id.len, req.stream_id, chunk_ptr, chunk.len);
    }
}

fn bodyCompleteHandler(req: *http.Request, res: *http.Response) errors.StreamingError!void {
    _ = res; // Unused in FFI layer
    const ctx_ptr = req.user_data orelse return;
    const ctx = @as(*RouteContext, @ptrCast(@alignCast(ctx_ptr)));
    if (ctx.body_complete_callback) |callback| {
        const conn_id = req.conn_id orelse &[_]u8{};
        callback(ctx.user_data, conn_id.ptr, conn_id.len, req.stream_id);
    }
}

fn registerRoute(
    handle: *ServerHandle,
    method_str: []const u8,
    pattern: []const u8,
    cb: RequestCallback,
    dgram_cb: DatagramCallback,
    wt_cb: WTSessionCallback,
    user: ?*anyopaque,
) !void {
    const method = Method.fromString(method_str) orelse return FfiError.InvalidMethod;
    const ctx = try handle.allocator.create(RouteContext);
    ctx.* = .{
        .server = handle,
        .callback = cb,
        .datagram_callback = dgram_cb,
        .wt_session_callback = wt_cb,
        .user_data = user,
    };
    try handle.route_contexts.append(handle.allocator, ctx);
    logMessage(handle, "register route {s} {s}", .{ method_str, pattern });

    try handle.builder.add(.{
        .pattern = pattern,
        .method = method,
        .handler = requestHandler,
        .on_h3_dgram = if (dgram_cb != null) datagramHandler else null,
        .on_wt_session = if (wt_cb != null) wtSessionHandler else null,
        .user_data = ctx,
    });

    if (dgram_cb != null) {
        handle.config.enable_dgram = true;
    }
    if (wt_cb != null) {
        handle.config.enable_dgram = true;
        handle.force_webtransport = true;
    }
}

fn registerRouteStreaming(
    handle: *ServerHandle,
    method_str: []const u8,
    pattern: []const u8,
    cb: RequestCallback,
    body_chunk_cb: BodyChunkCallback,
    body_complete_cb: BodyCompleteCallback,
    dgram_cb: DatagramCallback,
    wt_cb: WTSessionCallback,
    user: ?*anyopaque,
) !void {
    const method = Method.fromString(method_str) orelse return FfiError.InvalidMethod;
    const ctx = try handle.allocator.create(RouteContext);
    ctx.* = .{
        .server = handle,
        .callback = cb,
        .datagram_callback = dgram_cb,
        .wt_session_callback = wt_cb,
        .body_chunk_callback = body_chunk_cb,
        .body_complete_callback = body_complete_cb,
        .user_data = user,
    };
    try handle.route_contexts.append(handle.allocator, ctx);
    logMessage(handle, "register streaming route {s} {s}", .{ method_str, pattern });

    try handle.builder.add(.{
        .pattern = pattern,
        .method = method,
        .handler = requestHandler,
        .on_body_chunk = if (body_chunk_cb != null) bodyChunkHandler else null,
        .on_body_complete = if (body_complete_cb != null) bodyCompleteHandler else null,
        .on_h3_dgram = if (dgram_cb != null) datagramHandler else null,
        .on_wt_session = if (wt_cb != null) wtSessionHandler else null,
        .user_data = ctx,
    });

    if (dgram_cb != null) {
        handle.config.enable_dgram = true;
    }
    if (wt_cb != null) {
        handle.config.enable_dgram = true;
        handle.force_webtransport = true;
    }
}

// Adapter for stream close callback: Zig → C FFI
fn streamCloseAdapter(conn_id: []const u8, stream_id: u64, aborted: bool, user: ?*anyopaque) void {
    if (user) |u| {
        const handle: *ServerHandle = @ptrCast(@alignCast(u));
        if (handle.stream_close_callback) |cb| {
            const aborted_u8: u8 = if (aborted) 1 else 0;
            cb(handle.stream_close_user, conn_id.ptr, conn_id.len, stream_id, aborted_u8);
        }
    }
}

// Adapter for connection close callback: Zig → C FFI
fn connectionCloseAdapter(conn_id: []const u8, user: ?*anyopaque) void {
    if (user) |u| {
        const handle: *ServerHandle = @ptrCast(@alignCast(u));
        if (handle.connection_close_callback) |cb| {
            cb(handle.connection_close_user, conn_id.ptr, conn_id.len);
        }
    }
}

fn startServer(handle: *ServerHandle) !void {
    if (handle.state == .running) return FfiError.InvalidState;
    applyForcedWebTransportConfig(handle);
    const dyn = try handle.allocator.create(routing_dynamic.DynMatcher);
    handle.matcher = dyn;
    dyn.* = try handle.builder.build();
    const matcher = dyn.intoMatcher();

    const server = try QuicServer.init(handle.allocator, handle.config, matcher);
    errdefer {
        server.deinit();
    }

    // Wire cleanup callbacks through adapters so FFI layer gets notified
    server.on_stream_close = streamCloseAdapter;
    server.on_stream_close_user = handle;
    server.on_connection_close = connectionCloseAdapter;
    server.on_connection_close_user = handle;

    applyForcedWebTransport(handle, server);

    try server.bind();
    handle.server = server;

    handle.thread = try std.Thread.spawn(.{}, runServerThread, .{handle});
    handle.state = .running;
}

fn runServerThread(handle: *ServerHandle) void {
    if (handle.server) |srv| {
        srv.run() catch |err| {
            logError(handle, "zig_h3_server run() failed: {s}", .{@errorName(err)});
        };
    }
    handle.state = .stopped;
}

fn stopServer(handle: *ServerHandle) void {
    if (handle.state != .running) return;
    if (handle.server) |srv| {
        srv.stop();
    }
    if (handle.thread) |t| {
        t.join();
        handle.thread = null;
    }
    if (handle.server) |srv| {
        srv.deinit();
        handle.server = null;
    }
    var idx: usize = 0;
    while (idx < handle.session_handles.items.len) {
        const sess_handle = handle.session_handles.items[idx];
        sess_handle.clear();
        handle.allocator.destroy(sess_handle);
        idx += 1;
    }
    handle.session_handles.items.len = 0;
    if (handle.matcher) |m| {
        m.deinit();
        handle.allocator.destroy(m);
        handle.matcher = null;
    }
    handle.state = .stopped;
}

fn responseFromOpaque(resp_ptr: *ZigResponse) *ResponseHandle {
    return @ptrCast(@alignCast(resp_ptr));
}

fn sliceFromC(ptr: ?[*]const u8, len: usize) []const u8 {
    if (len == 0 or ptr == null) return &[_]u8{};
    return ptr.?[0..len];
}

fn headersFromC(ptr: ?[*]const ZigHeader, len: usize) []const ZigHeader {
    if (len == 0 or ptr == null) return &[_]ZigHeader{};
    return ptr.?[0..len];
}

pub fn zig_h3_server_new(cfg_ptr: ?*const ZigServerConfig) ?*ZigServer {
    const allocator = std.heap.c_allocator;
    var handle = allocator.create(ServerHandle) catch return null;
    handle.* = .{
        .allocator = allocator,
        .config = config_mod.ServerConfig{},
        .builder = routing_dynamic.Builder.init(allocator),
        .session_handles = .{},
        .owned_strings = .{},
        .force_webtransport = false,
        .log_callback = null,
        .log_user = null,
    };

    if (applyConfigDefaults(handle, cfg_ptr)) |_| {} else |err| {
        logError(handle, "zig_h3_server_new failed: {s}", .{@errorName(err)});
        handle.deinit();
        return null;
    }
    return @ptrCast(handle);
}

pub fn zig_h3_server_free(server_ptr: ?*ZigServer) i32 {
    if (asHandle(server_ptr)) |handle| {
        stopServer(handle);
        handle.deinit();
        return 0;
    }
    return -1;
}

pub fn zig_h3_server_route(
    server_ptr: ?*ZigServer,
    method_c: ?[*:0]const u8,
    pattern_c: ?[*:0]const u8,
    cb: RequestCallback,
    dgram_cb: DatagramCallback,
    wt_cb: WTSessionCallback,
    user: ?*anyopaque,
) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    if (handle.state != .created) return -2;
    if (method_c == null or pattern_c == null) return -3;
    if (cb == null) return -4;
    const method = std.mem.span(method_c.?);
    const pattern = std.mem.span(pattern_c.?);
    registerRoute(handle, method, pattern, cb, dgram_cb, wt_cb, user) catch |err| {
        logError(handle, "zig_h3_server_route failed: {s}", .{@errorName(err)});
        return -5;
    };
    return 0;
}

pub fn zig_h3_server_route_streaming(
    server_ptr: ?*ZigServer,
    method_c: ?[*:0]const u8,
    pattern_c: ?[*:0]const u8,
    cb: RequestCallback,
    body_chunk_cb: BodyChunkCallback,
    body_complete_cb: BodyCompleteCallback,
    dgram_cb: DatagramCallback,
    wt_cb: WTSessionCallback,
    user: ?*anyopaque,
) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    if (handle.state != .created) return -2;
    if (method_c == null or pattern_c == null) return -3;
    if (cb == null) return -4;
    const method = std.mem.span(method_c.?);
    const pattern = std.mem.span(pattern_c.?);
    registerRouteStreaming(handle, method, pattern, cb, body_chunk_cb, body_complete_cb, dgram_cb, wt_cb, user) catch |err| {
        logError(handle, "zig_h3_server_route_streaming failed: {s}", .{@errorName(err)});
        return -5;
    };
    return 0;
}

pub fn zig_h3_server_set_stream_close_cb(
    server_ptr: ?*ZigServer,
    callback: StreamCloseCallback,
    user_data: ?*anyopaque,
) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    handle.stream_close_callback = callback;
    handle.stream_close_user = user_data;
    return 0;
}

pub fn zig_h3_server_set_connection_close_cb(
    server_ptr: ?*ZigServer,
    callback: ConnectionCloseCallback,
    user_data: ?*anyopaque,
) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    handle.connection_close_callback = callback;
    handle.connection_close_user = user_data;
    return 0;
}

pub fn zig_h3_server_start(server_ptr: ?*ZigServer) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    startServer(handle) catch |err| {
        logError(handle, "zig_h3_server_start failed: {s}", .{@errorName(err)});
        return -2;
    };
    return 0;
}

pub fn zig_h3_server_stop(server_ptr: ?*ZigServer) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    stopServer(handle);
    return 0;
}

pub fn zig_h3_server_set_log(server_ptr: ?*ZigServer, cb: LogCallback, user: ?*anyopaque) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    handle.log_callback = cb;
    handle.log_user = if (cb != null) user else null;
    return 0;
}

pub fn zig_h3_response_status(resp_ptr: ?*ZigResponse, status: u16) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    handle.response.status(status) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_response_header(
    resp_ptr: ?*ZigResponse,
    name_ptr: ?[*]const u8,
    name_len: usize,
    value_ptr: ?[*]const u8,
    value_len: usize,
) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    const name = sliceFromC(name_ptr, name_len);
    const value = sliceFromC(value_ptr, value_len);
    handle.response.header(name, value) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_response_write(
    resp_ptr: ?*ZigResponse,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    const data = sliceFromC(data_ptr, data_len);
    handle.response.writeAll(data) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_response_end(
    resp_ptr: ?*ZigResponse,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    const data_slice = if (data_len == 0 or data_ptr == null) null else sliceFromC(data_ptr, data_len);
    handle.response.end(data_slice) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_response_send_h3_datagram(
    resp_ptr: ?*ZigResponse,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    if (data_len == 0 or data_ptr == null) return 0;
    const data = sliceFromC(data_ptr, data_len);
    handle.response.sendH3Datagram(data) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_response_send_trailers(
    resp_ptr: ?*ZigResponse,
    headers_ptr: ?[*]const ZigHeader,
    headers_len: usize,
) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    if (headers_len == 0 or headers_ptr == null) {
        handle.response.sendTrailers(&.{}) catch |err| return mapHandlerError(err);
        return 0;
    }
    const headers = headersFromC(headers_ptr, headers_len);
    const allocator = handle.response.allocator;
    var trailers = allocator.alloc(http.Response.Trailer, headers_len) catch {
        return -500;
    };
    defer allocator.free(trailers);
    for (headers, 0..) |hdr, idx| {
        trailers[idx] = .{
            .name = sliceFromC(hdr.name, hdr.name_len),
            .value = sliceFromC(hdr.value, hdr.value_len),
        };
    }
    handle.response.sendTrailers(trailers) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_response_defer_end(resp_ptr: ?*ZigResponse) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    handle.response.deferEnd();
    return 0;
}

pub fn zig_h3_response_set_auto_end(resp_ptr: ?*ZigResponse, enable: u8) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    if (enable != 0) {
        handle.response.enableAutoEnd();
    } else {
        handle.response.deferEnd();
    }
    return 0;
}

pub fn zig_h3_response_should_auto_end(resp_ptr: ?*ZigResponse) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    return if (handle.response.shouldAutoEnd()) 1 else 0;
}

pub fn zig_h3_response_process_partial(resp_ptr: ?*ZigResponse) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    handle.response.processPartialResponse() catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_wt_accept(session_ptr: ?*ZigWebTransportSession) i32 {
    const handle = sessionHandleFromOpaque(session_ptr) orelse return -1;
    handle.session.accept(.{}) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_wt_reject(session_ptr: ?*ZigWebTransportSession, status: u16) i32 {
    const handle = sessionHandleFromOpaque(session_ptr) orelse return -1;
    handle.session.reject(.{ .status = status }) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_wt_close(
    session_ptr: ?*ZigWebTransportSession,
    code: u32,
    reason_ptr: ?[*]const u8,
    reason_len: usize,
) i32 {
    const handle = sessionHandleFromOpaque(session_ptr) orelse return -1;
    const reason = sliceFromC(reason_ptr, reason_len);
    handle.session.close(.{ .code = code, .reason = reason }) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_wt_send_datagram(
    session_ptr: ?*ZigWebTransportSession,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    const handle = sessionHandleFromOpaque(session_ptr) orelse return -1;
    if (data_len == 0 or data_ptr == null) return 0;
    const data = sliceFromC(data_ptr, data_len);
    handle.session.sendDatagram(data) catch |err| return mapHandlerError(err);
    return 0;
}

pub fn zig_h3_wt_release(session_ptr: ?*ZigWebTransportSession) i32 {
    const handle = sessionHandleFromOpaque(session_ptr) orelse return -1;
    const server_handle = handle.ctx.server;
    removeSessionHandle(server_handle, handle);
    handle.clear();
    server_handle.allocator.destroy(handle);
    return 0;
}
