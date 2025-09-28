const std = @import("std");
const client_cfg = @import("../quic/client/config.zig");
const client_mod = @import("../quic/client/mod.zig");
const http = @import("../http/mod.zig");
const errors = @import("../errors.zig");

const Allocator = std.mem.Allocator;
const QuicClient = client_mod.QuicClient;
const ClientConfig = client_cfg.ClientConfig;
const ServerEndpoint = client_cfg.ServerEndpoint;
const Method = http.Method;

pub const ZigClientConfig = extern struct {
    verify_peer: u8 = 1,
    enable_dgram: u8 = 0,
    enable_webtransport: u8 = 0,
    idle_timeout_ms: u32 = 30000,
    request_timeout_ms: u32 = 30000,
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
};

pub const ZigClient = opaque {};

const FetchCallback = ?*const fn (
    user: ?*anyopaque,
    status: u16,
    headers: ?[*]const ZigHeader,
    headers_len: usize,
    body: ?[*]const u8,
    body_len: usize,
    trailers: ?[*]const ZigHeader,
    trailers_len: usize,
) callconv(.C) void;

const DatagramCallback = ?*const fn (user: ?*anyopaque, flow_id: u64, payload: ?[*]const u8, payload_len: usize) callconv(.C) void;

const ClientHandle = struct {
    allocator: Allocator,
    client: *QuicClient,
    config: ClientConfig,
    dgram_cb: DatagramCallback = null,
    dgram_user: ?*anyopaque = null,
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
    var fetch_opts = client_mod.FetchOptions{};
    if (opts.method_len > 0 and opts.method) |method_ptr| {
        const method_slice = method_ptr[0..opts.method_len];
        fetch_opts.method = Method.fromString(method_slice) orelse Method.GET;
    }
    if (opts.path_len > 0 and opts.path) |path_ptr| {
        fetch_opts.path = path_ptr[0..opts.path_len];
    }
    if (opts.headers_len > 0 and opts.headers) |hdr_ptr| {
        const hdrs = hdr_ptr[0..opts.headers_len];
        fetch_opts.headers = try adoptHeaders(handle.allocator, hdrs);
    }
    if (opts.body_len > 0 and opts.body) |body_ptr| {
        fetch_opts.body = body_ptr[0..opts.body_len];
    }
    fetch_opts.collect_body = opts.collect_body != 0;
    fetch_opts.stream_request_body = opts.stream_body != 0;
    return fetch_opts;
}

fn cleanupFetchOptions(handle: *ClientHandle, fo: *client_mod.FetchOptions) void {
    if (fo.headers.len > 0) handle.allocator.free(fo.headers);
}

fn buildTempHeaders(allocator: Allocator, pairs: []client_mod.HeaderPair) ![]ZigHeader {
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

fn applyClientConfig(base: *ClientConfig, cfg_ptr: ?*const ZigClientConfig) void {
    if (cfg_ptr) |cfg| {
        base.verify_peer = cfg.verify_peer != 0;
        base.enable_dgram = cfg.enable_dgram != 0;
        base.enable_webtransport = cfg.enable_webtransport != 0;
        base.idle_timeout_ms = cfg.idle_timeout_ms;
        base.request_timeout_ms = cfg.request_timeout_ms;
        base.connect_timeout_ms = cfg.request_timeout_ms;
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

pub export fn zig_h3_client_new(cfg_ptr: ?*const ZigClientConfig) ?*ZigClient {
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

pub export fn zig_h3_client_free(client_ptr: ?*ZigClient) i32 {
    if (asHandle(client_ptr)) |handle| {
        handle.client.deinit();
        handle.allocator.destroy(handle);
        return 0;
    }
    return -1;
}

pub export fn zig_h3_client_connect(
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

pub export fn zig_h3_client_set_datagram_callback(
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

pub export fn zig_h3_client_fetch(
    client_ptr: ?*ZigClient,
    opts_ptr: ?*const ZigFetchOptions,
    cb: FetchCallback,
    user: ?*anyopaque,
) i32 {
    const handle = asHandle(client_ptr) orelse return -1;
    if (opts_ptr == null or cb == null) return -2;
    const opts = opts_ptr.?;
    if (opts.path == null or opts.path_len == 0) return -3;

    var fetch_opts = makeFetchOptions(handle, &opts) catch |err| {
        return mapClientError(err);
    };
    defer cleanupFetchOptions(handle, &fetch_opts);

    if (!fetch_opts.collect_body) {
        return -4; // streaming not yet supported
    }

    var response = handle.client.fetchWithOptions(handle.allocator, fetch_opts) catch |err| {
        return mapClientError(err);
    };
    defer response.deinit(handle.allocator);

    const rc = deliverFetchResponse(handle, cb, user, &response);
    return rc;
}

pub export fn zig_h3_client_send_h3_datagram(
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

pub export fn zig_h3_client_send_datagram(
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
