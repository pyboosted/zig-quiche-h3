const std = @import("std");
const client_mod = @import("client");
const http = @import("http");
const errors = @import("errors");

const Allocator = std.mem.Allocator;
const QuicClient = client_mod.QuicClient;
const ClientConfig = client_mod.ClientConfig;
const ServerEndpoint = client_mod.ServerEndpoint;
const Method = http.Method;
const ClientError = client_mod.ClientError;

pub const ZigClientConfig = extern struct {
    verify_peer: u8 = 1,
    enable_dgram: u8 = 0,
    enable_webtransport: u8 = 0,
    enable_debug_logging: u8 = 0,
    idle_timeout_ms: u32 = 30000,
    request_timeout_ms: u32 = 30000,
    connect_timeout_ms: u32 = 10000,
};

pub const ZigHeader = extern struct {
    name: ?[*]const u8 = null,
    name_len: usize = 0,
    value: ?[*]const u8 = null,
    value_len: usize = 0,
};

pub const ZigFetchOptions = extern struct {
    method: ?[*]const u8 = null,
    method_len: usize = 0,
    path: ?[*]const u8 = null,
    path_len: usize = 0,
    headers: ?[*]const ZigHeader = null,
    headers_len: usize = 0,
    body: ?[*]const u8 = null,
    body_len: usize = 0,
    stream_body: u8 = 0,
    collect_body: u8 = 1,
    event_cb: FetchEventCallback = null,
    event_user: ?*anyopaque = null,
    request_timeout_ms: u32 = 0,
    _reserved: u32 = 0,
};

pub const ZigClient = opaque {};

pub const FetchCallback = ?*const fn (
    user: ?*anyopaque,
    status: u16,
    headers: ?[*]const ZigHeader,
    headers_len: usize,
    body: ?[*]const u8,
    body_len: usize,
    trailers: ?[*]const ZigHeader,
    trailers_len: usize,
) callconv(.c) void;

const ZigFetchEventType = enum(u32) {
    headers = 0,
    data = 1,
    trailers = 2,
    finished = 3,
    datagram = 4,
    started = 5,
};

pub const ZigFetchEvent = extern struct {
    kind: ZigFetchEventType = ZigFetchEventType.headers,
    status: u16 = 0,
    reserved: u16 = 0,
    headers: ?[*]const ZigHeader = null,
    headers_len: usize = 0,
    data: ?[*]const u8 = null,
    data_len: usize = 0,
    flow_id: u64 = 0,
    stream_id: u64 = 0,
};

pub const FetchEventCallback = ?*const fn (user: ?*anyopaque, event: ?*const ZigFetchEvent) callconv(.c) void;

pub const DatagramCallback = ?*const fn (user: ?*anyopaque, flow_id: u64, payload: ?[*]const u8, payload_len: usize) callconv(.c) void;

const ClientHandle = struct {
    allocator: Allocator,
    client: *QuicClient,
    config: ClientConfig,
    dgram_cb: DatagramCallback = null,
    dgram_user: ?*anyopaque = null,
};

const FetchEventContext = struct {
    handle: *ClientHandle,
    cb: FetchEventCallback,
    user: ?*anyopaque,
    last_status: u16 = 0,
    stream_id: u64 = 0,
    event_storage: ZigFetchEvent = .{},
};

fn asHandle(ptr: ?*ZigClient) ?*ClientHandle {
    if (ptr) |raw| return @ptrCast(@alignCast(raw));
    return null;
}

fn sliceFromC(ptr: ?[*]const u8, len: usize) []const u8 {
    if (len == 0 or ptr == null) return &[_]u8{};
    return ptr.?[0..len];
}

fn headersFromC(ptr: ?[*]const ZigHeader, len: usize) []const ZigHeader {
    if (len == 0 or ptr == null) return &[_]ZigHeader{};
    return ptr.?[0..len];
}

fn toOptionalPtr(slice: []const u8) ?[*]const u8 {
    return if (slice.len == 0) null else slice.ptr;
}

fn adoptHeaders(allocator: Allocator, headers: []const ZigHeader) ![]client_mod.HeaderPair {
    if (headers.len == 0) return &[_]client_mod.HeaderPair{};
    const out = try allocator.alloc(client_mod.HeaderPair, headers.len);
    errdefer allocator.free(out);
    for (headers, 0..) |hdr, idx| {
        out[idx] = client_mod.HeaderPair{
            .name = sliceFromC(hdr.name, hdr.name_len),
            .value = sliceFromC(hdr.value, hdr.value_len),
        };
    }
    return out;
}

fn makeFetchOptions(handle: *ClientHandle, opts: *const ZigFetchOptions) !client_mod.FetchOptions {
    var fetch_opts = client_mod.FetchOptions{ .path = "" };
    if (opts.method_len > 0) {
        if (opts.method) |method_ptr| {
            const method_slice = method_ptr[0..opts.method_len];
            fetch_opts.method = method_slice;
        }
    }
    if (opts.path_len > 0) {
        if (opts.path) |path_ptr| {
            fetch_opts.path = path_ptr[0..opts.path_len];
        }
    }
    if (opts.headers_len > 0) {
        if (opts.headers) |hdr_ptr| {
            const hdrs = hdr_ptr[0..opts.headers_len];
            fetch_opts.headers = try adoptHeaders(handle.allocator, hdrs);
        }
    }
    if (opts.body_len > 0) {
        if (opts.body) |body_ptr| {
            fetch_opts.body = body_ptr[0..opts.body_len];
        }
    }
    fetch_opts.timeout_override_ms = if (opts.request_timeout_ms == 0) null else opts.request_timeout_ms;
    return fetch_opts;
}

fn cleanupFetchOptions(handle: *ClientHandle, fo: *client_mod.FetchOptions) void {
    if (fo.headers.len > 0) handle.allocator.free(fo.headers);
}

fn buildTempHeaders(allocator: Allocator, pairs: []const client_mod.HeaderPair) ![]ZigHeader {
    if (pairs.len == 0) return &[_]ZigHeader{};
    const temp = try allocator.alloc(ZigHeader, pairs.len);
    errdefer allocator.free(temp);
    for (pairs, 0..) |pair, idx| {
        temp[idx] = .{
            .name = toOptionalPtr(pair.name),
            .name_len = pair.name.len,
            .value = toOptionalPtr(pair.value),
            .value_len = pair.value.len,
        };
    }
    return temp;
}

fn mapClientError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => -500,
        client_mod.ClientError.RequestTimeout => -408,
        client_mod.ClientError.InvalidRequest => -400,
        client_mod.ClientError.DnsResolveFailed => -502,
        client_mod.ClientError.SocketSetupFailed => -502,
        client_mod.ClientError.NoConnection => -503,
        client_mod.ClientError.ConnectionClosed => -503,
        client_mod.ClientError.StreamReset => -503,
        client_mod.ClientError.DatagramNotEnabled => -421,
        client_mod.ClientError.DatagramTooLarge => -431,
        client_mod.ClientError.DatagramSendFailed => -503,
        else => -1,
    };
}

fn mapAllocError(err: anyerror) ClientError {
    return switch (err) {
        error.OutOfMemory => ClientError.OutOfMemory,
        else => ClientError.H3Error,
    };
}

fn errorFromCode(code: i32) ClientError {
    return switch (code) {
        -500 => ClientError.OutOfMemory,
        -408 => ClientError.RequestTimeout,
        -400 => ClientError.InvalidRequest,
        -421 => ClientError.DatagramNotEnabled,
        -431 => ClientError.DatagramTooLarge,
        -502 => ClientError.SocketSetupFailed,
        -503 => ClientError.ConnectionClosed,
        else => ClientError.StreamReset,
    };
}

fn deliverFetchResponse(
    handle: *ClientHandle,
    cb: FetchCallback,
    user: ?*anyopaque,
    response: *client_mod.FetchResponse,
) i32 {
    const headers_temp = buildTempHeaders(handle.allocator, response.headers) catch |err| {
        return mapClientError(err);
    };
    defer if (headers_temp.len > 0) handle.allocator.free(headers_temp);

    const trailers_temp = buildTempHeaders(handle.allocator, response.trailers) catch |err| {
        return mapClientError(err);
    };
    defer if (trailers_temp.len > 0) handle.allocator.free(trailers_temp);

    const body_ptr: ?[*]const u8 = if (response.body.len == 0) null else response.body.ptr;

    cb.?(user, response.status, if (headers_temp.len == 0) null else headers_temp.ptr, headers_temp.len, body_ptr, response.body.len, if (trailers_temp.len == 0) null else trailers_temp.ptr, trailers_temp.len);
    return 0;
}

fn responseEventThunk(event: client_mod.ResponseEvent, ctx: ?*anyopaque) ClientError!void {
    const raw_ctx = ctx orelse return;
    const state = @as(*FetchEventContext, @ptrCast(@alignCast(raw_ctx)));
    if (state.cb == null) return;

    switch (event) {
        .headers => |hdrs| {
            const temp = buildTempHeaders(state.handle.allocator, hdrs) catch |err| {
                return mapAllocError(err);
            };
            defer if (temp.len > 0) state.handle.allocator.free(temp);

            var status = state.last_status;
            for (hdrs) |hdr| {
                if (std.mem.eql(u8, hdr.name, ":status")) {
                    status = std.fmt.parseUnsigned(u16, hdr.value, 10) catch status;
                    break;
                }
            }
            if (status != 0) {
                state.last_status = status;
            }
            state.event_storage = ZigFetchEvent{
                .kind = ZigFetchEventType.headers,
                .status = state.last_status,
                .headers = if (temp.len == 0) null else temp.ptr,
                .headers_len = temp.len,
                .data = null,
                .data_len = 0,
                .flow_id = 0,
                .stream_id = state.stream_id,
            };
            state.cb.?(state.user, &state.event_storage);
        },
        .trailers => |hdrs| {
            const temp = buildTempHeaders(state.handle.allocator, hdrs) catch |err| {
                return mapAllocError(err);
            };
            defer if (temp.len > 0) state.handle.allocator.free(temp);

            state.event_storage = ZigFetchEvent{
                .kind = ZigFetchEventType.trailers,
                .status = state.last_status,
                .headers = if (temp.len == 0) null else temp.ptr,
                .headers_len = temp.len,
                .data = null,
                .data_len = 0,
                .flow_id = 0,
                .stream_id = state.stream_id,
            };
            state.cb.?(state.user, &state.event_storage);
        },
        .data => |chunk| {
            state.event_storage = ZigFetchEvent{
                .kind = ZigFetchEventType.data,
                .status = state.last_status,
                .headers = null,
                .headers_len = 0,
                .data = null,
                .data_len = 0,
                .flow_id = 0,
                .stream_id = state.stream_id,
            };
            if (chunk.len > 0) {
                const copy = state.handle.allocator.dupe(u8, chunk) catch |err| {
                    return mapAllocError(err);
                };
                defer state.handle.allocator.free(copy);
                state.event_storage.data = copy.ptr;
                state.event_storage.data_len = copy.len;
                state.cb.?(state.user, &state.event_storage);
                state.event_storage.data = null;
                state.event_storage.data_len = 0;
            } else {
                state.cb.?(state.user, &state.event_storage);
            }
        },
        .finished => {
            state.event_storage = ZigFetchEvent{
                .kind = ZigFetchEventType.finished,
                .status = state.last_status,
                .headers = null,
                .headers_len = 0,
                .data = null,
                .data_len = 0,
                .flow_id = 0,
                .stream_id = state.stream_id,
            };
            state.cb.?(state.user, &state.event_storage);
        },
        .datagram => |d| {
            state.event_storage = ZigFetchEvent{
                .kind = ZigFetchEventType.datagram,
                .status = state.last_status,
                .headers = null,
                .headers_len = 0,
                .data = null,
                .data_len = 0,
                .flow_id = d.flow_id,
                .stream_id = state.stream_id,
            };
            if (d.payload.len > 0) {
                const copy = state.handle.allocator.dupe(u8, d.payload) catch |err| {
                    return mapAllocError(err);
                };
                defer state.handle.allocator.free(copy);
                state.event_storage.data = copy.ptr;
                state.event_storage.data_len = copy.len;
                state.cb.?(state.user, &state.event_storage);
                state.event_storage.data = null;
                state.event_storage.data_len = 0;
            } else {
                state.cb.?(state.user, &state.event_storage);
            }
        },
    }
}

fn applyClientConfig(base: *ClientConfig, cfg_ptr: ?*const ZigClientConfig) void {
    if (cfg_ptr) |cfg| {
        base.verify_peer = cfg.verify_peer != 0;
        base.enable_dgram = cfg.enable_dgram != 0;
        base.enable_webtransport = cfg.enable_webtransport != 0;
        base.enable_debug_logging = cfg.enable_debug_logging != 0;
        base.idle_timeout_ms = cfg.idle_timeout_ms;
        base.request_timeout_ms = cfg.request_timeout_ms;
        base.connect_timeout_ms = cfg.connect_timeout_ms;
    }
}

fn datagramDispatch(_: *QuicClient, payload: []const u8, user: ?*anyopaque) void {
    const handle_ptr = user orelse return;
    const handle = @as(*ClientHandle, @ptrCast(@alignCast(handle_ptr)));
    if (handle.dgram_cb) |cb| {
        const data_ptr: ?[*]const u8 = if (payload.len == 0) null else payload.ptr;
        cb(handle.dgram_user, 0, data_ptr, payload.len);
    }
}

comptime {
    std.debug.assert(@sizeOf(ZigHeader) == @sizeOf(client_mod.HeaderPair));
}

pub fn clientNew(cfg_ptr: ?*const ZigClientConfig) ?*ZigClient {
    const allocator = std.heap.c_allocator;
    var cfg = ClientConfig{};
    applyClientConfig(&cfg, cfg_ptr);
    const client = QuicClient.init(allocator, cfg) catch return null;
    const handle = allocator.create(ClientHandle) catch {
        client.deinit();
        return null;
    };
    handle.* = .{
        .allocator = allocator,
        .client = client,
        .config = cfg,
    };
    return @ptrCast(handle);
}

pub fn clientFree(client_ptr: ?*ZigClient) i32 {
    if (asHandle(client_ptr)) |handle| {
        handle.client.deinit();
        handle.allocator.destroy(handle);
        return 0;
    }
    return -1;
}

pub fn clientConnect(
    client_ptr: ?*ZigClient,
    host_ptr: ?[*:0]const u8,
    port: u16,
    sni_ptr: ?[*:0]const u8,
) i32 {
    const handle = asHandle(client_ptr) orelse return -1;
    if (host_ptr == null or port == 0) return -2;
    const host_slice = std.mem.span(host_ptr.?);
    const endpoint = ServerEndpoint{
        .host = host_slice,
        .port = port,
        .sni = if (sni_ptr) |sp| std.mem.span(sp) else null,
    };

    handle.client.rememberEndpoint(endpoint) catch |err| return mapClientError(err);
    handle.client.connect(endpoint) catch |err| return mapClientError(err);
    return 0;
}

pub fn clientSetDatagramCallback(
    client_ptr: ?*ZigClient,
    cb: DatagramCallback,
    user: ?*anyopaque,
) i32 {
    const handle = asHandle(client_ptr) orelse return -1;
    handle.dgram_cb = cb;
    handle.dgram_user = user;
    if (cb != null) {
        handle.client.onQuicDatagram(datagramDispatch, handle);
    } else {
        handle.client.onQuicDatagram(datagramDispatch, null);
    }
    return 0;
}

pub fn clientFetch(
    client_ptr: ?*ZigClient,
    opts_ptr: ?*const ZigFetchOptions,
    stream_id_out: ?*u64,
    cb: FetchCallback,
    user: ?*anyopaque,
) i32 {
    const handle = asHandle(client_ptr) orelse return -1;
    if (opts_ptr == null or cb == null) return -2;
    const opts_ref = opts_ptr.?;
    const opts = opts_ref.*;
    if (opts.path == null or opts.path_len == 0) return -3;

    var fetch_opts = makeFetchOptions(handle, opts_ref) catch |err| {
        return mapClientError(err);
    };
    defer cleanupFetchOptions(handle, &fetch_opts);

    const wants_stream = opts.collect_body == 0;
    var event_ctx_ptr: ?*FetchEventContext = null;
    defer if (event_ctx_ptr) |ctx_ptr| {
        handle.allocator.destroy(ctx_ptr);
    };

    if (wants_stream) {
        const event_cb = opts.event_cb orelse {
            return -4;
        };
        const ctx = handle.allocator.create(FetchEventContext) catch {
            return mapClientError(error.OutOfMemory);
        };
        ctx.* = .{
            .handle = handle,
            .cb = event_cb,
            .user = opts.event_user,
            .last_status = 0,
            .stream_id = 0,
        };
        fetch_opts.on_event = responseEventThunk;
        fetch_opts.event_ctx = @ptrCast(@alignCast(ctx));
        event_ctx_ptr = ctx;
    } else {
        fetch_opts.on_event = null;
        fetch_opts.event_ctx = null;
    }

    var fetch_handle = handle.client.startRequest(handle.allocator, fetch_opts) catch |err| {
        return mapClientError(err);
    };

    const stream_id = fetch_handle.stream_id;
    if (event_ctx_ptr) |ctx| {
        ctx.stream_id = stream_id;
    }
    if (stream_id_out) |out_ptr| {
        out_ptr.* = stream_id;
    }

    if (event_ctx_ptr) |ctx| {
        if (ctx.cb) |cb_fn| {
            ctx.event_storage = ZigFetchEvent{
                .kind = ZigFetchEventType.started,
                .status = 0,
                .headers = null,
                .headers_len = 0,
                .data = null,
                .data_len = 0,
                .flow_id = 0,
                .stream_id = stream_id,
            };
            cb_fn(ctx.user, &ctx.event_storage);
        }
    }

    var response = fetch_handle.await() catch |err| {
        return mapClientError(err);
    };
    defer response.deinit(handle.allocator);

    const rc = deliverFetchResponse(handle, cb, user, &response);
    return rc;
}

pub fn clientCancelFetch(
    client_ptr: ?*ZigClient,
    stream_id: u64,
    error_code: i32,
) i32 {
    const handle = asHandle(client_ptr) orelse return -1;
    const err = errorFromCode(error_code);
    handle.client.cancelFetch(stream_id, err);
    return 0;
}

pub fn clientFetchSimple(
    client_ptr: ?*ZigClient,
    method_ptr: ?[*:0]const u8,
    path_ptr: ?[*:0]const u8,
    collect_body: u8,
    stream_body: u8,
    request_timeout_ms: u32,
    event_cb: FetchEventCallback,
    event_user: ?*anyopaque,
    cb: FetchCallback,
    user: ?*anyopaque,
    stream_id_out: ?*u64,
) i32 {
    if (path_ptr == null) return -3;
    var opts = ZigFetchOptions{};
    if (method_ptr) |m_ptr| {
        const method = std.mem.span(m_ptr);
        opts.method = method.ptr;
        opts.method_len = method.len;
    }
    const path = std.mem.span(path_ptr.?);
    opts.path = path.ptr;
    opts.path_len = path.len;
    opts.collect_body = collect_body;
    opts.stream_body = stream_body;
    opts.event_cb = event_cb;
    opts.event_user = event_user;
    opts.request_timeout_ms = request_timeout_ms;
    return clientFetch(client_ptr, &opts, stream_id_out, cb, user);
}

pub fn fetchEventStructSize() usize {
    return @sizeOf(ZigFetchEvent);
}

pub fn headerStructSize() usize {
    return @sizeOf(ZigHeader);
}

pub fn fetchEventCopy(src: ?*const ZigFetchEvent, dst: ?*ZigFetchEvent) i32 {
    if (src == null or dst == null) return -1;
    dst.?.* = src.?.*;
    return 0;
}

pub fn headerCopy(src: ?*const ZigHeader, dst: ?*ZigHeader) i32 {
    if (src == null or dst == null) return -1;
    dst.?.* = src.?.*;
    return 0;
}

pub fn headerCopyAt(base: ?*const ZigHeader, len: usize, index: usize, dst: ?*ZigHeader) i32 {
    if (base == null or dst == null) return -1;
    const base_many: ?[*]const ZigHeader = if (base) |b| @ptrCast(b) else null;
    const slice = headersFromC(base_many, len);
    if (index >= slice.len) return -2;
    dst.?.* = slice[index];
    return 0;
}

pub fn headersCopy(base: ?*const ZigHeader, len: usize, dst: ?*ZigHeader, dst_len: usize) i32 {
    if (base == null or dst == null) return -1;
    const base_many: ?[*]const ZigHeader = if (base) |b| @ptrCast(b) else null;
    const slice = headersFromC(base_many, len);
    if (slice.len == 0) return 0;
    if (dst_len < slice.len) return -2;
    const dst_many: [*]ZigHeader = @ptrCast(dst.?);
    for (slice, 0..) |hdr, idx| {
        dst_many[idx] = hdr;
    }
    return @as(i32, @intCast(slice.len));
}

pub fn copyBytes(src: ?[*]const u8, len: usize, dst: ?*u8) i32 {
    if (src == null or dst == null) return -1;
    if (len == 0) return 0;
    const slice = src.?[0..len];
    const dst_many: [*]u8 = @ptrCast(dst.?);
    const dst_slice = dst_many[0..len];
    std.mem.copyForwards(u8, dst_slice, slice);
    return @as(i32, @intCast(len));
}

pub fn clientSendH3Datagram(
    client_ptr: ?*ZigClient,
    stream_id: u64,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    const handle = asHandle(client_ptr) orelse return -1;
    if (data_len == 0 or data_ptr == null) return 0;
    const data = sliceFromC(data_ptr, data_len);
    handle.client.sendH3Datagram(stream_id, data) catch |err| return mapClientError(err);
    return 0;
}

pub fn clientSendDatagram(
    client_ptr: ?*ZigClient,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    const handle = asHandle(client_ptr) orelse return -1;
    if (data_len == 0 or data_ptr == null) return 0;
    const data = sliceFromC(data_ptr, data_len);
    handle.client.sendQuicDatagram(data) catch |err| return mapClientError(err);
    return 0;
}
