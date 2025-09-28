const std = @import("std");
const config_mod = @import("../quic/config.zig");
const server_pkg = @import("../quic/server.zig");
const routing_dynamic = @import("../routing/dynamic.zig");
const http = @import("../http/mod.zig");
const errors = @import("../errors.zig");

const Allocator = std.mem.Allocator;
const QuicServer = server_pkg.QuicServer;
const Method = http.Method;
const FfiError = error{ InvalidMethod, InvalidState };

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
    name: [*]const u8 = null,
    name_len: usize = 0,
    value: [*]const u8 = null,
    value_len: usize = 0,
};

pub const ZigRequest = extern struct {
    method: [*]const u8 = null,
    method_len: usize = 0,
    path: [*]const u8 = null,
    path_len: usize = 0,
    authority: [*]const u8 = null,
    authority_len: usize = 0,
    headers: [*]const ZigHeader = null,
    headers_len: usize = 0,
    stream_id: u64 = 0,
};

pub const ZigResponse = opaque {};
pub const ZigServer = opaque {};

const RequestCallback = ?*const fn (user: ?*anyopaque, req: *const ZigRequest, resp: *ZigResponse) callconv(.C) void;

const RouteContext = struct {
    server: *ServerHandle,
    callback: RequestCallback,
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
    owned_strings: std.ArrayListUnmanaged([]u8) = .{},

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
    }
}

fn mapHandlerError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => -500,
        else => blk: {
            const status = errors.errorToStatus(err);
            break :blk -@as(i32, @intCast(status));
        },
    };
}

fn requestHandler(req: *http.Request, res: *http.Response) errors.HandlerError!void {
    const ctx_ptr = req.user_data orelse return errors.HandlerError.InternalServerError;
    const ctx = @as(*RouteContext, @ptrCast(@alignCast(ctx_ptr)));
    if (ctx.callback == null) return errors.HandlerError.InternalServerError;

    const allocator = req.arena.allocator();
    var headers_buf = try allocator.alloc(ZigHeader, req.headers.len);
    for (req.headers, 0..) |header, idx| {
        headers_buf[idx] = .{
            .name = header.name.ptr,
            .name_len = header.name.len,
            .value = header.value.ptr,
            .value_len = header.value.len,
        };
    }

    const method_str = req.method.toString();
    const path = req.path_decoded;
    const authority_slice = req.authority orelse &[_]u8{};

    var request_view = ZigRequest{
        .method = method_str.ptr,
        .method_len = method_str.len,
        .path = path.ptr,
        .path_len = path.len,
        .authority = authority_slice.ptr,
        .authority_len = authority_slice.len,
        .headers = headers_buf.ptr,
        .headers_len = headers_buf.len,
        .stream_id = req.stream_id,
    };

    var resp_wrapper = ResponseHandle{ .response = res };
    const resp_ptr: *ZigResponse = @ptrCast(@alignCast(&resp_wrapper));
    const cb = ctx.callback.?;
    cb(ctx.user_data, &request_view, resp_ptr);
}

fn registerRoute(handle: *ServerHandle, method_str: []const u8, pattern: []const u8, cb: RequestCallback, user: ?*anyopaque) !void {
    const method = Method.fromString(method_str) orelse return FfiError.InvalidMethod;
    const ctx = try handle.allocator.create(RouteContext);
    ctx.* = .{ .server = handle, .callback = cb, .user_data = user };
    try handle.route_contexts.append(handle.allocator, ctx);

    try handle.builder.add(.{
        .pattern = pattern,
        .method = method,
        .handler = requestHandler,
        .user_data = ctx,
    });
}

fn startServer(handle: *ServerHandle) !void {
    if (handle.state == .running) return FfiError.InvalidState;
    const dyn = try handle.allocator.create(routing_dynamic.DynMatcher);
    handle.matcher = dyn;
    dyn.* = try handle.builder.build();
    const matcher = dyn.intoMatcher();

    const server = try QuicServer.init(handle.allocator, handle.config, matcher);
    errdefer {
        server.deinit();
    }

    try server.bind();
    handle.server = server;

    handle.thread = try std.Thread.spawn(.{}, runServerThread, .{handle});
    handle.state = .running;
}

fn runServerThread(handle: *ServerHandle) void {
    if (handle.server) |srv| {
        srv.run() catch |err| {
            std.log.err("zig_h3_server run() failed: {s}", .{@errorName(err)});
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

pub export fn zig_h3_server_new(cfg_ptr: ?*const ZigServerConfig) ?*ZigServer {
    const allocator = std.heap.c_allocator;
    var handle = allocator.create(ServerHandle) catch return null;
    handle.* = .{
        .allocator = allocator,
        .config = config_mod.ServerConfig{},
        .builder = routing_dynamic.Builder.init(allocator),
    };

    if (applyConfigDefaults(handle, cfg_ptr)) |_| {} else |err| {
        handle.deinit();
        std.log.err("zig_h3_server_new failed: {s}", .{@errorName(err)});
        return null;
    }
    return @ptrCast(handle);
}

pub export fn zig_h3_server_free(server_ptr: ?*ZigServer) i32 {
    if (asHandle(server_ptr)) |handle| {
        stopServer(handle);
        handle.deinit();
        return 0;
    }
    return -1;
}

pub export fn zig_h3_server_route(
    server_ptr: ?*ZigServer,
    method_c: ?[*:0]const u8,
    pattern_c: ?[*:0]const u8,
    cb: RequestCallback,
    user: ?*anyopaque,
) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    if (handle.state != .created) return -2;
    if (method_c == null or pattern_c == null) return -3;
    const method = std.mem.span(method_c.?);
    const pattern = std.mem.span(pattern_c.?);
    registerRoute(handle, method, pattern, cb, user) catch |err| {
        std.log.err("zig_h3_server_route failed: {s}", .{@errorName(err)});
        return -4;
    };
    return 0;
}

pub export fn zig_h3_server_start(server_ptr: ?*ZigServer) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    startServer(handle) catch |err| {
        std.log.err("zig_h3_server_start failed: {s}", .{@errorName(err)});
        return -2;
    };
    return 0;
}

pub export fn zig_h3_server_stop(server_ptr: ?*ZigServer) i32 {
    const handle = asHandle(server_ptr) orelse return -1;
    stopServer(handle);
    return 0;
}

pub export fn zig_h3_response_status(resp_ptr: ?*ZigResponse, status: u16) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    handle.response.status(status) catch |err| return mapHandlerError(err);
    return 0;
}

pub export fn zig_h3_response_header(
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

pub export fn zig_h3_response_write(
    resp_ptr: ?*ZigResponse,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    const data = sliceFromC(data_ptr, data_len);
    handle.response.writeAll(data) catch |err| return mapHandlerError(err);
    return 0;
}

pub export fn zig_h3_response_end(
    resp_ptr: ?*ZigResponse,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    const handle = asResponse(resp_ptr) orelse return -1;
    const data_slice = if (data_len == 0 or data_ptr == null) null else sliceFromC(data_ptr, data_len);
    handle.response.end(data_slice) catch |err| return mapHandlerError(err);
    return 0;
}
