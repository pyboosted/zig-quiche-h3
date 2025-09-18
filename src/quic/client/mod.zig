const std = @import("std");
const builtin = @import("builtin");
const quiche = @import("quiche");
const client_cfg = @import("config.zig");
const EventLoop = @import("event_loop").EventLoop;
const TimerHandle = @import("event_loop").TimerHandle;
const udp = @import("udp");
const connection = @import("connection");
const server_pkg = if (builtin.is_test) @import("server") else struct {};
const ServerConfig = @import("config").ServerConfig;
const routing_gen = @import("routing_gen");
const routing_api = @import("routing");
const logging = @import("logging.zig");

const AutoHashMap = std.AutoHashMap;

const h3 = @import("h3");

const posix = std.posix;
const QuicheError = quiche.QuicheError;
const QuicServer = if (builtin.is_test) server_pkg.QuicServer else struct {};
const H3Connection = h3.H3Connection;
const H3Config = h3.H3Config;
const h3_datagram = h3.datagram;

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const ResponseEvent = union(enum) {
    headers: []const HeaderPair,
    data: []const u8,
    trailers: []const HeaderPair,
    finished,
    datagram: DatagramEvent,
};

pub const DatagramEvent = struct {
    flow_id: u64,
    payload: []const u8,
};

pub const ResponseCallback = *const fn (event: ResponseEvent, ctx: ?*anyopaque) ClientError!void;
pub const BodyChunkResult = union(enum) {
    chunk: []const u8,
    finished,
};

pub const RequestBodyProvider = struct {
    ctx: ?*anyopaque = null,
    next: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) ClientError!BodyChunkResult,
};

pub const FetchOptions = struct {
    method: []const u8 = "GET",
    path: []const u8,
    headers: []const HeaderPair = &.{},
    body: []const u8 = &.{},
    body_provider: ?RequestBodyProvider = null,
    on_event: ?ResponseCallback = null,
    event_ctx: ?*anyopaque = null,
};

pub const ClientConfig = client_cfg.ClientConfig;
pub const ServerEndpoint = client_cfg.ServerEndpoint;

pub const FetchResponse = struct {
    status: u16,
    body: []u8,
    headers: []HeaderPair,
    trailers: []HeaderPair,

    pub fn deinit(self: *FetchResponse, allocator: std.mem.Allocator) void {
        if (self.body.len > 0) allocator.free(self.body);
        for (self.headers) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        if (self.headers.len > 0) allocator.free(self.headers);
        for (self.trailers) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        if (self.trailers.len > 0) allocator.free(self.trailers);
        self.* = undefined;
    }
};

pub const ClientError = error{
    AlreadyConnecting,
    AlreadyConnected,
    AlreadyClosed,
    DnsResolveFailed,
    SocketSetupFailed,
    UnsupportedAddressFamily,
    HandshakeTimeout,
    HandshakeFailed,
    QuicSendFailed,
    QuicRecvFailed,
    IoFailure,
    NoConnection,
    NoSocket,
    QlogSetupFailed,
    KeylogSetupFailed,
    ConnectionClosed,
    H3Error,
    ResponseIncomplete,
    UnexpectedStream,
    NoAuthority,
    InvalidRequest,
    DatagramNotEnabled,
    DatagramTooLarge,
    DatagramSendFailed,
};

const State = enum { idle, connecting, established, closed };

const FetchState = struct {
    allocator: std.mem.Allocator,
    stream_id: u64 = 0,
    status: ?u16 = null,
    body_chunks: std.array_list.Managed(u8),
    finished: bool = false,
    err: ?ClientError = null,
    awaiting: bool = false,
    collect_body: bool = true,
    response_callback: ?ResponseCallback = null,
    response_ctx: ?*anyopaque = null,
    body_buffer: []const u8 = &.{},
    body_sent: usize = 0,
    body_owned: bool = false,
    body_finished: bool = true,
    body_provider: ?RequestBodyProvider = null,
    provider_done: bool = true,
    headers: std.array_list.Managed(HeaderPair),
    trailers: std.array_list.Managed(HeaderPair),
    have_headers: bool = false,

    fn init(allocator: std.mem.Allocator) !*FetchState {
        const self = try allocator.create(FetchState);
        self.* = .{
            .allocator = allocator,
            .stream_id = 0,
            .status = null,
            .body_chunks = std.array_list.Managed(u8).init(allocator),
            .finished = false,
            .err = null,
            .awaiting = false,
            .collect_body = true,
            .response_callback = null,
            .response_ctx = null,
            .body_buffer = &.{},
            .body_sent = 0,
            .body_owned = false,
            .body_finished = true,
            .body_provider = null,
            .provider_done = true,
            .headers = std.array_list.Managed(HeaderPair).init(allocator),
            .trailers = std.array_list.Managed(HeaderPair).init(allocator),
            .have_headers = false,
        };
        return self;
    }

    fn hasPendingBody(self: *FetchState) bool {
        const pending_buffer = self.body_buffer.len > self.body_sent;
        return pending_buffer or !self.provider_done;
    }

    fn takeBody(self: *FetchState) ![]u8 {
        if (!self.collect_body) {
            return try self.allocator.alloc(u8, 0);
        }
        return self.body_chunks.toOwnedSlice();
    }

    fn destroy(self: *FetchState) void {
        self.body_chunks.deinit();
        if (self.body_owned and self.body_buffer.len > 0) {
            self.allocator.free(@constCast(self.body_buffer));
        }
        self.destroyHeaderList(&self.headers);
        self.destroyHeaderList(&self.trailers);
        self.allocator.destroy(self);
    }

    fn destroyHeaderList(self: *FetchState, list: *std.array_list.Managed(HeaderPair)) void {
        for (list.items) |pair| {
            self.allocator.free(pair.name);
            self.allocator.free(pair.value);
        }
        list.deinit();
    }
};

pub const FetchHandle = struct {
    client: *QuicClient,
    stream_id: u64,

    pub fn isFinished(self: FetchHandle) bool {
        const state = self.client.requests.get(self.stream_id) orelse return true;
        return state.finished;
    }

    pub fn await(self: FetchHandle) ClientError!FetchResponse {
        const client = self.client;
        const state = client.requests.get(self.stream_id) orelse return ClientError.ResponseIncomplete;

        while (!state.finished and state.err == null) {
            state.awaiting = true;
            defer state.awaiting = false;
            client.event_loop.run();
        }

        return client.finalizeFetch(self.stream_id);
    }
};

pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    quiche_config: quiche.Config,
    h3_config: H3Config,
    event_loop: *EventLoop,

    socket: ?udp.UdpSocket = null,
    conn: ?quiche.Connection = null,
    h3_conn: ?H3Connection = null,

    remote_addr: posix.sockaddr.storage = undefined,
    remote_addr_len: posix.socklen_t = 0,
    local_addr: posix.sockaddr.storage = undefined,
    local_addr_len: posix.socklen_t = 0,

    timeout_timer: ?TimerHandle = null,
    connect_timer: ?TimerHandle = null,

    state: State = .idle,
    handshake_error: ?ClientError = null,

    send_buf: [2048]u8 = undefined,
    recv_buf: [2048]u8 = undefined,
    datagram_buf: [2048]u8 = undefined,

    qlog_path: ?[:0]u8 = null,
    keylog_path: ?[:0]u8 = null,

    io_registered: bool = false,
    current_scid: ?[16]u8 = null,

    server_host: ?[]u8 = null,
    server_authority: ?[]u8 = null,
    server_port: ?u16 = null,

    log_context: ?*logging.LogContext = null,

    requests: AutoHashMap(u64, *FetchState),

    pub fn init(allocator: std.mem.Allocator, cfg: ClientConfig) !*QuicClient {
        try cfg.validate();
        try cfg.ensureQlogDir();

        var q_cfg = try quiche.Config.new(quiche.PROTOCOL_VERSION);
        errdefer q_cfg.deinit();

        const alpn_wire = try quiche.encodeAlpn(allocator, cfg.alpn_protocols);
        defer allocator.free(alpn_wire);
        try q_cfg.setApplicationProtos(alpn_wire);
        q_cfg.setMaxIdleTimeout(cfg.idle_timeout_ms);
        q_cfg.setInitialMaxData(cfg.initial_max_data);
        q_cfg.setInitialMaxStreamDataBidiLocal(cfg.initial_max_stream_data_bidi_local);
        q_cfg.setInitialMaxStreamDataBidiRemote(cfg.initial_max_stream_data_bidi_remote);
        q_cfg.setInitialMaxStreamDataUni(cfg.initial_max_stream_data_uni);
        q_cfg.setInitialMaxStreamsBidi(cfg.initial_max_streams_bidi);
        q_cfg.setInitialMaxStreamsUni(cfg.initial_max_streams_uni);
        q_cfg.setMaxRecvUdpPayloadSize(cfg.max_recv_udp_payload_size);
        q_cfg.setMaxSendUdpPayloadSize(cfg.max_send_udp_payload_size);
        q_cfg.setDisableActiveMigration(cfg.disable_active_migration);
        q_cfg.enablePacing(cfg.enable_pacing);
        q_cfg.enableDgram(cfg.enable_dgram, cfg.dgram_recv_queue_len, cfg.dgram_send_queue_len);
        q_cfg.grease(cfg.grease);

        const cc_algo = try allocator.dupeZ(u8, cfg.cc_algorithm);
        defer allocator.free(cc_algo);
        if (q_cfg.setCcAlgorithmName(cc_algo)) |_| {
            // OK
        } else |err| {
            std.debug.print("[client] cc={s} unsupported ({any}); falling back to cubic\n", .{ cfg.cc_algorithm, err });
            const fallback = try allocator.dupeZ(u8, "cubic");
            defer allocator.free(fallback);
            _ = q_cfg.setCcAlgorithmName(fallback) catch {};
        }

        q_cfg.verifyPeer(cfg.verify_peer);

        // Load CA bundle configuration if verification is enabled
        if (cfg.verify_peer) {
            if (cfg.ca_bundle_path) |path| {
                const ca_path_z = try allocator.dupeZ(u8, path);
                defer allocator.free(ca_path_z);

                q_cfg.loadVerifyLocationsFromFile(ca_path_z[0..ca_path_z.len :0]) catch |err| {
                    std.debug.print("[client] Failed to load CA bundle from {s}: {}\n", .{ path, err });
                    return error.LoadCABundleFailed;
                };
            }

            if (cfg.ca_bundle_dir) |dir| {
                const ca_dir_z = try allocator.dupeZ(u8, dir);
                defer allocator.free(ca_dir_z);

                q_cfg.loadVerifyLocationsFromDirectory(ca_dir_z[0..ca_dir_z.len :0]) catch |err| {
                    std.debug.print("[client] Failed to load CA directory from {s}: {}\n", .{ dir, err });
                    return error.LoadCADirectoryFailed;
                };
            }
        }

        // Set up debug logging if enabled
        var log_ctx: ?*logging.LogContext = null;
        if (cfg.enable_debug_logging) {
            log_ctx = try allocator.create(logging.LogContext);
            errdefer if (log_ctx) |ctx| allocator.destroy(ctx);
            log_ctx.?.* = logging.LogContext.init(cfg.debug_log_throttle);

            try quiche.enableDebugLogging(logging.debugLogCallback, log_ctx);
        }

        var h3_cfg = try H3Config.initWithDefaults();
        var h3_cfg_cleanup = true;
        errdefer if (h3_cfg_cleanup) h3_cfg.deinit();

        const loop = try EventLoop.initLibev(allocator);
        errdefer loop.deinit();

        const self = try allocator.create(QuicClient);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .config = cfg,
            .quiche_config = q_cfg,
            .h3_config = h3_cfg,
            .event_loop = loop,
            .socket = null,
            .conn = null,
            .h3_conn = null,
            .remote_addr = undefined,
            .remote_addr_len = 0,
            .local_addr = undefined,
            .local_addr_len = 0,
            .timeout_timer = null,
            .connect_timer = null,
            .state = .idle,
            .handshake_error = null,
            .send_buf = undefined,
            .recv_buf = undefined,
            .qlog_path = null,
            .keylog_path = null,
            .io_registered = false,
            .current_scid = null,
            .server_host = null,
            .server_authority = null,
            .server_port = null,
            .log_context = log_ctx,
            .requests = AutoHashMap(u64, *FetchState).init(allocator),
        };

        self.timeout_timer = try loop.createTimer(onQuicTimeout, self);
        self.connect_timer = try loop.createTimer(onConnectTimeout, self);
        h3_cfg_cleanup = false;
        return self;
    }

    pub fn deinit(self: *QuicClient) void {
        if (self.h3_conn) |*h3_conn_ref| {
            h3_conn_ref.deinit();
            self.h3_conn = null;
        }

        self.h3_config.deinit();

        if (self.conn) |*conn_ref| {
            conn_ref.deinit();
            self.conn = null;
        }

        if (self.qlog_path) |path| {
            const total = path.len + 1;
            self.allocator.free(path.ptr[0..total]);
            self.qlog_path = null;
        }

        if (self.keylog_path) |path| {
            const total = path.len + 1;
            self.allocator.free(path.ptr[0..total]);
            self.keylog_path = null;
        }

        if (self.server_host) |host| {
            self.allocator.free(host);
            self.server_host = null;
        }

        if (self.server_authority) |authority| {
            self.allocator.free(authority);
            self.server_authority = null;
        }

        var it = self.requests.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.destroy();
        }
        self.requests.deinit();

        if (self.socket) |*sock| {
            sock.close();
            self.socket = null;
        }

        if (self.timeout_timer) |handle| {
            self.event_loop.destroyTimer(handle);
            self.timeout_timer = null;
        }

        if (self.connect_timer) |handle| {
            self.event_loop.destroyTimer(handle);
            self.connect_timer = null;
        }

        if (self.log_context) |ctx| {
            self.allocator.destroy(ctx);
            self.log_context = null;
        }

        self.event_loop.deinit();
        self.quiche_config.deinit();
        self.allocator.destroy(self);
    }

    pub fn connect(self: *QuicClient, endpoint: ServerEndpoint) ClientError!void {
        switch (self.state) {
            .idle => {},
            .connecting => return ClientError.AlreadyConnecting,
            .established => return ClientError.AlreadyConnected,
            .closed => return ClientError.AlreadyClosed,
        }

        endpoint.validate() catch {
            return ClientError.InvalidRequest;
        };

        const address = resolvePreferredAddress(self.allocator, endpoint.host, endpoint.port) catch {
            return ClientError.DnsResolveFailed;
        };

        const remote = storageFromAddress(address);
        var sock = openSocket(address) catch |err| switch (err) {
            ClientError.UnsupportedAddressFamily => return err,
            else => return ClientError.SocketSetupFailed,
        };
        errdefer sock.close();

        var local_storage: posix.sockaddr.storage = undefined;
        var local_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(sock.fd, @ptrCast(&local_storage), &local_len) catch {
            return ClientError.SocketSetupFailed;
        };

        self.remote_addr = remote.storage;
        self.remote_addr_len = remote.len;
        self.local_addr = local_storage;
        self.local_addr_len = local_len;

        if (!self.io_registered) {
            self.event_loop.addUdpIo(sock.fd, onUdpReadable, self) catch {
                return ClientError.SocketSetupFailed;
            };
            self.io_registered = true;
        }

        self.socket = sock;
        sock.fd = -1;

        const server_name = endpoint.sniHost();
        const server_name_z = self.allocator.dupeZ(u8, server_name) catch {
            return ClientError.H3Error;
        };
        defer self.allocator.free(server_name_z);

        const scid = connection.generateScid();
        self.current_scid = scid;

        var q_conn = quiche.connect(
            server_name_z[0..server_name_z.len :0],
            scid[0..],
            @ptrCast(&self.local_addr),
            self.local_addr_len,
            @ptrCast(&self.remote_addr),
            self.remote_addr_len,
            &self.quiche_config,
        ) catch {
            return ClientError.SocketSetupFailed;
        };

        self.conn = q_conn;

        if (self.config.qlog_dir != null) {
            self.setupQlog(scid[0..]) catch |err| {
                self.conn = null;
                q_conn.deinit();
                return err;
            };
        }

        if (self.config.keylog_path) |path| {
            const keylog = self.allocator.dupeZ(u8, path) catch {
                return ClientError.KeylogSetupFailed;
            };
            const keylog_z: [:0]u8 = keylog[0..keylog.len :0];
            if (!q_conn.setKeylogPath(keylog_z)) {
                self.allocator.free(keylog);
                self.conn = null;
                q_conn.deinit();
                return ClientError.KeylogSetupFailed;
            }
            self.keylog_path = keylog_z;
        }

        self.state = .connecting;
        self.handshake_error = null;

        self.flushSend() catch |err| {
            self.recordFailure(err);
            return err;
        };
        self.afterQuicProgress();

        if (self.connect_timer) |handle| {
            const timeout_s = @as(f64, @floatFromInt(self.config.connect_timeout_ms)) / 1000.0;
            self.event_loop.startTimer(handle, timeout_s, 0);
        }

        self.event_loop.run();
        self.stopConnectTimer();

        switch (self.state) {
            .established => {
                try self.rememberEndpoint(endpoint);
                return;
            },
            .closed => {
                if (self.conn) |*conn_ref| {
                    conn_ref.deinit();
                    self.conn = null;
                }
                const err = self.handshake_error orelse ClientError.HandshakeFailed;
                return err;
            },
            else => return ClientError.HandshakeFailed,
        }
    }

    pub fn isEstablished(self: *const QuicClient) bool {
        return self.state == .established;
    }

    pub fn fetch(self: *QuicClient, allocator: std.mem.Allocator, path: []const u8) ClientError!FetchResponse {
        return self.fetchWithOptions(allocator, .{ .path = path });
    }

    pub fn fetchWithOptions(self: *QuicClient, allocator: std.mem.Allocator, options: FetchOptions) ClientError!FetchResponse {
        const handle = try self.startRequest(allocator, options);
        return handle.await();
    }

    pub fn startGet(self: *QuicClient, allocator: std.mem.Allocator, path: []const u8) ClientError!FetchHandle {
        return self.startRequest(allocator, .{ .path = path });
    }

    pub fn sendH3Datagram(self: *QuicClient, stream_id: u64, payload: []const u8) ClientError!void {
        const conn = try self.requireConn();
        try self.ensureH3();
        const h3_conn = &self.h3_conn.?;

        if (!h3_conn.dgramEnabledByPeer(conn)) return ClientError.DatagramNotEnabled;

        const flow_id = h3_datagram.flowIdForStream(stream_id);
        const overhead = h3_datagram.varintLen(flow_id);
        const total_len = overhead + payload.len;

        if (conn.dgramMaxWritableLen()) |maxw| {
            if (total_len > maxw) return ClientError.DatagramTooLarge;
        }

        var stack_buf: [2048]u8 = undefined;
        var buf: []u8 = stack_buf[0..];
        var use_heap = false;
        if (total_len <= stack_buf.len) {
            buf = stack_buf[0..total_len];
        } else {
            buf = self.allocator.alloc(u8, total_len) catch {
                return ClientError.H3Error;
            };
            use_heap = true;
        }
        defer if (use_heap) self.allocator.free(buf);

        const written = h3_datagram.encodeVarint(buf, flow_id) catch {
            return ClientError.H3Error;
        };
        @memcpy(buf[written..][0..payload.len], payload);

        const sent = conn.dgramSend(buf) catch |err| switch (err) {
            error.Done => return ClientError.DatagramSendFailed,
            else => return ClientError.DatagramSendFailed,
        };

        if (sent != buf.len) return ClientError.DatagramSendFailed;

        self.flushSend() catch |err| return err;
        self.afterQuicProgress();
    }

    pub fn startRequest(self: *QuicClient, allocator: std.mem.Allocator, options: FetchOptions) ClientError!FetchHandle {
        if (self.state != .established) return ClientError.NoConnection;
        if (self.server_authority == null) return ClientError.NoAuthority;
        if (options.path.len == 0) return ClientError.InvalidRequest;

        const conn = try self.requireConn();
        try self.ensureH3();
        const h3_conn = &self.h3_conn.?;

        var state = FetchState.init(allocator) catch {
            return ClientError.H3Error;
        };
        var state_cleanup = true;
        defer if (state_cleanup) state.destroy();

        state.collect_body = options.on_event == null;
        state.response_callback = options.on_event;
        state.response_ctx = options.event_ctx;

        if (options.body_provider) |provider| {
            state.body_provider = provider;
            state.provider_done = false;
            try self.loadNextBodyChunk(state);
        } else if (options.body.len > 0) {
            state.body_buffer = self.allocator.dupe(u8, options.body) catch {
                return ClientError.H3Error;
            };
            state.body_owned = true;
            state.body_finished = false;
        }

        const headers = try self.prepareRequestHeaders(options);
        defer self.allocator.free(headers);

        const has_body = state.body_buffer.len > 0 or !state.provider_done;
        const stream_id = h3_conn.sendRequest(conn, headers, !has_body) catch {
            return ClientError.H3Error;
        };
        state.stream_id = stream_id;

        self.requests.put(stream_id, state) catch {
            state.destroy();
            return ClientError.H3Error;
        };
        state_cleanup = false;

        if (has_body) {
            _ = self.trySendBody(stream_id, state) catch |err| {
                _ = self.requests.remove(stream_id);
                state.destroy();
                return err;
            };
        }

        self.flushSend() catch |err| {
            _ = self.requests.remove(stream_id);
            state.destroy();
            return err;
        };
        self.afterQuicProgress();

        return FetchHandle{ .client = self, .stream_id = stream_id };
    }

    fn rememberEndpoint(self: *QuicClient, endpoint: ServerEndpoint) ClientError!void {
        if (self.server_host) |prev| {
            self.allocator.free(prev);
            self.server_host = null;
        }
        if (self.server_authority) |prev| {
            self.allocator.free(prev);
            self.server_authority = null;
        }

        const host_copy = self.allocator.dupe(u8, endpoint.host) catch {
            return ClientError.H3Error;
        };
        errdefer self.allocator.free(host_copy);

        const authority = if (endpoint.port == 443)
            self.allocator.dupe(u8, endpoint.host) catch {
                self.allocator.free(host_copy);
                return ClientError.H3Error;
            }
        else
            std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ endpoint.host, endpoint.port }) catch {
                self.allocator.free(host_copy);
                return ClientError.H3Error;
            };
        errdefer self.allocator.free(authority);

        self.server_host = host_copy;
        self.server_authority = authority;
        self.server_port = endpoint.port;
    }

    fn ensureH3(self: *QuicClient) !void {
        if (self.h3_conn != null) return;
        const conn = try self.requireConn();
        const h3_conn = H3Connection.newWithTransport(self.allocator, conn, &self.h3_config) catch {
            return ClientError.H3Error;
        };
        self.h3_conn = h3_conn;
    }

    fn loadNextBodyChunk(self: *QuicClient, state: *FetchState) !void {
        const provider = state.body_provider orelse return;
        while (true) {
            const result = provider.next(provider.ctx, self.allocator) catch {
                return ClientError.H3Error;
            };

            switch (result) {
                .finished => {
                    state.provider_done = true;
                    state.body_buffer = &.{};
                    state.body_sent = 0;
                    state.body_owned = false;
                    state.body_finished = true;
                    return;
                },
                .chunk => |data| {
                    if (data.len == 0) continue;
                    state.body_buffer = data;
                    state.body_sent = 0;
                    state.body_owned = true;
                    state.body_finished = false;
                    return;
                },
            }
        }
    }

    fn trySendBody(self: *QuicClient, stream_id: u64, state: *FetchState) ClientError!bool {
        const conn = try self.requireConn();
        var wrote_any = false;

        while (state.hasPendingBody()) {
            if (state.body_buffer.len == state.body_sent and !state.provider_done) {
                if (state.body_owned and state.body_buffer.len > 0) {
                    self.allocator.free(@constCast(state.body_buffer));
                    state.body_owned = false;
                }
                state.body_buffer = &.{};
                state.body_sent = 0;
                state.body_finished = true;
                try self.loadNextBodyChunk(state);
                if (state.body_buffer.len == 0 and state.provider_done) break;
            }

            const capacity = conn.streamCapacity(stream_id) catch {
                return ClientError.H3Error;
            };
            if (capacity == 0) break;

            const buf_len = state.body_buffer.len;
            if (state.body_sent >= buf_len) {
                if (!state.provider_done) continue;
                break;
            }

            const remaining = buf_len - state.body_sent;
            const chunk_len = if (capacity < remaining) capacity else remaining;
            if (chunk_len == 0) break;

            const end_index = state.body_sent + chunk_len;
            const chunk = state.body_buffer[state.body_sent..end_index];
            const fin = end_index == state.body_buffer.len and state.provider_done;

            const written = conn.streamSend(stream_id, chunk, fin) catch |err| switch (err) {
                error.SendFailed => return ClientError.H3Error,
                else => return ClientError.H3Error,
            };

            if (written == 0) break;
            state.body_sent += written;
            wrote_any = true;

            if (state.body_sent == buf_len) {
                if (state.body_owned and buf_len > 0) {
                    self.allocator.free(@constCast(state.body_buffer));
                    state.body_owned = false;
                }
                state.body_buffer = &.{};
                state.body_sent = 0;
                state.body_finished = true;
                if (!state.provider_done) {
                    try self.loadNextBodyChunk(state);
                    continue;
                }
            }

            if (written < chunk_len) break;
        }

        if (state.body_sent == state.body_buffer.len) {
            state.body_finished = true;
        }

        return wrote_any;
    }

    fn emitEvent(self: *QuicClient, state: *FetchState, event: ResponseEvent) bool {
        if (state.response_callback) |cb| {
            cb(event, state.response_ctx) catch |err| {
                self.failFetch(state.stream_id, err);
                return false;
            };
        }
        return true;
    }

    fn sendPendingBodies(self: *QuicClient) void {
        if (self.requests.count() == 0) return;
        var wrote_any = false;
        var it = self.requests.iterator();
        while (it.next()) |entry| {
            const stream_id = entry.key_ptr.*;
            const state = entry.value_ptr.*;
            if (!state.hasPendingBody()) continue;
            const wrote = self.trySendBody(stream_id, state) catch |err| {
                self.failFetch(stream_id, err);
                continue;
            };
            if (wrote) wrote_any = true;
        }

        if (wrote_any) {
            self.flushSend() catch |err| {
                self.failAll(err);
            };
        }
    }

    fn finalizeFetch(self: *QuicClient, stream_id: u64) ClientError!FetchResponse {
        const state = self.requests.get(stream_id) orelse return ClientError.ResponseIncomplete;
        defer {
            _ = self.requests.remove(stream_id);
            state.destroy();
        }

        if (state.err) |fetch_err| {
            return fetch_err;
        }

        if (!state.finished or state.status == null) {
            return ClientError.ResponseIncomplete;
        }

        const body = state.takeBody() catch {
            return ClientError.H3Error;
        };
        const headers = state.headers.toOwnedSlice() catch {
            return ClientError.H3Error;
        };
        const trailers = state.trailers.toOwnedSlice() catch {
            return ClientError.H3Error;
        };

        return FetchResponse{
            .status = state.status.?,
            .body = body,
            .headers = headers,
            .trailers = trailers,
        };
    }

    fn setupQlog(self: *QuicClient, conn_id: []const u8) ClientError!void {
        const path = self.config.createQlogPath(self.allocator, conn_id) catch |err| switch (err) {
            error.QlogDisabled => return,
            else => return ClientError.QlogSetupFailed,
        };
        errdefer self.allocator.free(path.ptr[0 .. path.len + 1]);

        const title = self.allocator.dupeZ(u8, "quic-client") catch {
            return ClientError.QlogSetupFailed;
        };
        defer self.allocator.free(title);
        const desc = self.allocator.dupeZ(u8, "Zig QUIC Client") catch {
            return ClientError.QlogSetupFailed;
        };
        defer self.allocator.free(desc);

        const conn = try self.requireConn();
        if (!conn.setQlogPath(path, title[0..title.len :0], desc[0..desc.len :0])) {
            return ClientError.QlogSetupFailed;
        }

        self.qlog_path = path;
    }

    fn prepareRequestHeaders(self: *QuicClient, options: FetchOptions) ClientError![]quiche.h3.Header {
        const authority = self.server_authority orelse return ClientError.NoAuthority;
        if (options.method.len == 0) return ClientError.InvalidRequest;
        const scheme: []const u8 = "https";
        const user_agent: []const u8 = "zig-quiche-h3-client/0.1";

        const base_count: usize = 5;
        const total = base_count + options.headers.len;
        var headers = self.allocator.alloc(quiche.h3.Header, total) catch {
            return ClientError.H3Error;
        };
        headers[0] = makeHeader(":method", options.method);
        headers[1] = makeHeader(":scheme", scheme);
        headers[2] = makeHeader(":authority", authority);
        headers[3] = makeHeader(":path", options.path);
        headers[4] = makeHeader("user-agent", user_agent);

        var idx: usize = base_count;
        for (options.headers) |h| {
            headers[idx] = makeHeader(h.name, h.value);
            idx += 1;
        }
        return headers;
    }

    fn makeHeader(name_literal: []const u8, value_slice: []const u8) quiche.h3.Header {
        const name = name_literal;
        return .{
            .name = name.ptr,
            .name_len = name.len,
            .value = value_slice.ptr,
            .value_len = value_slice.len,
        };
    }

    fn handleReadable(self: *QuicClient, fd: posix.socket_t) ClientError!void {
        const conn = try self.requireConn();
        if (self.socket == null) return ClientError.NoSocket;

        while (true) {
            var peer_addr: posix.sockaddr.storage = undefined;
            var peer_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const n = posix.recvfrom(fd, &self.recv_buf, 0, @ptrCast(&peer_addr), &peer_len) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return ClientError.IoFailure,
            };

            if (n == 0) break;

            var recv_info = quiche.c.quiche_recv_info{
                .from = @ptrCast(&peer_addr),
                .from_len = peer_len,
                .to = @ptrCast(&self.local_addr),
                .to_len = self.local_addr_len,
            };

            const slice = self.recv_buf[0..n];
            _ = conn.recv(slice, &recv_info) catch |err| switch (err) {
                QuicheError.Done => break,
                else => return ClientError.QuicRecvFailed,
            };
        }

        try self.flushSend();
        self.afterQuicProgress();
    }

    fn flushSend(self: *QuicClient) ClientError!void {
        const conn = try self.requireConn();
        const sock = self.socket orelse return ClientError.NoSocket;

        while (true) {
            var send_info: quiche.c.quiche_send_info = undefined;
            const written = conn.send(self.send_buf[0..], &send_info) catch |err| switch (err) {
                QuicheError.Done => break,
                else => return ClientError.QuicSendFailed,
            };

            const payload = self.send_buf[0..written];
            const dest_ptr: *const posix.sockaddr = if (send_info.to_len != 0)
                @ptrCast(&send_info.to)
            else
                @ptrCast(&self.remote_addr);
            const dest_len: posix.socklen_t = if (send_info.to_len != 0)
                send_info.to_len
            else
                self.remote_addr_len;

            _ = posix.sendto(sock.fd, payload, 0, dest_ptr, dest_len) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return ClientError.IoFailure,
            };
        }
    }

    fn handleTimeout(self: *QuicClient) ClientError!void {
        const conn = try self.requireConn();
        conn.onTimeout();
        try self.flushSend();
        self.afterQuicProgress();
    }

    fn afterQuicProgress(self: *QuicClient) void {
        self.updateTimeout();
        self.sendPendingBodies();
        self.checkHandshakeState();
        self.processH3Events();
        self.processDatagrams();
    }

    fn updateTimeout(self: *QuicClient) void {
        if (self.timeout_timer) |handle| {
            const conn = if (self.conn) |*conn_ref| conn_ref else return;
            const timeout_ms = conn.timeoutAsMillis();
            if (timeout_ms == std.math.maxInt(u64)) {
                self.event_loop.stopTimer(handle);
                return;
            }
            const after_s = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
            self.event_loop.startTimer(handle, after_s, 0);
        }
    }

    fn checkHandshakeState(self: *QuicClient) void {
        const conn = if (self.conn) |*conn_ref| conn_ref else return;
        if (self.state != .connecting) return;

        if (conn.isEstablished()) {
            self.state = .established;
            self.handshake_error = null;
            self.stopTimeoutTimer();
            self.stopConnectTimer();
            self.event_loop.stop();
            return;
        }

        if (conn.isClosed()) {
            self.recordFailure(ClientError.ConnectionClosed);
        }
    }

    fn stopConnectTimer(self: *QuicClient) void {
        if (self.connect_timer) |handle| {
            self.event_loop.stopTimer(handle);
        }
    }

    fn stopTimeoutTimer(self: *QuicClient) void {
        if (self.timeout_timer) |handle| {
            self.event_loop.stopTimer(handle);
        }
    }

    fn processH3Events(self: *QuicClient) void {
        const conn = if (self.conn) |*conn_ref| conn_ref else return;
        const h3_conn = blk: {
            if (self.h3_conn) |*ptr| break :blk ptr;
            return;
        };

        while (true) {
            const result = h3_conn.poll(conn);
            if (result == null) break;
            var poll = result.?;
            defer poll.deinit();

            switch (poll.event_type) {
                .Headers => self.onH3Headers(poll.stream_id, poll.raw_event),
                .Data => self.onH3Data(poll.stream_id),
                .Finished => self.onH3Finished(poll.stream_id),
                .GoAway => {},
                .Reset => self.onH3Reset(poll.stream_id),
                .PriorityUpdate => {},
            }
        }
    }

    fn processDatagrams(self: *QuicClient) void {
        const conn = if (self.conn) |*conn_ref| conn_ref else return;

        while (true) {
            var buf_slice: []u8 = self.datagram_buf[0..];
            var use_heap = false;

            if (conn.dgramRecvFrontLen()) |hint| {
                if (hint > buf_slice.len) {
                    buf_slice = self.allocator.alloc(u8, hint) catch {
                        return;
                    };
                    use_heap = true;
                } else {
                    buf_slice = self.datagram_buf[0..hint];
                }
            }

            const read = conn.dgramRecv(buf_slice) catch |err| {
                if (use_heap) self.allocator.free(buf_slice);
                if (err == error.Done) return;
                return;
            };

            const payload = buf_slice[0..read];

            defer if (use_heap) self.allocator.free(buf_slice);

            const h3_conn_ptr = if (self.h3_conn) |*ptr| ptr else continue;

            if (!h3_conn_ptr.dgramEnabledByPeer(conn)) continue;

            const varint = h3_datagram.decodeVarint(payload) catch {
                continue;
            };
            if (varint.consumed > payload.len) continue;
            const flow_id = varint.value;
            const h3_payload = payload[varint.consumed..];
            const stream_id = h3_datagram.streamIdForFlow(flow_id);

            if (self.requests.get(stream_id)) |state| {
                if (state.response_callback == null) continue;

                const copy = state.allocator.dupe(u8, h3_payload) catch {
                    continue;
                };
                const event = ResponseEvent{ .datagram = .{ .flow_id = flow_id, .payload = copy } };
                _ = self.emitEvent(state, event);
                state.allocator.free(copy);
            }
        }
    }

    fn onH3Headers(self: *QuicClient, stream_id: u64, event: *quiche.c.quiche_h3_event) void {
        const state = self.requests.get(stream_id) orelse return;

        const headers = h3.collectHeaders(state.allocator, event) catch {
            self.failFetch(stream_id, ClientError.H3Error);
            return;
        };
        defer state.allocator.free(headers);

        const is_trailer = state.have_headers;
        var dest = if (is_trailer) &state.trailers else &state.headers;
        for (headers) |header| {
            if (!is_trailer and std.mem.eql(u8, header.name, ":status")) {
                const parsed = std.fmt.parseUnsigned(u16, header.value, 10) catch {
                    self.failFetch(stream_id, ClientError.H3Error);
                    return;
                };
                state.status = parsed;
            }
            dest.append(.{ .name = header.name, .value = header.value }) catch {
                self.failFetch(stream_id, ClientError.H3Error);
                return;
            };
        }

        if (!is_trailer) {
            state.have_headers = true;
            _ = self.emitEvent(state, ResponseEvent{ .headers = state.headers.items });
        } else {
            _ = self.emitEvent(state, ResponseEvent{ .trailers = state.trailers.items });
        }
    }

    fn onH3Data(self: *QuicClient, stream_id: u64) void {
        const state = self.requests.get(stream_id) orelse return;

        const conn = if (self.conn) |*conn_ref| conn_ref else return;
        const h3_conn_ptr = blk: {
            if (self.h3_conn) |*ptr| break :blk ptr;
            return;
        };
        var chunk: [2048]u8 = undefined;

        while (true) {
            const read = h3_conn_ptr.recvBody(conn, stream_id, chunk[0..]) catch |err| switch (err) {
                quiche.h3.Error.Done => break,
                else => {
                    self.failFetch(stream_id, ClientError.H3Error);
                    return;
                },
            };
            if (read == 0) break;
            const slice = chunk[0..read];
            if (state.collect_body) {
                state.body_chunks.appendSlice(slice) catch {
                    self.failFetch(stream_id, ClientError.H3Error);
                    return;
                };
            }

            if (!self.emitEvent(state, ResponseEvent{ .data = slice })) {
                return;
            }
        }
    }

    fn onH3Finished(self: *QuicClient, stream_id: u64) void {
        const state = self.requests.get(stream_id) orelse return;
        state.finished = true;
        _ = self.emitEvent(state, ResponseEvent.finished);
        if (state.awaiting) self.event_loop.stop();
    }

    fn onH3Reset(self: *QuicClient, stream_id: u64) void {
        self.failFetch(stream_id, ClientError.H3Error);
    }

    fn failFetch(self: *QuicClient, stream_id: u64, err: ClientError) void {
        if (self.requests.get(stream_id)) |state| {
            if (state.err == null) state.err = err;
            state.finished = true;
            _ = self.emitEvent(state, ResponseEvent.finished);
            if (state.awaiting) {
                self.event_loop.stop();
            }
        }
    }

    fn failAll(self: *QuicClient, err: ClientError) void {
        var it = self.requests.iterator();
        while (it.next()) |entry| {
            self.failFetch(entry.key_ptr.*, err);
        }
    }

    fn recordFailure(self: *QuicClient, err: ClientError) void {
        if (self.handshake_error == null) {
            self.handshake_error = err;
        }
        self.state = .closed;
        self.stopTimeoutTimer();
        self.stopConnectTimer();
        self.event_loop.stop();
        self.failAll(err);
    }

    fn requireConn(self: *QuicClient) ClientError!*quiche.Connection {
        if (self.conn) |*conn_ref| {
            return conn_ref;
        }
        return ClientError.NoConnection;
    }
};

fn onUdpReadable(fd: posix.socket_t, _revents: u32, user_data: *anyopaque) void {
    _ = _revents;
    const self: *QuicClient = @ptrCast(@alignCast(user_data));
    if (self.state == .closed) return;
    self.handleReadable(fd) catch |err| self.recordFailure(err);
}

fn onQuicTimeout(user_data: *anyopaque) void {
    const self: *QuicClient = @ptrCast(@alignCast(user_data));
    if (self.state == .closed) return;
    self.handleTimeout() catch |err| self.recordFailure(err);
}

fn onConnectTimeout(user_data: *anyopaque) void {
    const self: *QuicClient = @ptrCast(@alignCast(user_data));
    if (self.state == .connecting) {
        self.recordFailure(ClientError.HandshakeTimeout);
    }
}

fn resolvePreferredAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    if (std.net.Address.parseIp6(host, port)) |addr| {
        return addr;
    } else |_| {}

    if (std.net.Address.parseIp4(host, port)) |addr| {
        return addr;
    } else |_| {}

    var list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();

    var ipv4: ?std.net.Address = null;
    for (list.addrs) |addr| {
        switch (addr.any.family) {
            posix.AF.INET6 => return addr,
            posix.AF.INET => {
                if (ipv4 == null) ipv4 = addr;
            },
            else => {},
        }
    }

    if (ipv4) |addr| return addr;
    return error.NoUsableAddress;
}

const StorageWithLen = struct {
    storage: posix.sockaddr.storage,
    len: posix.socklen_t,
};

fn storageFromAddress(address: std.net.Address) StorageWithLen {
    var storage = std.mem.zeroes(posix.sockaddr.storage);
    const os_len = address.getOsSockLen();
    const src = @as([*]const u8, @ptrCast(&address.any))[0..os_len];
    const dst = @as([*]u8, @ptrCast(&storage))[0..os_len];
    @memcpy(dst, src);
    return .{ .storage = storage, .len = os_len };
}

fn openSocket(address: std.net.Address) ClientError!udp.UdpSocket {
    const base = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const fd = posix.socket(address.any.family, base, posix.IPPROTO.UDP) catch |err| switch (err) {
        error.AddressFamilyNotSupported, error.ProtocolFamilyNotAvailable => return ClientError.UnsupportedAddressFamily,
        error.ProtocolNotSupported, error.SocketTypeNotSupported => return ClientError.UnsupportedAddressFamily,
        else => return ClientError.SocketSetupFailed,
    };
    errdefer posix.close(fd);

    udp.setReuseAddr(fd, true) catch return ClientError.SocketSetupFailed;

    switch (address.any.family) {
        posix.AF.INET => {
            var bind_addr = std.mem.zeroes(posix.sockaddr.in);
            bind_addr.family = posix.AF.INET;
            bind_addr.port = 0;
            bind_addr.addr = 0;
            posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in)) catch return ClientError.SocketSetupFailed;
        },
        posix.AF.INET6 => {
            var bind_addr = std.mem.zeroes(posix.sockaddr.in6);
            bind_addr.family = posix.AF.INET6;
            bind_addr.port = 0;
            bind_addr.addr = std.mem.zeroes([16]u8);
            bind_addr.flowinfo = 0;
            bind_addr.scope_id = 0;
            udp.setIpv6Only(fd, false);
            posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in6)) catch return ClientError.SocketSetupFailed;
        },
        else => return ClientError.UnsupportedAddressFamily,
    }

    return udp.UdpSocket{ .fd = fd };
}

const ServerThreadCtx = struct {
    server: *QuicServer,
    err: ?anyerror = null,
};

fn serverThreadMain(ctx: *ServerThreadCtx) void {
    ctx.server.run() catch |err| {
        ctx.err = err;
    };
}

fn chooseTestPort() u16 {
    return 45443;
}

test "quic client handshake and fetch against local server" {
    const allocator = std.testing.allocator;

    const server_cfg = ServerConfig{
        .bind_addr = "127.0.0.1",
        .bind_port = chooseTestPort(),
        .cert_path = "third_party/quiche/quiche/examples/cert.crt",
        .key_path = "third_party/quiche/quiche/examples/cert.key",
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .qlog_dir = null,
    };

    const RouterT = routing_gen.compileMatcherType(&.{});
    var router = RouterT{};
    const matcher: routing_api.Matcher = router.matcher();

    var server = try QuicServer.init(allocator, server_cfg, matcher);
    defer server.deinit();

    try server.bind();

    var ctx = ServerThreadCtx{ .server = server, .err = null };
    const thread = try std.Thread.spawn(.{}, serverThreadMain, .{&ctx});
    errdefer {
        server.stop();
        thread.join();
    }

    std.time.sleep(50 * std.time.ns_per_ms) catch {};

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = false,
        .qlog_dir = null,
        .enable_debug_logging = false,
        .connect_timeout_ms = 5_000,
    };

    var client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    const endpoint = ServerEndpoint{
        .host = "127.0.0.1",
        .port = server_cfg.bind_port,
    };

    try client.connect(endpoint);
    try std.testing.expect(client.isEstablished());

    var response = try client.fetch(allocator, "/");
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, "Welcome to Zig QUIC/HTTP3 Server!", 1));
    try std.testing.expect(response.headers.len > 0);

    server.stop();
    thread.join();
    if (ctx.err) |err| {
        std.debug.print("server thread error: {}\n", .{err});
        try std.testing.expect(false);
    }
}

test "quic client concurrent fetches" {
    const allocator = std.testing.allocator;

    const server_cfg = ServerConfig{
        .bind_addr = "127.0.0.1",
        .bind_port = chooseTestPort() + 1,
        .cert_path = "third_party/quiche/quiche/examples/cert.crt",
        .key_path = "third_party/quiche/quiche/examples/cert.key",
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .qlog_dir = null,
    };

    const RouterT = routing_gen.compileMatcherType(&.{});
    var router = RouterT{};
    const matcher: routing_api.Matcher = router.matcher();

    var server = try QuicServer.init(allocator, server_cfg, matcher);
    defer server.deinit();

    try server.bind();

    var ctx = ServerThreadCtx{ .server = server, .err = null };
    const thread = try std.Thread.spawn(.{}, serverThreadMain, .{&ctx});
    errdefer {
        server.stop();
        thread.join();
    }

    std.time.sleep(50 * std.time.ns_per_ms) catch {};

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = false,
        .qlog_dir = null,
        .enable_debug_logging = false,
        .connect_timeout_ms = 5_000,
    };

    var client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    const endpoint = ServerEndpoint{
        .host = "127.0.0.1",
        .port = server_cfg.bind_port,
    };

    try client.connect(endpoint);
    try std.testing.expect(client.isEstablished());

    const handle_a = try client.startGet(allocator, "/");
    const handle_b = try client.startGet(allocator, "/api/users");

    var resp_b = try handle_b.await();
    defer resp_b.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp_b.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, resp_b.body, "Alice", 1));
    try std.testing.expect(resp_b.headers.len > 0);

    var resp_a = try handle_a.await();
    defer resp_a.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp_a.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, resp_a.body, "Welcome to Zig QUIC/HTTP3 Server!", 1));
    try std.testing.expect(resp_a.headers.len > 0);

    server.stop();
    thread.join();
    if (ctx.err) |err| {
        std.debug.print("server thread error: {}\n", .{err});
        try std.testing.expect(false);
    }
}

test "quic client post body and stream response" {
    const allocator = std.testing.allocator;

    const server_cfg = ServerConfig{
        .bind_addr = "127.0.0.1",
        .bind_port = chooseTestPort() + 2,
        .cert_path = "third_party/quiche/quiche/examples/cert.crt",
        .key_path = "third_party/quiche/quiche/examples/cert.key",
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .qlog_dir = null,
    };

    const RouterT = routing_gen.compileMatcherType(&.{});
    var router = RouterT{};
    const matcher: routing_api.Matcher = router.matcher();

    var server = try QuicServer.init(allocator, server_cfg, matcher);
    defer server.deinit();

    try server.bind();

    var ctx = ServerThreadCtx{ .server = server, .err = null };
    const thread = try std.Thread.spawn(.{}, serverThreadMain, .{&ctx});
    errdefer {
        server.stop();
        thread.join();
    }

    std.time.sleep(50 * std.time.ns_per_ms) catch {};

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = false,
        .qlog_dir = null,
        .enable_debug_logging = false,
        .connect_timeout_ms = 5_000,
    };

    var client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    const endpoint = ServerEndpoint{
        .host = "127.0.0.1",
        .port = server_cfg.bind_port,
    };

    try client.connect(endpoint);
    try std.testing.expect(client.isEstablished());

    const post_body = "{\"hello\":\"world\"}";
    var post_resp = try client.fetchWithOptions(allocator, .{
        .method = "POST",
        .path = "/api/echo",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = post_body,
    });
    defer post_resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), post_resp.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, post_resp.body, "world", 1));
    try std.testing.expect(post_resp.headers.len > 0);

    const BodyStream = struct {
        chunks: []const []const u8,
        index: usize = 0,

        fn next(provider_ctx: ?*anyopaque, prov_allocator: std.mem.Allocator) ClientError!BodyChunkResult {
            const self: *@This() = @ptrCast(@alignCast(provider_ctx.?));
            if (self.index >= self.chunks.len) return BodyChunkResult.finished;
            const src = self.chunks[self.index];
            self.index += 1;
            const dup = try prov_allocator.dupe(u8, src);
            return BodyChunkResult.chunk(dup);
        }
    };

    var body_stream = BodyStream{ .chunks = &.{ "{", "\"hello\":\"stream\"", "}" } };
    var streamed_post = try client.fetchWithOptions(allocator, .{
        .method = "POST",
        .path = "/api/echo",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body_provider = .{ .ctx = &body_stream, .next = BodyStream.next },
    });
    defer streamed_post.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), streamed_post.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, streamed_post.body, "stream", 1));
    try std.testing.expect(streamed_post.headers.len > 0);

    const StreamAccum = struct {
        total: usize = 0,
        checksum: u64 = 0,

        fn onChunk(event: ResponseEvent, user_ctx: ?*anyopaque) ClientError!void {
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            switch (event) {
                .data => |slice| {
                    self.total += slice.len;
                    for (slice) |byte| self.checksum += byte;
                },
                else => {},
            }
        }
    };

    var accum = StreamAccum{};
    const handle_stream = try client.startRequest(allocator, .{
        .path = "/stream/test",
        .on_event = StreamAccum.onChunk,
        .event_ctx = &accum,
    });
    var stream_resp = try handle_stream.await();
    defer stream_resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), stream_resp.status);
    try std.testing.expectEqual(@as(usize, 0), stream_resp.body.len);
    try std.testing.expect(stream_resp.headers.len >= 1);

    const total_bytes: usize = 10 * 1024 * 1024;
    const cycles: u64 = @intCast(total_bytes / 256);
    const per_cycle: u64 = 32640; // sum(0..255)
    const expected_checksum: u64 = cycles * per_cycle;

    try std.testing.expectEqual(total_bytes, accum.total);
    try std.testing.expectEqual(expected_checksum, accum.checksum);

    server.stop();
    thread.join();
    if (ctx.err) |err| {
        std.debug.print("server thread error: {}\n", .{err});
        try std.testing.expect(false);
    }
}

test "client CA bundle configuration - valid path" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = true,
        .ca_bundle_path = "third_party/quiche/quiche/examples/cert.crt",
        .enable_debug_logging = false,
    };

    const client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    // Should initialize without error
    try std.testing.expect(client.log_context == null); // No logging context since disabled
}

test "client CA bundle configuration - invalid path" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = true,
        .ca_bundle_path = "/nonexistent/ca.pem",
        .enable_debug_logging = false,
    };

    const result = QuicClient.init(allocator, client_config);
    try std.testing.expectError(error.LoadCABundleFailed, result);
}

test "client debug logging initialization" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = false,
        .enable_debug_logging = true,
        .debug_log_throttle = 10,
    };

    const client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    // Should have logging context
    try std.testing.expect(client.log_context != null);
    try std.testing.expectEqual(@as(u32, 10), client.log_context.?.debug_log_throttle);
}

test "client CA directory configuration" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = true,
        .ca_bundle_dir = "third_party/quiche/quiche/examples", // Directory containing cert.crt
        .enable_debug_logging = false,
    };

    const client = try QuicClient.init(allocator, client_config);
    defer client.deinit();
}

test "client with both CA and debug logging" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = true,
        .ca_bundle_path = "third_party/quiche/quiche/examples/cert.crt",
        .enable_debug_logging = true,
        .debug_log_throttle = 5,
    };

    const client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    // Should have both features enabled
    try std.testing.expect(client.log_context != null);
    try std.testing.expectEqual(@as(u32, 5), client.log_context.?.debug_log_throttle);
}
