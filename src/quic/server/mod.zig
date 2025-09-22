const std = @import("std");
const quiche = @import("quiche");
const connection = @import("connection");
const config_mod = @import("config");
const event_loop = @import("event_loop");
const EventLoop = event_loop.EventLoop;
const TimerHandle = event_loop.TimerHandle;
const udp = @import("udp");
const h3 = @import("h3");
const h3_datagram = @import("h3").datagram;
const http = @import("http");
const routing = @import("routing");
const errors = @import("errors");
const server_logging = @import("logging.zig");
const runtime_config = @import("config_runtime.zig");
const conn_state = @import("connection_state.zig");

const c = quiche.c;
const posix = std.posix;

// Debug helpers are provided by server/logging.zig

// Request state for streaming bodies
pub const RequestState = struct {
    arena: std.heap.ArenaAllocator,
    request: http.Request,
    response: http.Response,
    handler: http.Handler,
    body_complete: bool = false,
    handler_invoked: bool = false, // Track if handler was already called
    is_streaming: bool = false,
    // Phase 2: mark if this request is a download (file or generator streaming)
    is_download: bool = false,

    // User data for streaming handlers to store context
    user_data: ?*anyopaque = null,

    // Push-mode streaming callbacks (include Response pointer for bidirectional streaming)
    on_headers: ?http.OnHeaders = null,
    on_body_chunk: ?http.OnBodyChunk = null,
    on_body_complete: ?http.OnBodyComplete = null,

    // H3 DATAGRAM callback for request-associated datagrams
    on_h3_dgram: ?http.OnH3Datagram = null,

    // Whether the handler wants to keep the request alive for DATAGRAM echoing
    retain_for_datagram: bool = false,
    // Flag set once the stream has been detached but DATAGRAM flow still active
    datagram_detached: bool = false,

    // WebTransport session flag
    is_webtransport: bool = false,
};

// WT uni-stream preface accumulator lives in the WT facade now

pub const OnDatagram = *const fn (server: *QuicServer, conn: *connection.Connection, payload: []const u8, user: ?*anyopaque) errors.DatagramError!void;

pub const QuicServer = struct {
    allocator: std.mem.Allocator,
    config: config_mod.ServerConfig,
    quiche_config: quiche.Config,
    connections: connection.ConnectionTable,
    event_loop: *EventLoop,
    socket_v4: ?udp.UdpSocket = null,
    socket_v6: ?udp.UdpSocket = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    local_conn_id_len: usize = 16, // Use 16 bytes for our SCIDs
    send_buf: [2048]u8 = undefined, // Buffer for sending packets
    conn_id_seed: [32]u8, // HMAC-SHA256 key for connection ID derivation (like Rust)
    timeout_timer: ?TimerHandle = null,
    timeout_dirty: bool = false,
    next_timeout_deadline_ms: ?i64 = null,
    flush_timer: ?TimerHandle = null,
    flush_pending: bool = false,

    // HTTP/3 configuration
    h3_config: ?h3.H3Config = null,

    // HTTP routing via matcher only
    matcher: routing.Matcher,
    // Track per-connection stream state using a composite key so simultaneous
    // connections with the same stream_id (e.g., 0) don't collide.
    stream_states: std.hash_map.HashMap(conn_state.StreamKey, *RequestState, conn_state.StreamKeyContext, 80),

    // H3 DATAGRAM flow_id mapping lives under embedded state `h3`

    // Statistics (general)
    connections_accepted: usize = 0,
    packets_received: usize = 0,
    packets_sent: usize = 0,

    // Embedded state
    datagram: conn_state.DatagramStats = .{},
    h3: H3State,
    wt: WTState,

    on_datagram: ?OnDatagram = null,
    on_datagram_user: ?*anyopaque = null,

    // Feature facades (Zig 0.15.1 lacks container-scope `usingnamespace` support here)
    const DatagramFeature = @import("datagram.zig");
    const D = DatagramFeature.Impl(@This());
    const H3Core = @import("h3_core.zig");
    const H3 = H3Core.Impl(@This());
    const WTCore = @import("webtransport.zig");
    const WT = WTCore.Impl(@This());

    pub const StreamKey = conn_state.StreamKey;
    pub const StreamKeyContext = conn_state.StreamKeyContext;
    pub const SessionKey = conn_state.SessionKey;
    pub const SessionKeyContext = conn_state.SessionKeyContext;
    pub const FlowKey = conn_state.FlowKey;
    pub const FlowKeyContext = conn_state.FlowKeyContext;

    const H3State = conn_state.H3State(*RequestState);
    const WTState = conn_state.WTState(
        *h3.WebTransportSessionState,
        *h3.WebTransportSession.WebTransportStream,
        WT.UniPreface,
    );

    /// Build-time feature toggle for WebTransport
    pub const WithWT: bool = @import("build_options").with_webtransport;

    // H3 helpers are accessed directly via the H3 facade (no wrappers)

    comptime {
        const req_state_size = @sizeOf(RequestState);
        if (req_state_size > 4096) {
            @compileError(std.fmt.comptimePrint(
                "RequestState size ({d} bytes) exceeds expected maximum. Consider optimizing.",
                .{req_state_size},
            ));
        }
    }

    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.ServerConfig, matcher: routing.Matcher) !*QuicServer {
        const overrides = try runtime_config.applyRuntimeOverrides(allocator, cfg, WithWT);
        const cfg_eff = overrides.config;

        // Validate effective config after overrides and create qlog dir if needed
        try cfg_eff.validate();
        try cfg_eff.ensureQlogDir();

        // Create quiche config using effective settings
        var q_cfg = try quiche.Config.new(quiche.PROTOCOL_VERSION);
        errdefer q_cfg.deinit();

        // Load TLS certificates
        const cert_path = try allocator.dupeZ(u8, cfg_eff.cert_path);
        defer allocator.free(cert_path);
        const key_path = try allocator.dupeZ(u8, cfg_eff.key_path);
        defer allocator.free(key_path);

        try q_cfg.loadCertChainFromPemFile(cert_path);
        try q_cfg.loadPrivKeyFromPemFile(key_path);

        // Set ALPN protocols with proper wire format
        const alpn_wire = try quiche.encodeAlpn(allocator, cfg_eff.alpn_protocols);
        defer allocator.free(alpn_wire);
        try q_cfg.setApplicationProtos(alpn_wire);

        // Configure transport parameters
        q_cfg.setMaxIdleTimeout(cfg_eff.idle_timeout_ms);
        q_cfg.setInitialMaxData(cfg_eff.initial_max_data);
        q_cfg.setInitialMaxStreamDataBidiLocal(cfg_eff.initial_max_stream_data_bidi_local);
        q_cfg.setInitialMaxStreamDataBidiRemote(cfg_eff.initial_max_stream_data_bidi_remote);
        q_cfg.setInitialMaxStreamDataUni(cfg_eff.initial_max_stream_data_uni);
        q_cfg.setInitialMaxStreamsBidi(cfg_eff.initial_max_streams_bidi);
        q_cfg.setInitialMaxStreamsUni(cfg_eff.initial_max_streams_uni);
        q_cfg.setMaxRecvUdpPayloadSize(cfg_eff.max_recv_udp_payload_size);
        q_cfg.setMaxSendUdpPayloadSize(cfg_eff.max_send_udp_payload_size);

        // Features
        q_cfg.setDisableActiveMigration(cfg_eff.disable_active_migration);
        q_cfg.enablePacing(cfg_eff.enable_pacing);
        if (cfg_eff.enable_dgram) {
            const recv_len = if (cfg_eff.dgram_recv_queue_len == 0) 1024 else cfg_eff.dgram_recv_queue_len;
            const send_len = if (cfg_eff.dgram_send_queue_len == 0) 1024 else cfg_eff.dgram_send_queue_len;
            if (cfg_eff.enable_debug_logging) {
                std.debug.print("[init] enabling QUIC DATAGRAM (recv_queue={d}, send_queue={d})\n", .{ recv_len, send_len });
            }
            q_cfg.enableDgram(true, recv_len, send_len);
        } else {
            if (cfg_eff.enable_debug_logging) {
                std.debug.print("[init] QUIC DATAGRAM disabled via config\n", .{});
            }
            q_cfg.enableDgram(false, cfg_eff.dgram_recv_queue_len, cfg_eff.dgram_send_queue_len);
        }
        q_cfg.grease(cfg_eff.grease);

        // Set congestion control
        const cc_algo = try allocator.dupeZ(u8, cfg_eff.cc_algorithm);
        defer allocator.free(cc_algo);
        if (q_cfg.setCcAlgorithmName(cc_algo)) |_| {
            // ok
        } else |err| {
            // Log warning about unsupported CC algorithm
            // During init, we don't have a server instance yet, so use std.debug.print directly
            // This is a one-time initialization message
            std.debug.print("[WARN] cc={s} unsupported ({any}); falling back to cubic\n", .{ cfg_eff.cc_algorithm, err });
            const fallback = try allocator.dupeZ(u8, "cubic");
            defer allocator.free(fallback);
            _ = q_cfg.setCcAlgorithmName(fallback) catch {};
        }

        // Create event loop
        const loop = try EventLoop.initLibev(allocator);
        errdefer loop.deinit();

        // Create server
        const server = try allocator.create(QuicServer);
        errdefer allocator.destroy(server);

        // Generate random HMAC seed for connection ID derivation
        var conn_id_seed: [32]u8 = undefined;
        std.crypto.random.bytes(&conn_id_seed);

        var stream_states = std.hash_map.HashMap(conn_state.StreamKey, *RequestState, conn_state.StreamKeyContext, 80).init(allocator);
        errdefer stream_states.deinit();

        var h3_state = try H3State.init(allocator);
        errdefer h3_state.dgram_flows.deinit();

        var wt_state = try WTState.init(allocator);
        errdefer {
            wt_state.sessions.deinit();
            wt_state.dgram_map.deinit();
            wt_state.streams.deinit();
            wt_state.uni_preface.deinit();
        }

        server.* = .{
            .allocator = allocator,
            .config = cfg_eff,
            .quiche_config = q_cfg,
            .connections = connection.ConnectionTable.init(allocator),
            .event_loop = loop,
            .conn_id_seed = conn_id_seed,
            .matcher = matcher,
            .stream_states = stream_states,
            .h3 = h3_state,
            .wt = wt_state,
        };

        // Reapply DATAGRAM setting on stored quiche config to ensure move semantics
        if (server.config.enable_dgram) {
            const recv_len = if (server.config.dgram_recv_queue_len == 0) 1024 else server.config.dgram_recv_queue_len;
            const send_len = if (server.config.dgram_send_queue_len == 0) 1024 else server.config.dgram_send_queue_len;
            server.quiche_config.enableDgram(true, recv_len, send_len);
        } else {
            server.quiche_config.enableDgram(false, server.config.dgram_recv_queue_len, server.config.dgram_send_queue_len);
        }

        // Create H3 config; WebTransport requires explicit build flag
        if (WithWT and overrides.webtransport_enabled) {
            server.h3_config = try h3.H3Config.initWithWebTransport();
        } else {
            server.h3_config = try h3.H3Config.initWithDefaults();
        }
        errdefer if (server.h3_config) |*h| h.deinit();

        server.wt.enable_streams = overrides.wt_streams and WithWT;
        server.wt.enable_bidi = overrides.wt_bidi and WithWT;

        // Enable debug logging if requested
        if (server.config.enable_debug_logging) {
            try quiche.enableDebugLogging(server_logging.debugLog, &server.config);
        }

        return server;
    }

    pub fn eventLoop(self: *QuicServer) *EventLoop {
        return self.event_loop;
    }

    pub fn requestFlush(self: *QuicServer) void {
        if (self.flush_pending) return;

        if (self.flush_timer == null) {
            self.flush_timer = self.event_loop.createTimer(flushTimerCb, self) catch {
                return;
            };
        }

        self.flush_pending = true;
        self.event_loop.startTimer(self.flush_timer.?, 0.0, 0.0);
    }

    // Callback used by WebTransport sessions to report successful DATAGRAM sends
    fn wtOnDatagramSent(ctx: *anyopaque, _bytes: usize) void {
        _ = _bytes; // currently unused; future: track bytes sent
        const self: *QuicServer = @ptrCast(@alignCast(ctx));
        self.wt.dgrams_sent += 1;
    }

    pub fn deinit(self: *QuicServer) void {
        self.stop();

        if (self.timeout_timer) |handle| {
            self.event_loop.destroyTimer(handle);
            self.timeout_timer = null;
        }
        if (self.flush_timer) |handle| {
            self.event_loop.destroyTimer(handle);
            self.flush_timer = null;
        }

        // Clean up connections (including their H3 connections)
        var it = self.connections.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.http3) |h3_ptr| {
                const h3_conn = @as(*h3.H3Connection, @ptrCast(@alignCast(h3_ptr)));
                h3_conn.deinit();
                self.allocator.destroy(h3_conn);
            }
        }
        self.connections.deinit();

        // Clean up stream states
        var stream_iter = self.stream_states.iterator();
        while (stream_iter.next()) |entry| {
            entry.value_ptr.*.response.deinit();
            entry.value_ptr.*.arena.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.stream_states.deinit();

        // Clean up H3 DATAGRAM flows (no values to free - they point to RequestState already freed above)
        self.h3.dgram_flows.deinit();

        // Clean up WebTransport sessions
        var wt_it = self.wt.sessions.iterator();
        while (wt_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.wt.sessions.deinit();

        // Clean up WebTransport datagram map (values already freed above)
        self.wt.dgram_map.deinit();

        // Clean up WT streams
        var it_ws = self.wt.streams.iterator();
        while (it_ws.next()) |entry| {
            const s = entry.value_ptr.*;
            s.allocator.destroy(s);
        }
        self.wt.streams.deinit();
        self.wt.uni_preface.deinit();

        // No router to clean up

        if (self.h3_config) |*h| h.deinit();
        self.quiche_config.deinit();
        self.event_loop.deinit();
        if (self.socket_v4) |*s| s.*.close();
        if (self.socket_v6) |*s| s.*.close();
        self.allocator.destroy(self);
    }

    /// Register a QUIC DATAGRAM handler
    pub fn onDatagram(self: *QuicServer, cb: OnDatagram, user: ?*anyopaque) void {
        D.onDatagram(self, cb, user);
    }

    /// Send a QUIC DATAGRAM on a connection, tracking counters
    pub fn sendDatagram(self: *QuicServer, conn: *connection.Connection, data: []const u8) !void {
        return D.sendDatagram(self, conn, data);
    }

    pub fn bind(self: *QuicServer) !void {
        // Try to bind sockets based on configured bind_addr
        var sockets: udp.BindResult = .{};
        if (std.mem.eql(u8, self.config.bind_addr, "127.0.0.1") or std.mem.eql(u8, self.config.bind_addr, "localhost")) {
            // Prefer loopback-only in restricted environments (CI/sandbox)
            sockets.v6 = udp.bindUdp6Loopback(self.config.bind_port, true) catch null;
            sockets.v4 = udp.bindUdp4Loopback(self.config.bind_port, true) catch null;
        } else {
            sockets = udp.bindAny(self.config.bind_port, true);
        }
        if (!sockets.hasAny()) return error.FailedToBind;

        if (sockets.v6) |sock| {
            self.socket_v6 = sock;
            // Enlarge socket buffers for high-throughput scenarios
            udp.setRecvBufferSize(sock.fd, 16 * 1024 * 1024) catch {};
            udp.setSendBufferSize(sock.fd, 16 * 1024 * 1024) catch {};
            try self.event_loop.addUdpIo(sock.fd, onUdpReadable, self);
            std.debug.print("QUIC server bound to [::]:{d}\n", .{self.config.bind_port});
        }

        if (sockets.v4) |sock| {
            self.socket_v4 = sock;
            udp.setRecvBufferSize(sock.fd, 16 * 1024 * 1024) catch {};
            udp.setSendBufferSize(sock.fd, 16 * 1024 * 1024) catch {};
            try self.event_loop.addUdpIo(sock.fd, onUdpReadable, self);
            std.debug.print("QUIC server bound to 0.0.0.0:{d}\n", .{self.config.bind_port});
        }
    }

    pub fn run(self: *QuicServer) !void {
        self.running.store(true, .release);

        // Add signal handlers for graceful shutdown
        try self.event_loop.addSigint(onSignal, self);
        try self.event_loop.addSigterm(onSignal, self);

        std.debug.print("QUIC server running (quiche {s})\n", .{quiche.version()});
        std.debug.print("Test with: cargo run -p quiche --bin quiche-client -- https://127.0.0.1:{d}/ --no-verify --alpn hq-interop\n", .{self.config.bind_port});

        self.event_loop.run();
    }

    pub fn stop(self: *QuicServer) void {
        if (self.running.swap(false, .acq_rel)) {
            // Note: libev will clean up timers when loop stops
            self.event_loop.stop();
        }
    }

    /// Open a server-initiated WebTransport unidirectional stream for a session.
    /// Writes the WT uni-stream preface (type + session_id). If backpressured,
    /// the preface is queued and flushed when writable.
    pub fn openWtUniStream(
        self: *QuicServer,
        conn: *connection.Connection,
        sess_state: *h3.WebTransportSessionState,
    ) !*h3.WebTransportSession.WebTransportStream {
        return WT.openWtUniStream(self, conn, sess_state);
    }

    /// Open a server-initiated WebTransport bidirectional stream for a session.
    /// Writes the spec-accurate bidi preface [0x41][session_id] to bind the stream
    /// to the session (no capsules). Callers may then use sendWtStream() to write data.
    pub fn openWtBidiStream(
        self: *QuicServer,
        conn: *connection.Connection,
        sess_state: *h3.WebTransportSessionState,
    ) !*h3.WebTransportSession.WebTransportStream {
        return WT.openWtBidiStream(self, conn, sess_state);
    }

    // No capsule registration path; bidi binding uses per-stream preface.

    // All route registration APIs removed; use matcher generator

    fn onUdpReadable(fd: posix.socket_t, _revents: u32, user_data: *anyopaque) void {
        _ = _revents;
        const self: *QuicServer = @ptrCast(@alignCast(user_data));
        self.processPackets(fd) catch |err| {
            std.debug.print("Error processing packets: {}\n", .{err});
        };
    }

    fn onTimeoutTimer(user_data: *anyopaque) void {
        const self: *QuicServer = @ptrCast(@alignCast(user_data));
        self.checkTimeouts() catch |err| {
            std.debug.print("Error checking timeouts: {}\n", .{err});
        };
    }

    // Derive connection ID using HMAC-SHA256 (like Rust implementation)
    fn deriveConnId(self: *const QuicServer, dcid: []const u8) [16]u8 {
        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.conn_id_seed);
        hmac.update(dcid);
        var hash: [32]u8 = undefined;
        hmac.final(&hash);

        // Take first 16 bytes of HMAC output as connection ID
        var conn_id: [16]u8 = undefined;
        @memcpy(&conn_id, hash[0..16]);
        return conn_id;
    }

    fn processPackets(self: *QuicServer, fd: posix.socket_t) !void {
        // Batch receive to reduce syscall overhead
        var bufs: [udp.MAX_BATCH][2048]u8 = undefined;
        var views: [udp.MAX_BATCH]udp.RecvView = undefined;

        while (true) {
            // Prepare slices for this batch
            var slices: [udp.MAX_BATCH][]u8 = undefined;
            for (&slices, 0..) |*s, i| s.* = bufs[i][0..];

            const nrecv = try udp.recvBatch(fd, slices[0..], views[0..]);
            if (nrecv == 0) break; // WouldBlock or no data

            self.packets_received += nrecv;

            // Get local address once per batch (used for recv_info.to)
            var local_addr: posix.sockaddr.storage = undefined;
            var local_addr_len: posix.socklen_t = @sizeOf(@TypeOf(local_addr));
            _ = posix.getsockname(fd, @ptrCast(&local_addr), &local_addr_len) catch {
                // Failed to get local address; skip this batch
                continue;
            };

            // Track touched connections to drain once per conn
            var touched: [udp.MAX_BATCH]*connection.Connection = undefined;
            var touched_len: usize = 0;

            var i: usize = 0;
            while (i < nrecv) : (i += 1) {
                const pkt_buf = bufs[i][0..views[i].len];
                var peer_addr = views[i].addr;
                const peer_addr_len = views[i].addr_len;

                // Parse QUIC header
                var dcid: [quiche.MAX_CONN_ID_LEN]u8 = undefined;
                var scid: [quiche.MAX_CONN_ID_LEN]u8 = undefined;
                var dcid_len: usize = dcid.len;
                var scid_len: usize = scid.len;
                var version: u32 = 0;
                var pkt_type: u8 = 0;
                var token: [256]u8 = undefined;
                var token_len: usize = token.len;

                quiche.headerInfo(
                    pkt_buf,
                    self.local_conn_id_len,
                    &version,
                    &pkt_type,
                    &scid,
                    &scid_len,
                    &dcid,
                    &dcid_len,
                    &token,
                    &token_len,
                ) catch {
                    // Failed to parse packet header, skip
                    continue;
                };

                // First, try to look up connection by the DCID as-is
                // This handles subsequent packets where client uses our SCID as DCID
                var key_dcid: [quiche.MAX_CONN_ID_LEN]u8 = undefined;
                @memcpy(key_dcid[0..dcid_len], dcid[0..dcid_len]);

                var key = connection.ConnectionKey{
                    .dcid = key_dcid,
                    .dcid_len = @intCast(dcid_len),
                    .family = @as(*const posix.sockaddr, @ptrCast(&peer_addr)).family,
                };

                var conn = self.connections.get(key);

                // Derive connection ID using HMAC (like Rust)
                const derived_conn_id = self.deriveConnId(dcid[0..dcid_len]);

                // If not found by DCID, try HMAC-derived ID (for first Initial packet)
                if (conn == null) {
                    @memcpy(key_dcid[0..16], &derived_conn_id);
                    key = connection.ConnectionKey{
                        .dcid = key_dcid,
                        .dcid_len = 16,
                        .family = @as(*const posix.sockaddr, @ptrCast(&peer_addr)).family,
                    };
                    conn = self.connections.get(key);
                }

                const is_new_conn = (conn == null);

                if (is_new_conn) {
                    // Only create new connections for Initial packets (type 1)
                    // Other packet types should have an existing connection
                    if (pkt_type != quiche.PacketType.Initial) {
                        // Not an Initial packet but no connection found - drop it
                        continue;
                    }

                    // Check if version is supported BEFORE creating connection
                    if (!quiche.versionIsSupported(version)) {
                        // Send version negotiation packet
                        const vneg_len = quiche.negotiateVersion(
                            scid[0..scid_len],
                            dcid[0..dcid_len],
                            &self.send_buf,
                        ) catch {
                            continue;
                        };

                        _ = posix.sendto(fd, self.send_buf[0..vneg_len], 0, @ptrCast(&peer_addr), peer_addr_len) catch {};
                        continue; // Don't create connection for unsupported versions
                    }

                    // Only create connection for supported versions
                    conn = try self.acceptConnection(
                        &peer_addr,
                        peer_addr_len,
                        dcid[0..dcid_len],
                        derived_conn_id, // Use HMAC-derived ID as our SCID
                        fd,
                        pkt_buf, // Pass the initial packet
                    );
                    if (conn == null) continue;

                    // Initial packet was already processed in acceptConnection
                    // Fall through to process H3 and writable streams
                } else {
                    // Process packet with existing connection
                    const recv_info = c.quiche_recv_info{
                        .from = @ptrCast(&peer_addr),
                        .from_len = peer_addr_len,
                        .to = @ptrCast(&local_addr),
                        .to_len = local_addr_len,
                    };

                    _ = conn.?.conn.recv(pkt_buf, &recv_info) catch |err| {
                        if (err == error.Done) {
                            // This is normal - just means no more data to process
                        } else if (err != error.CryptoFail) {
                            // Log non-crypto errors (crypto errors are common during handshake)
                            std.debug.print("quiche_conn_recv failed: {}\n", .{err});
                        }
                        // Don't skip to next packet - fall through to check connection state
                    };
                }

                // Check if handshake completed
                if (conn.?.conn.isEstablished() and !conn.?.handshake_logged) {
                    var hex_buf: [40]u8 = undefined;
                    const hex_dcid = try connection.formatCid(dcid[0..dcid_len], &hex_buf);

                    // Build complete message first, then print once
                    if (conn.?.conn.applicationProto()) |proto| {
                        std.debug.print("✓ Handshake complete! DCID: {s}, ALPN: {s}\n", .{ hex_dcid, proto });

                        // Create H3 connection if ALPN is "h3"
                        if (std.mem.eql(u8, proto, "h3") and conn.?.http3 == null) {
                            if (self.h3_config) |*h3_cfg| {
                                const h3_conn = try self.allocator.create(h3.H3Connection);
                                h3_conn.* = try h3.H3Connection.newWithTransport(
                                    self.allocator,
                                    &conn.?.conn,
                                    h3_cfg,
                                );
                                conn.?.http3 = h3_conn;
                                std.debug.print("✓ HTTP/3 connection created for DCID: {s}\n", .{hex_dcid});
                                if (self.config.enable_dgram) {
                                    // Note: H3 DATAGRAM negotiation happens via SETTINGS exchange
                                    // At this point (immediately after H3 creation), the SETTINGS frames
                                    // haven't been exchanged yet, so dgramEnabledByPeer() will return false.
                                    // The actual negotiation completes shortly after, during the first
                                    // request processing. This is normal and expected behavior.
                                    server_logging.debugPrint(self, "  QUIC DATAGRAM enabled, H3 DATAGRAM SETTINGS will be exchanged\n", .{});
                                }
                            }
                        } else if (!std.mem.eql(u8, proto, "h3")) {
                            // Log when we're not using H3 (e.g., hq-interop)
                            std.debug.print("  ALPN fallback: using {s} instead of h3\n", .{proto});
                        }
                    } else {
                        std.debug.print("✓ Handshake complete! DCID: {s}\n", .{hex_dcid});
                    }

                    conn.?.handshake_logged = true;
                }

                // Record touched connection for post-batch processing (deduplicate crudely)
                if (touched_len < touched.len) {
                    var seen = false;
                    var t: usize = 0;
                    while (t < touched_len) : (t += 1) {
                        if (touched[t] == conn.?) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) {
                        touched[touched_len] = conn.?;
                        touched_len += 1;
                    }
                }
            }

            // After processing the batch, walk touched connections once
            var k: usize = 0;
            while (k < touched_len) : (k += 1) {
                const cconn = touched[k];
                if (cconn.http3 != null) {
                    H3.processH3(self, cconn) catch |err| {
                        if (err != quiche.h3.Error.StreamBlocked) {
                            std.debug.print("H3 processing error: {}\n", .{err});
                        }
                    };
                }
                // Drain any QUIC DATAGRAMs
                D.processDatagrams(self, cconn) catch |err| {
                    std.debug.print("Error processing datagrams: {}\n", .{err});
                };
                // Process WT streams (experimental) only when enabled
                if (self.wt.enable_streams and self.wt.sessions.count() > 0) {
                    WT.processReadableWtStreams(self, cconn) catch |err| {
                        std.debug.print("Error processing WT streams: {}\n", .{err});
                    };
                }
                H3.processWritableStreams(self, cconn) catch |err| {
                    std.debug.print("Error processing writable streams: {}\n", .{err});
                };
                if (self.wt.enable_streams and self.wt.sessions.count() > 0) {
                    WT.processWritableWtStreams(self, cconn) catch |err| {
                        std.debug.print("Error processing WT writable streams: {}\n", .{err});
                    };
                }
                try self.drainEgress(cconn);
                const timeout_ms2 = cconn.conn.timeoutAsMillis();
                self.updateTimer(cconn, timeout_ms2);
                if (cconn.conn.isClosed()) {
                    self.closeConnection(cconn);
                }
            }
            try self.flushTimeoutReschedule();
        }
    }

    fn acceptConnection(
        self: *QuicServer,
        peer_addr: *const posix.sockaddr.storage,
        peer_addr_len: posix.socklen_t,
        dcid: []const u8,
        scid: [16]u8, // Use the HMAC-derived ID as our SCID
        fd: posix.socket_t,
        initial_packet: []const u8, // Add the initial packet to process
    ) !?*connection.Connection {
        // Use provided SCID (HMAC-derived) instead of generating random one
        const new_scid = scid;

        // Get local address
        var local_addr: posix.sockaddr.storage = undefined;
        var local_addr_len: posix.socklen_t = @sizeOf(@TypeOf(local_addr));
        _ = posix.getsockname(fd, @ptrCast(&local_addr), &local_addr_len) catch {
            return null;
        };

        // Accept with quiche
        var q_conn = quiche.accept(
            &new_scid,
            null, // No ODCID for now
            @ptrCast(&local_addr),
            local_addr_len,
            @ptrCast(peer_addr),
            peer_addr_len,
            &self.quiche_config,
        ) catch |err| {
            std.debug.print("quiche_accept failed: {}\n", .{err});
            return null;
        };

        // Set up qlog immediately
        var qlog_path: ?[]u8 = null;
        if (self.config.qlog_dir != null) {
            const path = self.config.createQlogPath(self.allocator, &new_scid) catch null;
            if (path) |p| {
                // Create persistent strings for qlog - they need to remain valid for the connection lifetime
                const title = try self.allocator.dupeZ(u8, "quic-server");
                errdefer self.allocator.free(title);
                const desc = try self.allocator.dupeZ(u8, "Zig QUIC Server M3 - HTTP/3");
                errdefer self.allocator.free(desc);

                if ((&q_conn).setQlogPath(p, title[0..title.len :0], desc[0..desc.len :0])) {
                    qlog_path = p;
                    std.debug.print("QLOG enabled: {s}\n", .{p});
                    // quiche copies the strings internally, so we can free them now
                    self.allocator.free(title);
                    self.allocator.free(desc);
                    // Note: We keep 'p' allocated and pass ownership to the connection
                } else {
                    // QLOG setup failed, clean up
                    self.allocator.free(p);
                    self.allocator.free(title);
                    self.allocator.free(desc);
                    std.debug.print("QLOG setup failed for connection\n", .{});
                }
            }
        }

        // Create connection object
        const conn = try connection.createConnection(
            self.allocator,
            q_conn,
            new_scid,
            dcid,
            peer_addr.*,
            peer_addr_len,
            self.config.bind_port,
            fd,
            qlog_path,
        );

        // Add to table
        try self.connections.put(conn);
        self.connections_accepted += 1;

        // CRITICAL: Process the initial packet immediately after accept!
        // This is what the Rust implementation does - call recv() right after accept()
        const recv_info = c.quiche_recv_info{
            .from = @ptrCast(@constCast(peer_addr)),
            .from_len = peer_addr_len,
            .to = @ptrCast(&local_addr),
            .to_len = local_addr_len,
        };

        // recv needs a mutable buffer, so we need to copy
        var packet_buf: [2048]u8 = undefined;
        const packet_len = @min(initial_packet.len, packet_buf.len);
        @memcpy(packet_buf[0..packet_len], initial_packet[0..packet_len]);

        _ = conn.conn.recv(packet_buf[0..packet_len], &recv_info) catch {
            // Don't fail connection creation - let it continue
            return conn;
        };

        return conn;
    }

    /// Update the connection's timeout deadline based on quiche's reported timeout.
    pub fn updateTimer(self: *QuicServer, conn: *connection.Connection, timeout_ms: u64) void {
        const sentinel = std.math.maxInt(u64);
        if (timeout_ms == sentinel) {
            conn.timeout_deadline_ms = null;
        } else {
            const now = nowMillis();
            const delta_i64 = std.math.cast(i64, timeout_ms) orelse std.math.maxInt(i64);
            var deadline: i64 = now;
            if (timeout_ms > 0) {
                deadline = std.math.add(i64, now, delta_i64) catch std.math.maxInt(i64);
            }
            conn.timeout_deadline_ms = deadline;
        }
        self.timeout_dirty = true;
    }

    fn nowMillis() i64 {
        return std.time.milliTimestamp();
    }

    fn flushTimeoutReschedule(self: *QuicServer) !void {
        if (!self.timeout_dirty) return;
        self.timeout_dirty = false;
        try self.rescheduleTimeoutTimer();
    }

    fn rescheduleTimeoutTimer(self: *QuicServer) !void {
        const earliest = self.findEarliestDeadline();
        if (earliest) |deadline| {
            self.next_timeout_deadline_ms = deadline;
            const now = nowMillis();
            var delta_ms: i64 = deadline - now;
            if (delta_ms < 0) delta_ms = 0;
            const delta_s = @as(f64, @floatFromInt(delta_ms)) / 1000.0;
            if (self.timeout_timer == null) {
                self.timeout_timer = try self.event_loop.createTimer(onTimeoutTimer, self);
            }
            self.event_loop.startTimer(self.timeout_timer.?, delta_s, 0);
        } else {
            self.next_timeout_deadline_ms = null;
            if (self.timeout_timer) |handle| {
                self.event_loop.stopTimer(handle);
            }
        }
    }

    fn findEarliestDeadline(self: *QuicServer) ?i64 {
        var earliest: ?i64 = null;
        var iter = self.connections.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.timeout_deadline_ms) |deadline| {
                if (earliest == null or deadline < earliest.?) {
                    earliest = deadline;
                }
            }
        }
        return earliest;
    }

    fn checkTimeouts(self: *QuicServer) !void {
        const now = nowMillis();
        var due = std.ArrayListUnmanaged(*connection.Connection){};
        defer due.deinit(self.allocator);
        var iter = self.connections.map.iterator();
        while (iter.next()) |entry| {
            const conn = entry.value_ptr.*;
            if (conn.timeout_deadline_ms) |deadline| {
                if (deadline <= now) {
                    try due.append(self.allocator, conn);
                }
            }
        }

        for (due.items) |conn| {
            self.onTimeout(conn) catch |err| {
                std.debug.print("Error handling timeout: {}\n", .{err});
            };
        }

        try self.flushTimeoutReschedule();
    }

    pub fn drainEgress(self: *QuicServer, conn: *connection.Connection) !void {
        // Batch up to udp.MAX_BATCH packets per flush
        var out_bufs: [udp.MAX_BATCH][2048]u8 = undefined;
        var send_views: [udp.MAX_BATCH]udp.SendView = undefined;
        var count: usize = 0;

        while (true) {
            var send_info: c.quiche_send_info = undefined;

            const written = conn.conn.send(&out_bufs[count], &send_info) catch |err| {
                if (err == error.Done) break;
                return err;
            };

            // Select destination address (path-aware)
            const dest_ptr = if (send_info.to_len > 0)
                @as(*const posix.sockaddr, @ptrCast(&send_info.to))
            else
                @as(*const posix.sockaddr, @ptrCast(&conn.peer_addr));
            const dest_len: posix.socklen_t = if (send_info.to_len > 0) send_info.to_len else conn.peer_addr_len;

            // Copy dest addr into view storage
            var st: posix.sockaddr.storage = undefined;
            const copy_len = @min(@as(usize, dest_len), @sizeOf(posix.sockaddr.storage));
            @memcpy(@as([*]u8, @ptrCast(&st))[0..copy_len], @as([*]const u8, @ptrCast(dest_ptr))[0..copy_len]);

            send_views[count] = .{
                .data = out_bufs[count][0..written],
                .addr = st,
                .addr_len = dest_len,
            };
            count += 1;

            if (count == udp.MAX_BATCH) {
                self.packets_sent += try udp.sendBatch(conn.socket_fd, send_views[0..count]);
                count = 0;
            }
        }

        if (count > 0) {
            self.packets_sent += try udp.sendBatch(conn.socket_fd, send_views[0..count]);
        }
    }

    /// Send data on a WT stream with backpressure handling.
    /// Wrapper that delegates to the WT facade.
    pub fn sendWtStream(
        self: *QuicServer,
        conn: *connection.Connection,
        stream: *h3.WebTransportSession.WebTransportStream,
        data: []const u8,
        fin: bool,
    ) !usize {
        return WT.sendWtStream(self, conn, stream, data, fin);
    }

    /// Convenience helper: ensure all bytes are either sent immediately or
    /// queued for later sending. Never returns WouldBlock — it enqueues the
    /// remainder when immediate send can't progress.
    pub fn sendWtStreamAll(
        self: *QuicServer,
        conn: *connection.Connection,
        stream: *h3.WebTransportSession.WebTransportStream,
        data: []const u8,
        fin: bool,
    ) !void {
        return WT.sendWtStreamAll(self, conn, stream, data, fin);
    }

    /// Drain all currently available bytes from a WT stream into `out`.
    /// Returns the total bytes copied and whether a FIN was observed.
    /// Stops when the stream reports Done (no more data now), when `out` is full,
    /// or when FIN is received. Does not allocate.
    pub fn readWtStreamAll(
        self: *QuicServer,
        conn: *connection.Connection,
        stream: *h3.WebTransportSession.WebTransportStream,
        out: []u8,
    ) !struct { n: usize, fin: bool } {
        return WT.readWtStreamAll(self, conn, stream, out);
    }

    // ------------------------ Tests ------------------------
    test "cleanup removes stream state and H3 DATAGRAM flow mapping" {
        const allocator = std.testing.allocator;

        // Prepare a minimal server instance with just the fields we need
        var server: QuicServer = undefined;
        server.allocator = allocator;
        server.stream_states = std.hash_map.HashMap(conn_state.StreamKey, *RequestState, conn_state.StreamKeyContext, 80).init(allocator);
        server.h3 = try H3State.init(allocator);

        // Create a dummy connection
        const conn_ptr = try allocator.create(connection.Connection);
        defer allocator.destroy(conn_ptr);

        const test_stream_id: u64 = 5;
        const flow_id = h3_datagram.flowIdForStream(test_stream_id);

        // Create a minimal RequestState with a Response safe for deinit()
        const state = try allocator.create(RequestState);
        state.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .request = undefined,
            .response = .{
                .h3_conn = @ptrFromInt(1),
                .quic_conn = @ptrFromInt(1),
                .stream_id = test_stream_id,
                .headers_sent = false,
                .ended = false,
                .status_code = 200,
                .header_buffer = std.ArrayList(quiche.h3.Header){},
                .allocator = allocator,
                .is_head_request = false,
                .partial_response = null,
            },
            .handler = undefined,
            .body_complete = false,
            .handler_invoked = false,
            .is_streaming = false,
            .user_data = null,
            .on_headers = null,
            .on_body_chunk = null,
            .on_body_complete = null,
            // Set a non-null callback so cleanup also purges flow mapping
            .on_h3_dgram = @ptrFromInt(1),
        };

        // Insert entries into both maps
        try server.stream_states.put(.{ .conn = conn_ptr, .stream_id = test_stream_id }, state);
        try server.h3.dgram_flows.put(.{ .conn = conn_ptr, .flow_id = flow_id }, state);

        // Sanity: entries exist
        try std.testing.expect(server.stream_states.get(.{ .conn = conn_ptr, .stream_id = test_stream_id }) != null);
        try std.testing.expect(server.h3.dgram_flows.get(.{ .conn = conn_ptr, .flow_id = flow_id }) != null);

        // Act: cleanup
        H3.cleanupStreamState(&server, conn_ptr, test_stream_id, state);

        // Verify: both entries are removed
        try std.testing.expect(server.stream_states.get(.{ .conn = conn_ptr, .stream_id = test_stream_id }) == null);
        try std.testing.expect(server.h3.dgram_flows.get(.{ .conn = conn_ptr, .flow_id = flow_id }) == null);

        // Deinit maps
        server.stream_states.deinit();
        server.h3.dgram_flows.deinit();
    }

    /// Increment H3 DATAGRAM sent counter (for use by callbacks)
    pub fn incrementH3DatagramSent(self: *QuicServer) void {
        self.h3.dgrams_sent += 1;
    }

    fn onTimeout(self: *QuicServer, conn: *connection.Connection) !void {
        conn.conn.onTimeout();
        try self.drainEgress(conn);
        const timeout_ms = conn.conn.timeoutAsMillis();
        self.updateTimer(conn, timeout_ms);
        if (conn.conn.isClosed()) {
            self.closeConnection(conn);
        }
    }

    fn flushTimerCb(user_data: *anyopaque) void {
        const self: *QuicServer = @ptrCast(@alignCast(user_data));
        self.flushPendingWork();
    }

    fn flushPendingWork(self: *QuicServer) void {
        self.flush_pending = false;

        var conns = std.ArrayListUnmanaged(*connection.Connection){};
        defer conns.deinit(self.allocator);

        var iter = self.connections.map.iterator();
        while (iter.next()) |entry| {
            conns.append(self.allocator, entry.value_ptr.*) catch {
                std.debug.print("requestFlush: failed to queue connection for flush\n", .{});
                break;
            };
        }

        for (conns.items) |conn| {
            if (conn.http3 != null) {
                H3.processWritableStreams(self, conn) catch |err| {
                    if (err != quiche.h3.Error.StreamBlocked) {
                        std.debug.print("requestFlush: writable processing error {}\n", .{err});
                    }
                };
            }

            D.processDatagrams(self, conn) catch |err| {
                std.debug.print("requestFlush: datagram processing error {}\n", .{err});
            };

            if (self.wt.enable_streams and self.wt.sessions.count() > 0) {
                WT.processWritableWtStreams(self, conn) catch |err| {
                    std.debug.print("requestFlush: WT writable processing error {}\n", .{err});
                };
            }

            self.drainEgress(conn) catch |err| {
                std.debug.print("requestFlush: drain egress error {}\n", .{err});
            };

            const timeout_ms = conn.conn.timeoutAsMillis();
            self.updateTimer(conn, timeout_ms);
            if (conn.conn.isClosed()) {
                self.closeConnection(conn);
            }
        }

        self.flushTimeoutReschedule() catch |err| {
            std.debug.print("requestFlush: timeout reschedule error {}\n", .{err});
        };
    }

    fn closeConnection(self: *QuicServer, conn: *connection.Connection) void {
        conn.timeout_deadline_ms = null;
        self.timeout_dirty = true;
        // Clean up any pending stream states for this connection first
        var to_remove = std.ArrayList(conn_state.StreamKey){};
        defer to_remove.deinit(self.allocator);
        {
            var it = self.stream_states.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.conn == conn) {
                    // Copy key for removal after iteration
                    to_remove.append(self.allocator, key) catch {};
                }
            }
        }
        for (to_remove.items) |k| {
            if (self.stream_states.fetchRemove(k)) |kv| {
                H3.cleanupStreamState(self, conn, k.stream_id, kv.value);
            }
        }

        // Purge any remaining H3 DATAGRAM flow mappings for this connection
        {
            var it2 = self.h3.dgram_flows.iterator();
            var flow_keys_to_remove = std.ArrayList(conn_state.FlowKey){};
            defer flow_keys_to_remove.deinit(self.allocator);
            while (it2.next()) |entry| {
                const fk = entry.key_ptr.*;
                if (fk.conn == conn) {
                    flow_keys_to_remove.append(self.allocator, fk) catch {};
                }
            }
            for (flow_keys_to_remove.items) |fk| {
                if (self.h3.dgram_flows.fetchRemove(fk)) |kv| {
                    const retained = kv.value;
                    retained.response.deinit();
                    retained.arena.deinit();
                    self.allocator.destroy(retained);
                }
            }
        }

        // Clean up WebTransport sessions for this connection
        {
            var wt_it = self.wt.sessions.iterator();
            var wt_keys_to_remove = std.ArrayList(SessionKey){};
            defer wt_keys_to_remove.deinit(self.allocator);
            while (wt_it.next()) |entry| {
                const sk = entry.key_ptr.*;
                if (sk.conn == conn) {
                    wt_keys_to_remove.append(self.allocator, sk) catch {};
                }
            }
            for (wt_keys_to_remove.items) |sk| {
                if (self.wt.sessions.fetchRemove(sk)) |kv| {
                    // Remove from datagram map
                    _ = self.wt.dgram_map.remove(.{ .conn = conn, .flow_id = sk.session_id });
                    // Clean up session state
                    kv.value.deinit(self.allocator);
                    self.wt.sessions_closed += 1;
                }
            }
        }

        // Log stats
        var stats: c.quiche_stats = undefined;
        conn.conn.stats(&stats);

        var hex_buf: [40]u8 = undefined;
        const hex_dcid = connection.formatCid(conn.dcid[0..conn.dcid_len], &hex_buf) catch "???";

        // Check for peer error details
        if (conn.conn.peerError()) |peer_err| {
            std.debug.print("Connection closed {s}: recv={d} sent={d} lost={d} peer_error={{app={}, code=0x{x}, reason=\"{s}\"}}\n", .{
                hex_dcid,
                stats.recv,
                stats.sent,
                stats.lost,
                peer_err.is_app,
                peer_err.error_code,
                peer_err.reason,
            });
        } else {
            std.debug.print("Connection closed {s}: recv={d} sent={d} lost={d}\n", .{
                hex_dcid,
                stats.recv,
                stats.sent,
                stats.lost,
            });
        }

        // Clean up H3 connection if it exists
        if (conn.http3) |h3_ptr| {
            const h3_conn = @as(*h3.H3Connection, @ptrCast(@alignCast(h3_ptr)));
            h3_conn.deinit();
            self.allocator.destroy(h3_conn);
            conn.http3 = null;
        }

        // Remove from table and cleanup
        const key = conn.getKey();
        if (self.connections.remove(key)) |removed| {
            removed.deinit(self.allocator);
            self.allocator.destroy(removed);
        }
    }

    // expireIdleWtSessions lives in the WT facade

    fn onSignal(signum: c_int, user_data: *anyopaque) void {
        const self: *QuicServer = @ptrCast(@alignCast(user_data));
        const sig_name = if (signum == posix.SIG.INT) "SIGINT" else "SIGTERM";
        std.debug.print("\n{s} received, shutting down...\n", .{sig_name});

        // Print final stats
        std.debug.print("Stats: connections={d}, packets_in={d}, packets_out={d}\n", .{
            self.connections_accepted,
            self.packets_received,
            self.packets_sent,
        });

        // QUIC DATAGRAM stats
        std.debug.print("  QUIC dgrams: recv={d}, sent={d}, dropped_on_send={d}\n", .{
            self.datagram.received,
            self.datagram.sent,
            self.datagram.dropped_send,
        });

        // H3 DATAGRAM stats
        std.debug.print("  H3 dgrams: recv={d}, sent={d}, unknown_flow={d}, would_block={d}\n", .{
            self.h3.dgrams_received,
            self.h3.dgrams_sent,
            self.h3.unknown_flow,
            self.h3.would_block,
        });

        // WebTransport stats
        std.debug.print("  WebTransport: sessions={{created={d}, closed={d}}}, dgrams={{recv={d}, sent={d}, would_block={d}}}\n", .{
            self.wt.sessions_created,
            self.wt.sessions_closed,
            self.wt.dgrams_received,
            self.wt.dgrams_sent,
            self.wt.dgrams_would_block,
        });

        self.stop();
    }
};
