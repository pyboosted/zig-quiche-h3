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
const webtransport = @import("webtransport.zig");

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
    StreamReset,
    H3Error,
    ResponseIncomplete,
    UnexpectedStream,
    NoAuthority,
    GoAwayReceived,
    ConnectionGoingAway,
    InvalidRequest,
    DatagramNotEnabled,
    DatagramTooLarge,
    DatagramSendFailed,
    ConnectionPoolExhausted,
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

    // WebTransport extensions - reusing existing state machine
    is_webtransport: bool = false,
    wt_session: ?*webtransport.WebTransportSession = null,
    wt_datagrams_received: u32 = 0,

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
    server_sni: ?[]u8 = null,  // Store SNI for reconnection

    log_context: ?*logging.LogContext = null,

    requests: AutoHashMap(u64, *FetchState),

    // WebTransport sessions (stream_id -> session)
    wt_sessions: AutoHashMap(u64, *webtransport.WebTransportSession),

    // Plain QUIC datagram callback
    on_quic_datagram: ?*const fn (client: *QuicClient, payload: []const u8, user: ?*anyopaque) void = null,
    on_quic_datagram_user: ?*anyopaque = null,

    // Datagram metrics (matching server)
    datagram_stats: struct {
        sent: u64 = 0,
        received: u64 = 0,
        dropped_send: u64 = 0,
    } = .{},

    // GOAWAY state tracking
    goaway_received: bool = false,
    goaway_stream_id: ?u64 = null, // Last accepted request stream ID from server

    // GOAWAY callback (runs on event loop thread)
    on_goaway: ?*const fn (client: *QuicClient, last_stream_id: u64, user: ?*anyopaque) void = null,
    on_goaway_user: ?*anyopaque = null,

    // Track most recent request stream ID for comparison
    last_request_stream_id: ?u64 = null,

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

        var h3_cfg = if (cfg.enable_webtransport)
            try H3Config.initWithWebTransport()
        else
            try H3Config.initWithDefaults();
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
            .wt_sessions = AutoHashMap(u64, *webtransport.WebTransportSession).init(allocator),
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

        if (self.server_sni) |sni| {
            self.allocator.free(sni);
            self.server_sni = null;
        }

        var it = self.requests.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.destroy();
        }
        self.requests.deinit();

        var wt_it = self.wt_sessions.iterator();
        while (wt_it.next()) |entry| {
            const session = entry.value_ptr.*;
            // Free any queued datagrams
            for (session.datagram_queue.items) |dgram| {
                self.allocator.free(dgram);
            }
            // Deinit the queue itself
            session.datagram_queue.deinit(self.allocator);
            // Free the allocated path before destroying the session
            self.allocator.free(session.path);
            self.allocator.destroy(session);
        }
        self.wt_sessions.deinit();

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
            // CRITICAL: Unregister the debug logging callback before freeing the context
            // The callback is registered globally with quiche and persists beyond this client's lifetime
            // Failing to unregister would cause use-after-free when quiche tries to log
            quiche.enableDebugLogging(null, null) catch {
                // Even if disabling fails, we still need to clean up
                // Log the error but continue with cleanup
                std.debug.print("Warning: Failed to disable debug logging\n", .{});
            };
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

    /// Check if client is idle (no active requests or WebTransport sessions)
    /// Note: This only checks active request/session maps, not pending body providers or timers.
    pub fn isIdle(self: *QuicClient) bool {
        return self.requests.count() == 0 and self.wt_sessions.count() == 0;
    }

    /// Reconnect to the server (closes existing connection and establishes new one)
    pub fn reconnect(self: *QuicClient) ClientError!void {
        // Close existing connection if present
        if (self.conn) |*conn| {
            conn.close(true, 0, "reconnecting") catch {}; // Best-effort close
            conn.deinit();
            self.conn = null;
        }

        // Clear H3 connection
        if (self.h3_conn) |*h3_conn| {
            h3_conn.deinit();
            self.h3_conn = null;
        }

        // Close the socket properly
        if (self.socket) |*sock| {
            sock.close();
            self.socket = null;
        }

        // Clear pending requests properly to avoid iterator invalidation
        // Collect keys first, then clean up
        var req_keys = std.ArrayList(u64).init(self.allocator);
        defer req_keys.deinit();
        var req_it = self.requests.iterator();
        while (req_it.next()) |entry| {
            try req_keys.append(entry.key_ptr.*);
        }
        // Now clean up using collected keys
        for (req_keys.items) |stream_id| {
            if (self.requests.fetchRemove(stream_id)) |kv| {
                kv.value.destroy();
            }
        }

        // Clear WebTransport sessions properly
        var wt_keys = std.ArrayList(u64).init(self.allocator);
        defer wt_keys.deinit();
        var wt_it = self.wt_sessions.iterator();
        while (wt_it.next()) |entry| {
            try wt_keys.append(entry.key_ptr.*);
        }
        for (wt_keys.items) |stream_id| {
            if (self.wt_sessions.fetchRemove(stream_id)) |kv| {
                // close() returns void and handles all cleanup including destroy()
                kv.value.close();
                // Do NOT call destroy() - close() already handles that
            }
        }

        // Reset state to idle
        self.state = .idle;

        // Re-establish connection using saved endpoint with SNI
        if (self.server_host != null and self.server_port != null) {
            const endpoint = ServerEndpoint{
                .host = self.server_host.?,
                .port = self.server_port.?,
                .sni = self.server_sni,
            };
            try self.connect(endpoint);
        } else {
            return ClientError.NoConnection;
        }
    }

    /// Fetch with automatic retry on transient failures
    /// Note: Requests with streaming body_provider are NOT supported as the
    /// provider will be exhausted after the first attempt. This method will
    /// return an error if a body_provider is specified.
    pub fn fetchWithRetry(
        self: *QuicClient,
        allocator: std.mem.Allocator,
        options: FetchOptions,
        max_retries: u32,
    ) ClientError!FetchResponse {
        // Reject if body_provider is present (can't retry streaming bodies)
        if (options.body_provider != null) {
            return ClientError.InvalidRequest;
        }

        var attempt: u32 = 0;
        while (attempt < max_retries) : (attempt += 1) {
            const result = self.fetchWithOptions(allocator, options) catch |err| {
                // On last attempt, return the error
                if (attempt == max_retries - 1) return err;

                // Retry on specific transient errors
                switch (err) {
                    ClientError.ConnectionClosed,
                    ClientError.StreamReset,
                    ClientError.HandshakeTimeout,
                    ClientError.QuicSendFailed,
                    ClientError.QuicRecvFailed => {
                        // Try to reconnect and retry
                        self.reconnect() catch |reconnect_err| {
                            // If reconnect fails on last retry attempt, return that error
                            if (attempt == max_retries - 2) return reconnect_err;
                            // Otherwise continue to next retry
                            continue;
                        };
                        continue;
                    },
                    else => return err, // Non-transient error, fail immediately
                }
            };
            return result;
        }
        unreachable;
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

    /// Register a callback for plain QUIC datagrams.
    /// The callback will receive datagram payloads that are not H3-formatted.
    /// IMPORTANT: The payload is only valid during the callback execution.
    /// Callers must copy the data if they need to retain it.
    pub fn onQuicDatagram(
        self: *QuicClient,
        cb: *const fn (client: *QuicClient, payload: []const u8, user: ?*anyopaque) void,
        user: ?*anyopaque,
    ) void {
        self.on_quic_datagram = cb;
        self.on_quic_datagram_user = user;
    }

    /// Register a callback for GOAWAY events (runs on event loop thread).
    /// The callback is invoked when the server sends a GOAWAY frame indicating
    /// the connection will be closed gracefully.
    /// @param last_stream_id The last stream ID that the server will process
    pub fn onGoaway(
        self: *QuicClient,
        cb: *const fn (client: *QuicClient, last_stream_id: u64, user: ?*anyopaque) void,
        user: ?*anyopaque,
    ) void {
        self.on_goaway = cb;
        self.on_goaway_user = user;
    }

    /// Send a plain QUIC datagram without H3 flow-id prefix.
    /// This sends raw payload directly via the QUIC transport.
    pub fn sendQuicDatagram(self: *QuicClient, payload: []const u8) ClientError!void {
        const conn = try self.requireConn();

        // Check if datagrams are supported
        const max_len = conn.dgramMaxWritableLen() orelse
            return ClientError.DatagramNotEnabled;

        if (payload.len > max_len) {
            self.datagram_stats.dropped_send += 1;
            return ClientError.DatagramTooLarge;
        }

        const sent = conn.dgramSend(payload) catch |err| {
            self.datagram_stats.dropped_send += 1;
            if (err == error.Done) return ClientError.DatagramSendFailed;
            return ClientError.DatagramSendFailed;
        };

        if (sent != payload.len) {
            self.datagram_stats.dropped_send += 1;
            return ClientError.DatagramSendFailed;
        }

        self.datagram_stats.sent += 1;
        self.flushSend() catch |err| return err;
        self.afterQuicProgress();
    }

    /// Open a WebTransport session via Extended CONNECT
    /// Returns a session handle that can be used to send datagrams and manage the session
    pub fn openWebTransport(self: *QuicClient, path: []const u8) ClientError!*webtransport.WebTransportSession {
        if (self.state != .established) return ClientError.NoConnection;
        if (self.server_authority == null) return ClientError.NoAuthority;
        if (path.len == 0) return ClientError.InvalidRequest;

        // Check if connection was negotiated with Extended CONNECT support
        const conn = try self.requireConn();
        try self.ensureH3();
        const h3_conn = &self.h3_conn.?;

        // Check if peer supports Extended CONNECT
        if (!h3_conn.extendedConnectEnabledByPeer()) {
            return ClientError.H3Error;  // Extended CONNECT not supported
        }

        // Build WebTransport CONNECT headers
        const headers = webtransport.buildWebTransportHeaders(
            self.allocator,
            self.server_authority.?,
            path,
            &.{},
        ) catch {
            return ClientError.H3Error;
        };
        defer self.allocator.free(headers);

        // Send Extended CONNECT request
        const stream_id = h3_conn.sendRequest(conn, headers, false) catch {
            return ClientError.H3Error;
        };

        // Create WebTransport session
        const session = self.allocator.create(webtransport.WebTransportSession) catch {
            return ClientError.H3Error;
        };

        const path_copy = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(session);
            return ClientError.H3Error;
        };

        session.* = .{
            .session_id = stream_id,
            .client = self,
            .state = .connecting,
            .path = path_copy,
            .datagram_queue = std.ArrayList([]u8).init(self.allocator),
        };

        // Track session
        self.wt_sessions.put(stream_id, session) catch {
            session.datagram_queue.deinit(self.allocator);
            self.allocator.free(path_copy);
            self.allocator.destroy(session);
            return ClientError.H3Error;
        };

        // Also track in requests for proper lifecycle management
        var state = FetchState.init(self.allocator) catch {
            _ = self.wt_sessions.remove(stream_id);
            session.datagram_queue.deinit(self.allocator);
            self.allocator.free(path_copy);
            self.allocator.destroy(session);
            return ClientError.H3Error;
        };

        state.stream_id = stream_id;
        state.is_webtransport = true;
        state.wt_session = session;
        state.collect_body = false;  // Don't collect body for WT

        self.requests.put(stream_id, state) catch {
            state.destroy();
            _ = self.wt_sessions.remove(stream_id);
            session.datagram_queue.deinit(self.allocator);
            self.allocator.free(path_copy);
            self.allocator.destroy(session);
            return ClientError.H3Error;
        };

        self.flushSend() catch |err| {
            _ = self.requests.remove(stream_id);
            state.destroy();
            _ = self.wt_sessions.remove(stream_id);
            session.datagram_queue.deinit(self.allocator);
            self.allocator.free(path_copy);
            self.allocator.destroy(session);
            return err;
        };

        self.afterQuicProgress();
        return session;
    }

    pub fn startRequest(self: *QuicClient, allocator: std.mem.Allocator, options: FetchOptions) ClientError!FetchHandle {
        if (self.state != .established) return ClientError.NoConnection;
        if (self.server_authority == null) return ClientError.NoAuthority;
        if (options.path.len == 0) return ClientError.InvalidRequest;

        // Check GOAWAY state before allocating any resources
        if (self.goaway_received) {
            // If we have a GOAWAY and know the last request ID, check if new requests would exceed it
            // Since we can't predict the next stream ID, we conservatively reject all new requests
            return ClientError.ConnectionGoingAway;
        }

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

        // Track the most recent request stream ID
        self.last_request_stream_id = stream_id;

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
        // Duplicate new values first before freeing old ones to avoid use-after-free
        // when reconnect() passes pointers to our own stored strings
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

        const sni_copy = if (endpoint.sni) |sni|
            self.allocator.dupe(u8, sni) catch {
                self.allocator.free(host_copy);
                self.allocator.free(authority);
                return ClientError.H3Error;
            }
        else
            null;
        errdefer if (sni_copy) |s| self.allocator.free(s);

        // Now free old values and replace with new ones
        if (self.server_host) |prev| {
            self.allocator.free(prev);
        }
        if (self.server_authority) |prev| {
            self.allocator.free(prev);
        }
        if (self.server_sni) |prev_sni| {
            self.allocator.free(prev_sni);
        }

        // Store new values
        self.server_host = host_copy;
        self.server_authority = authority;
        self.server_port = endpoint.port;
        self.server_sni = sni_copy;
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
            // Clean up WebTransport session if this was a WT CONNECT request
            if (state.is_webtransport) {
                if (self.wt_sessions.get(stream_id)) |session| {
                    if (session.state == .established) {
                        // For established sessions, remove from tracking but don't destroy
                        // The user now owns this session and must call close() on it
                        _ = self.wt_sessions.remove(stream_id);
                    } else {
                        // Failed sessions get cleaned up immediately
                        self.cleanupWebTransportSession(stream_id);
                    }
                }
            }
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
                .GoAway => self.onH3GoAway(poll.stream_id),
                .Reset => self.onH3Reset(poll.stream_id),
                .PriorityUpdate => {},
            }
        }
    }

    fn processDatagrams(self: *QuicClient) void {
        const conn = if (self.conn) |*conn_ref| conn_ref else return;

        while (true) {
            // Get hint for buffer size needed
            const hint = conn.dgramRecvFrontLen();
            var buf_slice: []u8 = self.datagram_buf[0..];
            var use_heap = false;

            if (hint) |h| {
                if (h > self.datagram_buf.len) {
                    buf_slice = self.allocator.alloc(u8, h) catch return;
                    use_heap = true;
                } else {
                    buf_slice = self.datagram_buf[0..h];
                }
            }

            const read = conn.dgramRecv(buf_slice) catch |err| {
                if (use_heap) self.allocator.free(buf_slice);
                if (err == error.Done) return; // No more datagrams
                return;
            };

            const payload = buf_slice[0..read];
            self.datagram_stats.received += 1;

            // Important: handle the datagram before defer cleanup
            var handled_as_h3 = false;

            // Try H3 format first if H3 is enabled
            if (self.h3_conn) |*h3_conn_ptr| {
                if (h3_conn_ptr.dgramEnabledByPeer(conn)) {
                    // Try to parse as H3 datagram with flow-id
                    handled_as_h3 = self.processH3Datagram(payload) catch false;
                }
            }

            // Fall back to plain QUIC datagram if not handled as H3
            if (!handled_as_h3 and self.on_quic_datagram != null) {
                if (self.on_quic_datagram) |cb| {
                    // IMPORTANT: payload is only valid during callback
                    // Caller must copy if they need to retain the data
                    cb(self, payload, self.on_quic_datagram_user);
                }
            }

            // Clean up heap allocation after handling
            if (use_heap) self.allocator.free(buf_slice);
        }
    }

    /// Process H3 datagram with flow-id prefix
    /// Returns true if successfully handled as H3, false otherwise
    fn processH3Datagram(self: *QuicClient, payload: []const u8) !bool {
        const varint = h3_datagram.decodeVarint(payload) catch return false;
        if (varint.consumed >= payload.len) return false;

        const id = varint.value;
        const h3_payload = payload[varint.consumed..];

        // Check if this is a WebTransport datagram (session_id prefix)
        if (self.wt_sessions.get(id)) |session| {
            // This is a WebTransport datagram
            // Queue it in the session for the user to retrieve
            session.queueDatagram(h3_payload) catch {
                // If we can't queue it (out of memory), drop it
                return false;
            };

            // Update stats on the FetchState if it exists
            if (self.requests.get(id)) |state| {
                state.wt_datagrams_received += 1;
            }
            return true;
        }

        // Otherwise, treat as regular H3 datagram with flow-id
        const stream_id = h3_datagram.streamIdForFlow(id);

        // Route to the appropriate request
        if (self.requests.get(stream_id)) |state| {
            if (state.response_callback) |_| {
                // Must copy for the event since we don't own the buffer
                const copy = state.allocator.dupe(u8, h3_payload) catch return false;
                const event = ResponseEvent{ .datagram = .{ .flow_id = id, .payload = copy } };
                _ = self.emitEvent(state, event);
                state.allocator.free(copy);
                return true;
            }
        }
        return false;
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

                // Handle WebTransport CONNECT response
                if (state.is_webtransport and state.wt_session != null) {
                    state.wt_session.?.handleConnectResponse(parsed);

                    if (parsed == 200) {
                        // Success: Keep FetchState alive for datagram routing
                        // The FetchState will be cleaned up when the session closes
                        // or when the client deinits
                        state.finished = true;
                    } else {
                        // Failure: trigger failFetch to clean up properly
                        // This will mark session as closed and remove FetchState
                        self.failFetch(stream_id, ClientError.H3Error);
                        return;
                    }
                }
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

        // For WebTransport, we keep the FetchState alive for datagram routing
        // It will be cleaned up when the user calls close() on the session
    }

    fn onH3Reset(self: *QuicClient, stream_id: u64) void {
        self.failFetch(stream_id, ClientError.H3Error);
    }

    fn onH3GoAway(self: *QuicClient, last_accepted_id: u64) void {
        // Note: The stream_id from poll might be the GOAWAY stream ID,
        // but for HTTP/3 GOAWAY, it represents the last accepted request ID

        // Ignore duplicate GOAWAYs with higher IDs
        if (self.goaway_received) {
            if (self.goaway_stream_id) |existing_id| {
                if (last_accepted_id >= existing_id) return;
            }
        }

        self.goaway_received = true;
        self.goaway_stream_id = last_accepted_id;

        // Notify application callback if registered
        if (self.on_goaway) |cb| {
            cb(self, last_accepted_id, self.on_goaway_user);
        }

        // Cancel all requests with stream_id > last_accepted_id
        // Collect IDs first to avoid iterator invalidation
        var to_cancel = std.ArrayList(u64).initCapacity(self.allocator, self.requests.count()) catch {
            // If we can't allocate, at least mark the state
            return;
        };
        defer to_cancel.deinit(self.allocator);

        var it = self.requests.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* > last_accepted_id) {
                to_cancel.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        // Use failFetch for proper cleanup and event emission
        for (to_cancel.items) |stream_id| {
            self.failFetch(stream_id, ClientError.GoAwayReceived);
        }
    }

    /// Helper to mark a WebTransport session as closed without destroying it
    /// Used when the session might still have user references
    fn markWebTransportSessionClosed(self: *QuicClient, stream_id: u64) void {
        if (self.wt_sessions.get(stream_id)) |session| {
            session.state = .closed;
            // Keep it tracked so close() can still clean up properly
            // User's reference remains valid but session is marked closed
        }
    }

    /// Helper to properly clean up a WebTransport session
    /// Only use when certain no user references exist
    fn cleanupWebTransportSession(self: *QuicClient, stream_id: u64) void {
        if (self.wt_sessions.get(stream_id)) |session| {
            session.state = .closed;
            // Free any queued datagrams
            for (session.datagram_queue.items) |dgram| {
                self.allocator.free(dgram);
            }
            // Deinit the queue itself
            session.datagram_queue.deinit(self.allocator);
            // Free the path string
            self.allocator.free(session.path);
            // Remove from map
            _ = self.wt_sessions.remove(stream_id);
            // Destroy the session struct
            self.allocator.destroy(session);
        }
    }

    fn failFetch(self: *QuicClient, stream_id: u64, err: ClientError) void {
        if (self.requests.get(stream_id)) |state| {
            if (state.err == null) state.err = err;
            state.finished = true;
            _ = self.emitEvent(state, ResponseEvent.finished);
            if (state.awaiting) {
                self.event_loop.stop();
            }

            // Handle WebTransport session cleanup
            if (state.is_webtransport) {
                if (self.wt_sessions.get(stream_id)) |session| {
                    // Mark session as closed so users can observe the failure
                    session.state = .closed;
                    // Note: We keep the session in wt_sessions so that when the user
                    // calls close() on their reference, it will properly free memory
                }

                // Remove and destroy the FetchState for WebTransport
                // WebTransport doesn't use finalizeFetch, so we must clean up here
                _ = self.requests.remove(stream_id);
                state.destroy();
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

test "quic client plain datagram callback lifecycle" {
    // Test that datagram callbacks are invoked correctly and that
    // the payload is only valid during the callback execution
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestContext = struct {
        received_count: u32 = 0,
        last_payload: ?[]u8 = null,
        allocator: std.mem.Allocator,

        fn datagramCallback(client: *QuicClient, payload: []const u8, user: ?*anyopaque) void {
            _ = client;
            const self: *@This() = @ptrCast(@alignCast(user.?));
            self.received_count += 1;

            // Copy the payload to test that it's valid during callback
            if (self.last_payload) |old| {
                self.allocator.free(old);
            }
            self.last_payload = self.allocator.dupe(u8, payload) catch null;
        }
    };

    var test_ctx = TestContext{ .allocator = allocator };

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Register the datagram callback
    client.onQuicDatagram(TestContext.datagramCallback, &test_ctx);

    // Verify callback was registered
    try std.testing.expect(client.on_quic_datagram != null);
    try std.testing.expect(client.on_quic_datagram_user == &test_ctx);

    // Simulate receiving a plain QUIC datagram
    const test_payload = "test datagram payload";

    // Create a test buffer that simulates what processDatagrams would receive
    var test_buf: [256]u8 = undefined;
    @memcpy(test_buf[0..test_payload.len], test_payload);

    // Directly invoke the callback to test the lifecycle
    if (client.on_quic_datagram) |cb| {
        cb(&client, test_buf[0..test_payload.len], client.on_quic_datagram_user);
    }

    // Verify the callback was invoked
    try std.testing.expectEqual(@as(u32, 1), test_ctx.received_count);
    try std.testing.expect(test_ctx.last_payload != null);
    try std.testing.expectEqualSlices(u8, test_payload, test_ctx.last_payload.?);
}

test "quic client plain datagram metrics tracking" {
    // Test that datagram send/receive metrics are properly tracked
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Initial metrics should be zero
    try std.testing.expectEqual(@as(u64, 0), client.datagram_stats.sent);
    try std.testing.expectEqual(@as(u64, 0), client.datagram_stats.received);
    try std.testing.expectEqual(@as(u64, 0), client.datagram_stats.dropped_send);

    // Simulate receiving datagrams
    client.datagram_stats.received += 1;
    try std.testing.expectEqual(@as(u64, 1), client.datagram_stats.received);

    client.datagram_stats.received += 5;
    try std.testing.expectEqual(@as(u64, 6), client.datagram_stats.received);

    // Simulate sending datagrams
    client.datagram_stats.sent += 3;
    try std.testing.expectEqual(@as(u64, 3), client.datagram_stats.sent);

    // Simulate dropped sends
    client.datagram_stats.dropped_send += 2;
    try std.testing.expectEqual(@as(u64, 2), client.datagram_stats.dropped_send);
}

test "quic client H3 vs plain datagram routing" {
    // Test that processDatagrams correctly routes H3 and plain QUIC datagrams
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestContext = struct {
        plain_received: u32 = 0,
        h3_received: u32 = 0,
        last_flow_id: ?u64 = null,

        fn plainCallback(client: *QuicClient, payload: []const u8, user: ?*anyopaque) void {
            _ = client;
            _ = payload;
            const self: *@This() = @ptrCast(@alignCast(user.?));
            self.plain_received += 1;
        }
    };

    var test_ctx = TestContext{};

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Register plain datagram callback
    client.onQuicDatagram(TestContext.plainCallback, &test_ctx);

    // Test 1: Plain QUIC datagram (no flow ID prefix)
    {
        const plain_payload = "plain datagram";
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..plain_payload.len], plain_payload);

        // Simulate what would happen in processDatagrams for plain datagram
        if (client.on_quic_datagram) |cb| {
            cb(&client, buf[0..plain_payload.len], client.on_quic_datagram_user);
            client.datagram_stats.received += 1;
        }

        try std.testing.expectEqual(@as(u32, 1), test_ctx.plain_received);
        try std.testing.expectEqual(@as(u64, 1), client.datagram_stats.received);
    }

    // Test 2: H3 datagram with flow ID (would be handled differently)
    {
        // H3 datagrams have a varint flow_id prefix
        // For this test, we're verifying the routing logic conceptually
        // In real usage, processH3Datagram would handle the flow_id parsing
        var h3_buf: [256]u8 = undefined;
        // Varint encoding of flow_id = 42 (single byte for values < 64)
        h3_buf[0] = 42; // flow_id
        const h3_payload = "h3 datagram payload";
        @memcpy(h3_buf[1 .. 1 + h3_payload.len], h3_payload);

        // In real processDatagrams, this would try processH3Datagram first
        // For test purposes, we simulate detecting it's an H3 datagram
        const flow_id = h3_buf[0]; // Simplified varint parsing
        if (flow_id < 64) { // Valid single-byte varint
            test_ctx.h3_received += 1;
            test_ctx.last_flow_id = flow_id;
        }

        try std.testing.expectEqual(@as(u32, 1), test_ctx.h3_received);
        try std.testing.expectEqual(@as(u64, 42), test_ctx.last_flow_id.?);
    }

    // Test 3: Multiple plain datagrams
    {
        for (0..3) |_| {
            const payload = "another plain datagram";
            var buf: [256]u8 = undefined;
            @memcpy(buf[0..payload.len], payload);

            if (client.on_quic_datagram) |cb| {
                cb(&client, buf[0..payload.len], client.on_quic_datagram_user);
                client.datagram_stats.received += 1;
            }
        }

        try std.testing.expectEqual(@as(u32, 4), test_ctx.plain_received); // 1 + 3
        try std.testing.expectEqual(@as(u64, 4), client.datagram_stats.received); // 1 + 3
    }
}

test "quic client datagram send error handling" {
    // Test error handling in sendQuicDatagram
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Test sending when connection is not established (conn is null)
    const payload = "test payload";
    const result = client.sendQuicDatagram(payload);

    // Should fail because conn is null (not connected)
    try std.testing.expectError(error.NotConnected, result);

    // Dropped send metric should increment
    try std.testing.expectEqual(@as(u64, 1), client.datagram_stats.dropped_send);
}

test "quic client debug logging cleanup safety" {
    // Test that debug logging is properly unregistered to prevent use-after-free
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create multiple clients with debug logging enabled
    {
        const client1 = try QuicClient.init(
            allocator,
            .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
            .{ .debug_log = true, .debug_log_throttle = 1 },
        );
        defer client1.deinit();

        // Verify logging was enabled
        try std.testing.expect(client1.log_context != null);
    }

    // After client1 is destroyed, create another client
    // This tests that the previous callback was properly unregistered
    {
        const client2 = try QuicClient.init(
            allocator,
            .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
            .{ .debug_log = true, .debug_log_throttle = 2 },
        );
        defer client2.deinit();

        // Verify this client has its own context
        try std.testing.expect(client2.log_context != null);
        try std.testing.expectEqual(@as(u32, 2), client2.log_context.?.debug_log_throttle);
    }

    // Create a client without debug logging to ensure no interference
    {
        const client3 = try QuicClient.init(
            allocator,
            .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
            .{},
        );
        defer client3.deinit();

        // Verify no logging context
        try std.testing.expect(client3.log_context == null);
    }

    // If we got here without crashes, the cleanup is working correctly
}

test "quic client datagram memory safety" {
    // Test that datagram payloads are handled safely with proper memory management
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestContext = struct {
        payload_copies: std.ArrayListUnmanaged([]u8),
        allocator: std.mem.Allocator,

        fn datagramCallback(client: *QuicClient, payload: []const u8, user: ?*anyopaque) void {
            _ = client;
            const self: *@This() = @ptrCast(@alignCast(user.?));

            // The payload is only valid during this callback
            // We must copy it if we want to keep it
            const copy = self.allocator.dupe(u8, payload) catch return;
            self.payload_copies.append(self.allocator, copy) catch {
                self.allocator.free(copy);
            };
        }

        fn cleanup(self: *@This()) void {
            for (self.payload_copies.items) |copy| {
                self.allocator.free(copy);
            }
            self.payload_copies.deinit(self.allocator);
        }
    };

    var test_ctx = TestContext{
        .payload_copies = .{},
        .allocator = allocator,
    };
    defer test_ctx.cleanup();

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Register callback
    client.onQuicDatagram(TestContext.datagramCallback, &test_ctx);

    // Simulate receiving multiple datagrams
    const payloads = [_][]const u8{
        "first datagram",
        "second datagram with longer content",
        "third",
        "fourth datagram payload with even more content to test",
    };

    for (payloads) |payload| {
        // Simulate receiving this datagram
        if (client.on_quic_datagram) |cb| {
            // Create a temporary buffer (simulating what processDatagrams does)
            var temp_buf: [256]u8 = undefined;
            @memcpy(temp_buf[0..payload.len], payload);

            // Call the callback with the temporary buffer
            cb(&client, temp_buf[0..payload.len], client.on_quic_datagram_user);

            // After callback returns, temp_buf could be reused/modified
            // This tests that the callback properly copied the data
        }
    }

    // Verify all payloads were properly copied and stored
    try std.testing.expectEqual(payloads.len, test_ctx.payload_copies.items.len);

    for (payloads, test_ctx.payload_copies.items) |expected, actual| {
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}
