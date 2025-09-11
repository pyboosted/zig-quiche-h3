const std = @import("std");
const quiche = @import("quiche");
const connection = @import("connection");
const config_mod = @import("config");
const EventLoop = @import("event_loop").EventLoop;
const udp = @import("udp");
const h3 = @import("h3");
const h3_datagram = @import("h3").datagram;
const http = @import("http");

const c = quiche.c;
const posix = std.posix;

// Debug logging state
var debug_counter = std.atomic.Value(u32).init(0);

fn debugLog(line: [*c]const u8, argp: ?*anyopaque) callconv(.c) void {
    const count = debug_counter.fetchAdd(1, .monotonic);
    const cfg = @as(*const config_mod.ServerConfig, @ptrCast(@alignCast(argp orelse return)));
    // debug_log_throttle is validated to be > 0 in config.validate()
    if (count % cfg.debug_log_throttle == 0) {
        std.debug.print("[QUICHE] {s}\n", .{line});
    }
}

fn appDebug(self: *const QuicServer) bool {
    return self.config.enable_debug_logging;
}

fn debugPrint(self: *const QuicServer, comptime fmt: []const u8, args: anytype) void {
    if (self.config.enable_debug_logging) {
        std.debug.print(fmt, args);
    }
}

// Request state for streaming bodies
const RequestState = struct {
    arena: std.heap.ArenaAllocator,
    request: http.Request,
    response: http.Response,
    handler: http.Handler,
    body_complete: bool = false,
    handler_invoked: bool = false, // Track if handler was already called
    is_streaming: bool = false,

    // User data for streaming handlers to store context
    user_data: ?*anyopaque = null,

    // Push-mode streaming callbacks (include Response pointer for bidirectional streaming)
    on_headers: ?*const fn (req: *http.Request, res: *http.Response) anyerror!void = null,
    on_body_chunk: ?*const fn (req: *http.Request, res: *http.Response, chunk: []const u8) anyerror!void = null,
    on_body_complete: ?*const fn (req: *http.Request, res: *http.Response) anyerror!void = null,
    
    // H3 DATAGRAM callback for request-associated datagrams
    on_h3_dgram: ?*const fn (req: *http.Request, res: *http.Response, payload: []const u8) anyerror!void = null,
};

pub const OnDatagram = *const fn (server: *QuicServer, conn: *connection.Connection, payload: []const u8, user: ?*anyopaque) anyerror!void;

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
    timeout_timer_started: bool = false, // Track if periodic timer for checking connection timeouts is started

    // HTTP/3 configuration
    h3_config: ?h3.H3Config = null,

    // HTTP routing
    router: http.Router,
    // Track per-connection stream state using a composite key so
    // simultaneous connections with the same stream_id (e.g., 0)
    // don't collide.
    stream_states: std.hash_map.HashMap(StreamKey, *RequestState, StreamKeyContext, 80),
    
    // H3 DATAGRAM flow_id mapping (flow_id -> RequestState for active requests)
    h3_dgram_flows: std.hash_map.HashMap(FlowKey, *RequestState, FlowKeyContext, 80),

    // Statistics
    connections_accepted: usize = 0,
    packets_received: usize = 0,
    packets_sent: usize = 0,
    dgrams_received: usize = 0,
    dgrams_sent: usize = 0,
    dgrams_dropped_send: usize = 0,
    
    // H3 DATAGRAM statistics
    h3_dgrams_received: usize = 0,
    h3_dgrams_sent: usize = 0,
    h3_dgrams_unknown_flow: usize = 0,
    h3_dgrams_would_block: usize = 0,

    on_datagram: ?OnDatagram = null,
    on_datagram_user: ?*anyopaque = null,

    // Type definitions for stream state tracking
    const StreamKey = struct { conn: *connection.Connection, stream_id: u64 };
    const StreamKeyContext = struct {
        pub fn hash(_: StreamKeyContext, key: StreamKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&key.conn));
            h.update(std.mem.asBytes(&key.stream_id));
            return h.final();
        }
        pub fn eql(_: StreamKeyContext, a: StreamKey, b: StreamKey) bool {
            return a.conn == b.conn and a.stream_id == b.stream_id;
        }
    };
    
    // Type definitions for H3 DATAGRAM flow_id tracking
    const FlowKey = struct { conn: *connection.Connection, flow_id: u64 };
    const FlowKeyContext = struct {
        pub fn hash(_: FlowKeyContext, key: FlowKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&key.conn));
            h.update(std.mem.asBytes(&key.flow_id));
            return h.final();
        }
        pub fn eql(_: FlowKeyContext, a: FlowKey, b: FlowKey) bool {
            return a.conn == b.conn and a.flow_id == b.flow_id;
        }
    };

    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.ServerConfig) !*QuicServer {
        // Validate config
        try cfg.validate();

        // Create qlog directory if needed
        try cfg.ensureQlogDir();

        // Create quiche config
        var q_cfg = try quiche.Config.new(quiche.PROTOCOL_VERSION);
        errdefer q_cfg.deinit();

        // Load TLS certificates
        const cert_path = try allocator.dupeZ(u8, cfg.cert_path);
        defer allocator.free(cert_path);
        const key_path = try allocator.dupeZ(u8, cfg.key_path);
        defer allocator.free(key_path);

        try q_cfg.loadCertChainFromPemFile(cert_path);
        try q_cfg.loadPrivKeyFromPemFile(key_path);

        // Set ALPN protocols with proper wire format
        const alpn_wire = try quiche.encodeAlpn(allocator, cfg.alpn_protocols);
        defer allocator.free(alpn_wire);
        try q_cfg.setApplicationProtos(alpn_wire);

        // Configure transport parameters
        q_cfg.setMaxIdleTimeout(cfg.idle_timeout_ms);
        q_cfg.setInitialMaxData(cfg.initial_max_data);
        q_cfg.setInitialMaxStreamDataBidiLocal(cfg.initial_max_stream_data_bidi_local);
        q_cfg.setInitialMaxStreamDataBidiRemote(cfg.initial_max_stream_data_bidi_remote);
        q_cfg.setInitialMaxStreamDataUni(cfg.initial_max_stream_data_uni);
        q_cfg.setInitialMaxStreamsBidi(cfg.initial_max_streams_bidi);
        q_cfg.setInitialMaxStreamsUni(cfg.initial_max_streams_uni);
        q_cfg.setMaxRecvUdpPayloadSize(cfg.max_recv_udp_payload_size);
        q_cfg.setMaxSendUdpPayloadSize(cfg.max_send_udp_payload_size);

        // Features
        q_cfg.setDisableActiveMigration(cfg.disable_active_migration);
        q_cfg.enablePacing(cfg.enable_pacing);
        q_cfg.enableDgram(cfg.enable_dgram, cfg.dgram_recv_queue_len, cfg.dgram_send_queue_len);
        q_cfg.grease(cfg.grease);

        // Set congestion control
        const cc_algo = try allocator.dupeZ(u8, cfg.cc_algorithm);
        defer allocator.free(cc_algo);
        if (q_cfg.setCcAlgorithmName(cc_algo)) |_| {
            // ok
        } else |err| {
            std.debug.print("cc={s} unsupported ({any}); falling back to cubic\n", .{ cfg.cc_algorithm, err });
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

        server.* = .{
            .allocator = allocator,
            .config = cfg,
            .quiche_config = q_cfg,
            .connections = connection.ConnectionTable.init(allocator),
            .event_loop = loop,
            .conn_id_seed = conn_id_seed,
            .router = http.Router.init(allocator),
            .stream_states = std.hash_map.HashMap(StreamKey, *RequestState, StreamKeyContext, 80).init(allocator),
            .h3_dgram_flows = std.hash_map.HashMap(FlowKey, *RequestState, FlowKeyContext, 80).init(allocator),
        };

        // Create H3 config
        server.h3_config = try h3.H3Config.initWithDefaults();
        errdefer if (server.h3_config) |*h| h.deinit();

        // Enable debug logging if requested
        if (cfg.enable_debug_logging) {
            try quiche.enableDebugLogging(debugLog, &server.config);
        }

        return server;
    }

    pub fn deinit(self: *QuicServer) void {
        self.stop();

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
        self.h3_dgram_flows.deinit();

        // Clean up router
        self.router.deinit();

        if (self.h3_config) |*h| h.deinit();
        self.quiche_config.deinit();
        self.event_loop.deinit();
        if (self.socket_v4) |*s| s.*.close();
        if (self.socket_v6) |*s| s.*.close();
        self.allocator.destroy(self);
    }

    /// Register a QUIC DATAGRAM handler
    pub fn onDatagram(self: *QuicServer, cb: OnDatagram, user: ?*anyopaque) void {
        self.on_datagram = cb;
        self.on_datagram_user = user;
    }

    /// Send a QUIC DATAGRAM on a connection, tracking counters
    pub fn sendDatagram(self: *QuicServer, conn: *connection.Connection, data: []const u8) !void {
        // Respect max writable length when available
        if (conn.conn.dgramMaxWritableLen()) |maxw| {
            if (data.len > maxw) return error.DatagramTooLarge;
        }
        _ = conn.conn.dgramSend(data) catch |err| {
            if (err == error.Done) {
                // Treat as transient backpressure
                self.dgrams_dropped_send += 1;
                return error.WouldBlock;
            }
            return err;
        };
        self.dgrams_sent += 1;
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

        // Start periodic timer for checking connection timeouts (50ms interval)
        try self.event_loop.addTimer(0.05, 0.05, onTimeoutTimer, self);
        self.timeout_timer_started = true;
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

    /// Register a route with the HTTP router
    pub fn route(self: *QuicServer, method: http.Method, pattern: []const u8, handler: http.Handler) !void {
        try self.router.route(method, pattern, handler);
    }

    /// Register a streaming route with push-mode callbacks
    pub fn routeStreaming(
        self: *QuicServer,
        method: http.Method,
        pattern: []const u8,
        callbacks: struct {
            on_headers: ?http.OnHeaders = null,
            on_body_chunk: ?http.OnBodyChunk = null,
            on_body_complete: ?http.OnBodyComplete = null,
        },
    ) !void {
        try self.router.routeStreaming(method, pattern, .{
            .on_headers = callbacks.on_headers,
            .on_body_chunk = callbacks.on_body_chunk,
            .on_body_complete = callbacks.on_body_complete,
        });
    }

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
                    if (touched[t] == conn.?) { seen = true; break; }
                }
                if (!seen) { touched[touched_len] = conn.?; touched_len += 1; }
            }
            }

            // After processing the batch, walk touched connections once
            var k: usize = 0;
            while (k < touched_len) : (k += 1) {
                const cconn = touched[k];
                if (cconn.http3 != null) {
                    self.processH3(cconn) catch |err| {
                        if (err != quiche.h3.Error.StreamBlocked) {
                            std.debug.print("H3 processing error: {}\n", .{err});
                        }
                    };
                }
                // Drain any QUIC DATAGRAMs
                self.processDatagrams(cconn) catch |err| {
                    std.debug.print("Error processing datagrams: {}\n", .{err});
                };
                self.processWritableStreams(cconn) catch |err| {
                    std.debug.print("Error processing writable streams: {}\n", .{err});
                };
                try self.drainEgress(cconn);
                const timeout_ms2 = cconn.conn.timeoutAsMillis();
                try self.updateTimer(cconn, timeout_ms2);
                if (cconn.conn.isClosed()) {
                    self.closeConnection(cconn);
                }
            }
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

    fn drainEgress(self: *QuicServer, conn: *connection.Connection) !void {
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

    fn processH3(self: *QuicServer, conn: *connection.Connection) !void {
        const h3_ptr = conn.http3 orelse return;
        const h3_conn = @as(*h3.H3Connection, @ptrCast(@alignCast(h3_ptr)));

        while (true) {
            var result = h3_conn.poll(&conn.conn) orelse break;
            defer result.deinit();

            switch (result.event_type) {
                .Headers => {
                    // Create request state with arena first
                    const state = try self.allocator.create(RequestState);
                    state.* = .{
                        .arena = std.heap.ArenaAllocator.init(self.allocator),
                        .request = undefined,
                        .response = undefined,
                        .handler = undefined,
                        .body_complete = false,
                        .handler_invoked = false,
                    };
                    errdefer {
                        state.arena.deinit();
                        self.allocator.destroy(state);
                    }

                    // Collect headers using arena allocator
                    const arena_allocator = state.arena.allocator();
                    const headers = try h3.collectHeaders(arena_allocator, result.raw_event);
                    // No defer free - arena will handle it

                    // Parse request info
                    const req_info = h3.parseRequestHeaders(headers);

                    // Validate required pseudo-headers
                    if (req_info.method == null or req_info.path == null) {
                        // Send 400 Bad Request
                        try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 400);
                        state.arena.deinit();
                        self.allocator.destroy(state);
                        continue;
                    }

                    const method_str = req_info.method.?;
                    const path_raw = req_info.path.?;

                    std.debug.print("→ HTTP/3 request: {s} {s}\n", .{ method_str, path_raw });

                    // Parse method
                    const method = http.Method.fromString(method_str) orelse {
                        // Unknown method
                        try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 405);
                        state.arena.deinit();
                        self.allocator.destroy(state);
                        continue;
                    };

                    // Convert headers to our format - reuse arena-allocated headers
                    const req_headers = try arena_allocator.alloc(http.Header, headers.len);
                    for (headers, 0..) |h, i| {
                        // Headers are already arena-allocated from collectHeaders, just reference them
                        req_headers[i] = .{
                            .name = h.name,
                            .value = h.value,
                        };
                    }

                    // Initialize request
                    state.request = try http.Request.init(
                        &state.arena,
                        method,
                        path_raw,
                        req_info.authority,
                        req_headers,
                        result.stream_id,
                    );

                    // Link request's user_data to state's user_data for streaming handlers
                    state.request.user_data = state.user_data;

                    // Match route
                    const match_result = try self.router.match(
                        arena_allocator,
                        method,
                        state.request.path_decoded,
                    );

                    switch (match_result) {
                        .Found => |found| {
                            // Store extracted params
                            state.request.params = found.params;
                            // Copy handler or streaming callbacks from route
                            if (found.route.is_streaming) {
                                state.is_streaming = true;
                                state.handler = undefined; // Won't be used
                                state.on_headers = found.route.on_headers;
                                state.on_body_chunk = found.route.on_body_chunk;
                                state.on_body_complete = found.route.on_body_complete;
                            } else {
                                state.handler = found.route.handler;
                            }
                            
                            // Copy H3 DATAGRAM callback if present
                            state.on_h3_dgram = found.route.on_h3_dgram;

                            // Initialize response
                            state.response = http.Response.init(
                                state.arena.allocator(),
                                h3_conn,
                                &conn.conn,
                                result.stream_id,
                                method == .HEAD,
                            );
                            
                            // H3 DATAGRAM sent counter is available via incrementH3DatagramSent() for applications that need tracking

                            // Store state (keyed by connection + stream id)
                            try self.stream_states.put(.{ .conn = conn, .stream_id = result.stream_id }, state);
                            
                            // If route has H3 DATAGRAM callback, create flow_id mapping
                            if (state.on_h3_dgram != null) {
                                // Derive flow_id similar to quiche's driver behavior
                                // Default mapping: flow_id == stream_id (simple GET demo)
                                var flow_id: u64 = h3_datagram.flowIdForStream(result.stream_id);

                                // RFC 9298 CONNECT-UDP over CONNECT with :protocol → use quarter_stream_id
                                if (method == .CONNECT) {
                                    if (state.request.h3Protocol() != null) {
                                        flow_id = result.stream_id / 4;
                                    }
                                }

                                // Draft CONNECT-UDP method with datagram-flow-id header
                                if (method == .CONNECT_UDP) {
                                    if (state.request.datagramFlowId()) |v| {
                                        flow_id = v;
                                    }
                                }

                                // Persist on response so sends use the correct flow_id
                                state.response.h3_flow_id = flow_id;

                                self.debugPrint("[DEBUG] Creating H3 DATAGRAM flow mapping: conn={*}, stream_id={}, flow_id={}, route={s}\n", 
                                    .{conn, result.stream_id, flow_id, found.route.raw_pattern});
                                try self.h3_dgram_flows.put(.{ .conn = conn, .flow_id = flow_id }, state);
                                self.debugPrint("[DEBUG] Flow mapping created successfully\n", .{});
                            }

                            // Handle immediate invocation based on route type
                            if (state.is_streaming) {
                                // For streaming routes, call on_headers immediately if present
                                if (state.on_headers) |on_headers| {
                                    on_headers(&state.request, &state.response) catch |err| {
                                        // StreamBlocked is non-fatal
                                        if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked) {
                                            return;
                                        }
                                        std.debug.print("onHeaders error: {}\n", .{err});
                                        self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                    };
                                    // Sync user_data back to state after callback
                                    state.user_data = state.request.user_data;
                                }
                                // For methods with body, wait for Data events to call on_body_chunk
                            } else {
                                // Regular handler: invoke immediately for methods without body
                                if (method == .GET or method == .HEAD or method == .DELETE) {
                                    self.invokeHandler(state) catch |err| {
                                        // Backpressure-like conditions are non-fatal
                                        if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                                            // Keep state alive for processWritableStreams to resume
                                            return;
                                        }
                                        // For other errors, send error response
                                        std.debug.print("Handler error: {}\n", .{err});
                                        self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                    };
                                }
                                // For methods with body, wait for Data events
                            }
                        },
                        .NotFound => {
                            try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 404);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                        },
                        .MethodNotAllowed => |not_allowed| {
                            const allow = try http.Router.formatAllowHeader(
                                self.allocator,
                                not_allowed.allowed_methods,
                            );
                            defer self.allocator.free(allow);
                            // Don't free allowed_methods - arena will handle it

                            try self.sendErrorResponseWithAllow(h3_conn, &conn.conn, result.stream_id, 405, allow);
                            state.arena.deinit();
                            self.allocator.destroy(state);
                        },
                    }

                    // Note: Body data (if any) will arrive in subsequent Data events
                },
                .Data => {
                    // Handle body data (drain all available data for this event)
                    if (self.stream_states.get(.{ .conn = conn, .stream_id = result.stream_id })) |state| {
                        var buf: [64 * 1024]u8 = undefined;
                        while (true) {
                            const received = h3_conn.recvBody(&conn.conn, result.stream_id, &buf) catch |err| {
                                if (err == quiche.h3.Error.Done) break; // no more data now
                                // Unexpected error while reading body
                                std.debug.print("recvBody error on stream {}: {}\n", .{ result.stream_id, err });
                                break;
                            };

                            if (received == 0) break;

                            // Check if we're in streaming mode
                            if (state.on_body_chunk) |on_chunk| {
                                // Push-mode: call the streaming callback
                                const new_total = state.request.getBodySize() + received;
                                if (new_total > self.config.max_request_body_size) {
                                    try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 413);
                                    // Clean up state
                                    self.cleanupStreamState(conn, result.stream_id, state);
                                    return;
                                }

                                // Update body size for tracking
                                state.request.addToBodySize(received);

                                // Call the chunk callback with response
                                on_chunk(&state.request, &state.response, buf[0..received]) catch |err| {
                                    if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                                        // Non-fatal backpressure; keep state
                                        return;
                                    }
                                    const status = http.errorToStatus(err);
                                    try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, status);
                                    self.cleanupStreamState(conn, result.stream_id, state);
                                    return;
                                };
                            } else {
                                // Buffering mode: add to body buffer (with size limit)
                                state.request.appendBody(buf[0..received], self.config.max_request_body_size) catch |err| {
                                    if (err == error.PayloadTooLarge) {
                                        try self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, 413);
                                        self.cleanupStreamState(conn, result.stream_id, state);
                                        return;
                                    }
                                };
                            }
                        }
                    }
                },
                .Finished => {
                    std.debug.print("  Stream {} finished\n", .{result.stream_id});

                    // If we have state and haven't invoked handler yet, do it now
                    if (self.stream_states.get(.{ .conn = conn, .stream_id = result.stream_id })) |state| {
                        if (!state.body_complete) {
                            state.body_complete = true;
                            state.request.setBodyComplete();

                            // Check if we're in streaming mode with completion callback
                            if (state.on_body_complete) |on_complete| {
                                // Call the completion callback with response
                                on_complete(&state.request, &state.response) catch |err| {
                                    // Backpressure-like conditions are non-fatal
                                    if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                                        // Keep state alive for processWritableStreams
                                        return;
                                    }
                                    std.debug.print("onBodyComplete error: {}\n", .{err});
                                    self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                };
                                // Don't invoke the regular handler - streaming mode handles its own response
                            } else {
                                // Buffering mode: invoke handler with complete body
                                self.invokeHandler(state) catch |err| {
                                    // Backpressure-like conditions are non-fatal - handler started streaming response
                                    if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                                        // Keep state alive for processWritableStreams to resume
                                        return;
                                    }
                                    // For other errors, send error response
                                    std.debug.print("Handler error: {}\n", .{err});
                                    self.sendErrorResponse(h3_conn, &conn.conn, result.stream_id, http.errorToStatus(err)) catch {};
                                };
                            }
                        }

                        // Only clean up if response is truly complete
                        if (state.response.isEnded() and state.response.partial_response == null) {
                            // Response is complete, safe to clean up
                            self.cleanupStreamState(conn, result.stream_id, state);
                        } else {
                            // Keep state alive for processWritableStreams to finish
                            std.debug.print("  Keeping stream {} alive for ongoing response\n", .{result.stream_id});
                        }
                    }
                },
                .GoAway, .Reset => {
                    std.debug.print("  Stream {} closed ({})\n", .{ result.stream_id, result.event_type });

                    // Clean up state if exists (also purge H3 DATAGRAM flow mapping)
                    if (self.stream_states.fetchRemove(.{ .conn = conn, .stream_id = result.stream_id })) |entry| {
                        self.cleanupStreamState(conn, result.stream_id, entry.value);
                    }
                },
                .PriorityUpdate => {
                    // Log for telemetry
                },
            }
        }
    }

    fn invokeHandler(self: *QuicServer, state: *RequestState) !void {
        _ = self;
        // Prevent double invocation
        if (state.handler_invoked) {
            return;
        }
        state.handler_invoked = true;

        // Call the handler and handle backpressure errors specially
        state.handler(&state.request, &state.response) catch |err| {
            // Backpressure-like conditions are non-fatal - the handler is trying to send
            // a large response and hit flow control. Keep the state alive so
            // processWritableStreams can resume the send later.
            if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                // Don't send error response or end the stream
                // The partial response will be resumed by processWritableStreams
                return;
            }
            // For other errors, propagate them normally
            return err;
        };

        // Only auto-end the response if there's no partial response pending
        // If there is a partial response, let processWritableStreams handle completion
        if (!state.response.isEnded() and state.response.partial_response == null) {
            try state.response.end(null);
        }
    }

    fn processWritableStreams(self: *QuicServer, conn: *connection.Connection) !void {
        // Process all writable streams
        while (conn.conn.streamWritableNext()) |stream_id| {
            // Check if this stream has a partial response waiting
            if (self.stream_states.get(.{ .conn = conn, .stream_id = stream_id })) |state| {
                if (state.response.partial_response != null) {
                    // Try to resume sending the partial response
                    state.response.processPartialResponse() catch |err| {
                        if (err == error.StreamBlocked or err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                            // Stream is blocked again, will retry later
                            continue;
                        }
                        // For other errors, clean up the stream state
                        std.debug.print("Error processing partial response for stream {}: {}\n", .{ stream_id, err });
                        // Remove from H3 DATAGRAM flow mapping if present
                        if (state.on_h3_dgram != null) {
                            const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(stream_id);
                            _ = self.h3_dgram_flows.remove(.{ .conn = conn, .flow_id = flow_id });
                        }
                        
                        state.response.deinit();
                        state.arena.deinit();
                        self.allocator.destroy(state);
                        _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });
                    };

                    // If response is complete, clean up
                    if (state.response.isEnded() and state.response.partial_response == null) {
                        // Remove from H3 DATAGRAM flow mapping if present
                        if (state.on_h3_dgram != null) {
                            const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(stream_id);
                            _ = self.h3_dgram_flows.remove(.{ .conn = conn, .flow_id = flow_id });
                        }
                        
                        state.response.deinit();
                        state.arena.deinit();
                        self.allocator.destroy(state);
                        _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });
                    }
                }
            }
        }

        // Drain egress after processing writable streams
        try self.drainEgress(conn);

        // Refresh the connection's idle timeout based on quiche's timer.
        // Large transfers that progress via send-only paths (writable hints)
        // must still bump the deadline, otherwise the periodic timer may
        // close the connection around the idle_timeout_ms boundary.
        const timeout_ms = conn.conn.timeoutAsMillis();
        try self.updateTimer(conn, timeout_ms);
    }

    fn sendErrorResponse(
        self: *QuicServer,
        h3_conn: *h3.H3Connection,
        quic_conn: *quiche.Connection,
        stream_id: u64,
        status_code: u16,
    ) !void {
        _ = self;
        var status_buf: [4]u8 = undefined;
        const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{status_code});

        const headers = [_]quiche.h3.Header{
            .{ .name = ":status", .name_len = 7, .value = status_str.ptr, .value_len = status_str.len },
            .{ .name = "content-length", .name_len = 14, .value = "0", .value_len = 1 },
        };

        try h3_conn.sendResponse(quic_conn, stream_id, headers[0..], true);
    }

    fn sendErrorResponseWithAllow(
        self: *QuicServer,
        h3_conn: *h3.H3Connection,
        quic_conn: *quiche.Connection,
        stream_id: u64,
        status_code: u16,
        allow: []const u8,
    ) !void {
        _ = self;
        var status_buf: [4]u8 = undefined;
        const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{status_code});

        const headers = [_]quiche.h3.Header{
            .{ .name = ":status", .name_len = 7, .value = status_str.ptr, .value_len = status_str.len },
            .{ .name = "allow", .name_len = 5, .value = allow.ptr, .value_len = allow.len },
            .{ .name = "content-length", .name_len = 14, .value = "0", .value_len = 1 },
        };

        try h3_conn.sendResponse(quic_conn, stream_id, headers[0..], true);
    }

    fn updateTimer(self: *QuicServer, conn: *connection.Connection, timeout_ms: u64) !void {
        _ = self;
        // Track the deadline for when this connection should timeout
        const now = std.time.milliTimestamp();

        // Handle special case where timeout_ms is maxInt or very large (no timeout or error)
        // This can happen when connections have errors like UnknownVersion
        // quiche's timeout_as_millis() returns u64::MAX when there's no timeout needed
        // or when the connection is in an error state. We cap at 1 hour to prevent overflow
        // and ensure connections don't hang indefinitely. This is fine for M2; later versions
        // can implement more sophisticated timeout handling based on connection state.
        if (timeout_ms >= std.math.maxInt(i64) or timeout_ms > 3_600_000) {
            // Set deadline far in the future (1 hour from now)
            conn.timeout_deadline_ms = now + 3_600_000;
            return;
        }

        // Now we know timeout_ms fits in i64, cast safely
        const timeout_i64: i64 = @intCast(timeout_ms);
        conn.timeout_deadline_ms = now +% timeout_i64; // Use wrapping add for safety
    }

    fn checkTimeouts(self: *QuicServer) !void {
        const now = std.time.milliTimestamp();

        // Collect connections that have timed out
        var timed_out = std.ArrayList(*connection.Connection){};
        defer timed_out.deinit(self.allocator);

        var iter = self.connections.map.iterator();
        while (iter.next()) |entry| {
            const conn = entry.value_ptr.*;

            // Process H3 events if H3 connection exists (periodic processing)
            if (conn.http3 != null) {
                self.processH3(conn) catch |err| {
                    if (err != quiche.h3.Error.StreamBlocked) {
                        std.debug.print("H3 processing error in timer: {}\n", .{err});
                    }
                };

                // Periodically check for writable streams (retry blocked sends)
                self.processWritableStreams(conn) catch |err| {
                    std.debug.print("Error processing writable streams in timer: {}\n", .{err});
                };

                // Also check for pending DATAGRAMs
                self.processDatagrams(conn) catch |err| {
                    std.debug.print("Error processing datagrams in timer: {}\n", .{err});
                };
            }

            // Check if this connection has timed out
            if (conn.timeout_deadline_ms <= now) {
                try timed_out.append(self.allocator, conn);
            }
        }

        // Process timeouts for collected connections
        for (timed_out.items) |conn| {
            self.onTimeout(conn);
        }
    }

    fn processDatagrams(self: *QuicServer, conn: *connection.Connection) !void {
        // Try to read all pending datagrams
        var small_buf: [2048]u8 = undefined;
        
        while (true) {
            // Optional size hint
            const hint = conn.conn.dgramRecvFrontLen();
            var use_heap = false;
            var buf: []u8 = small_buf[0..];
            if (hint) |h| {
                if (h > small_buf.len) {
                    buf = try self.allocator.alloc(u8, h);
                    use_heap = true;
                } else {
                    buf = small_buf[0..h];
                }
            }

            const read = conn.conn.dgramRecv(buf) catch |err| {
                if (use_heap) self.allocator.free(buf);
                if (err == error.Done) {
                    return; // no more
                }
                self.debugPrint("[DEBUG] dgramRecv error: {}\n", .{err});
                return err;
            };

            const payload = buf[0..read];
            self.dgrams_received += 1;
            // Basic log for debugging/tests
            if (self.appDebug()) {
                std.debug.print("[DEBUG] DATAGRAM recv len={d}, first bytes: ", .{payload.len});
                for (payload[0..@min(16, payload.len)]) |b| {
                    std.debug.print("{x:0>2} ", .{b});
                }
                std.debug.print("\n", .{});
            }

            // Try H3 DATAGRAM first if H3 connection exists and H3 DATAGRAMs are enabled
            var handled_as_h3 = false;
            if (conn.http3) |h3_ptr| {
                const h3_conn = @as(*h3.H3Connection, @ptrCast(@alignCast(h3_ptr)));
                const h3_enabled = h3_conn.dgramEnabledByPeer(&conn.conn);
                self.debugPrint("[DEBUG] H3 connection exists, dgramEnabledByPeer={}\n", .{h3_enabled});
                
                if (h3_enabled) {
                    handled_as_h3 = self.processH3Datagram(conn, payload) catch |err| blk: {
                        // On parse error, fall back to QUIC DATAGRAM (configurable behavior)
                        self.debugPrint("[DEBUG] H3 DATAGRAM parse error: {}, falling back to QUIC\n", .{err});
                        break :blk false;
                    };
                    self.debugPrint("[DEBUG] Handled as H3 DATAGRAM: {}\n", .{handled_as_h3});
                }
            } else {
                self.debugPrint("[DEBUG] No H3 connection for this QUIC connection\n", .{});
            }

            // Fall back to QUIC DATAGRAM callback if not handled as H3 DATAGRAM
            if (!handled_as_h3 and self.on_datagram != null) {
                if (self.on_datagram) |cb| {
                    cb(self, conn, payload, self.on_datagram_user) catch |e| {
                        std.debug.print("onDatagram error: {}\n", .{e});
                    };
                }
            }

            if (use_heap) self.allocator.free(buf);
        }
    }
    
    /// Process H3 DATAGRAM payload (with varint flow_id prefix)
    /// Returns true if successfully handled as H3 DATAGRAM, false if should fall back to QUIC
    fn processH3Datagram(self: *QuicServer, conn: *connection.Connection, payload: []const u8) !bool {
        self.debugPrint("[DEBUG] processH3Datagram: attempting to decode varint from {} bytes\n", .{payload.len});
        
        // Decode varint flow_id from the payload
        const varint_result = h3_datagram.decodeVarint(payload) catch |err| {
            // Invalid varint format - not an H3 DATAGRAM
            self.debugPrint("[DEBUG] Failed to decode varint: {}\n", .{err});
            return false;
        };
        
        const flow_id = varint_result.value;
        const payload_offset = varint_result.consumed;
        self.debugPrint("[DEBUG] Decoded flow_id={}, consumed {} bytes\n", .{flow_id, payload_offset});
        
        if (payload_offset >= payload.len) {
            // No payload after flow_id
            self.debugPrint("[DEBUG] Empty H3 DATAGRAM payload after flow_id\n", .{});
            self.h3_dgrams_received += 1; // Count it but don't process empty payload
            return true;
        }
        
        const h3_payload = payload[payload_offset..];
        self.debugPrint("[DEBUG] H3 DATAGRAM payload size: {} bytes\n", .{h3_payload.len});
        
        // Look up the request state for this flow_id
        const flow_key = FlowKey{ .conn = conn, .flow_id = flow_id };
        self.debugPrint("[DEBUG] Looking up flow_key: conn={*}, flow_id={}\n", .{conn, flow_id});
        
        if (self.h3_dgram_flows.get(flow_key)) |state| {
            self.debugPrint("[DEBUG] Found flow mapping for flow_id={}\n", .{flow_id});
            self.h3_dgrams_received += 1;
            
            if (state.on_h3_dgram) |callback| {
                // Debug log for H3 DATAGRAM
                self.debugPrint("[DEBUG] H3 DGRAM recv flow={d} len={d}, invoking callback\n", .{ flow_id, h3_payload.len });
                
                // Invoke the H3 DATAGRAM callback
                callback(&state.request, &state.response, h3_payload) catch |err| {
                    // Count would_block errors for H3 DATAGRAM sends  
                    if (err == error.WouldBlock) {
                        self.h3_dgrams_would_block += 1;
                        self.debugPrint("[DEBUG] H3 DATAGRAM callback returned WouldBlock\n", .{});
                    } else {
                        self.debugPrint("[DEBUG] H3 DATAGRAM callback error: {}\n", .{err});
                    }
                    // Don't propagate callback errors - continue processing
                };
                self.debugPrint("[DEBUG] H3 DATAGRAM callback completed\n", .{});
            } else {
                // Route matched but no H3 DATAGRAM callback registered
                self.debugPrint("[DEBUG] H3 DGRAM recv flow={d} len={d} - no callback registered\n", .{ flow_id, h3_payload.len });
            }
            
            return true;
        } else {
            // Unknown flow_id - drop and count
            self.h3_dgrams_unknown_flow += 1;
            self.debugPrint("[DEBUG] H3 DGRAM recv unknown flow_id={d} len={d} - dropped\n", .{ flow_id, h3_payload.len });
            
            // Debug: print all registered flow_ids for this connection
            if (self.appDebug()) {
                std.debug.print("[DEBUG] Registered flow_ids for conn={*}:\n", .{conn});
                var it = self.h3_dgram_flows.iterator();
                while (it.next()) |entry| {
                    if (entry.key_ptr.conn == conn) {
                        std.debug.print("[DEBUG]   flow_id={}\n", .{entry.key_ptr.flow_id});
                    }
                }
            }
            
            return true; // Still handled as H3 DATAGRAM (just dropped)
        }
    }

    /// Helper function to clean up both stream state and flow_id mapping
    fn cleanupStreamState(self: *QuicServer, conn: *connection.Connection, stream_id: u64, state: *RequestState) void {
        // Remove from stream states
        _ = self.stream_states.remove(.{ .conn = conn, .stream_id = stream_id });

        // Also remove H3 DATAGRAM flow mapping if present for this request
        if (state.on_h3_dgram != null) {
            const flow_id = state.response.h3_flow_id orelse h3_datagram.flowIdForStream(stream_id);
            _ = self.h3_dgram_flows.remove(.{ .conn = conn, .flow_id = flow_id });
        }
        
        // Clean up state memory
        state.response.deinit();
        state.arena.deinit();
        self.allocator.destroy(state);
    }

    // ------------------------ Tests ------------------------
    test "cleanup removes stream state and H3 DATAGRAM flow mapping" {
        const allocator = std.testing.allocator;

        // Prepare a minimal server instance with just the fields we need
        var server: QuicServer = undefined;
        server.allocator = allocator;
        server.stream_states = std.hash_map.HashMap(StreamKey, *RequestState, StreamKeyContext, 80).init(allocator);
        server.h3_dgram_flows = std.hash_map.HashMap(FlowKey, *RequestState, FlowKeyContext, 80).init(allocator);

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
        try server.h3_dgram_flows.put(.{ .conn = conn_ptr, .flow_id = flow_id }, state);

        // Sanity: entries exist
        try std.testing.expect(server.stream_states.get(.{ .conn = conn_ptr, .stream_id = test_stream_id }) != null);
        try std.testing.expect(server.h3_dgram_flows.get(.{ .conn = conn_ptr, .flow_id = flow_id }) != null);

        // Act: cleanup
        server.cleanupStreamState(conn_ptr, test_stream_id, state);

        // Verify: both entries are removed
        try std.testing.expect(server.stream_states.get(.{ .conn = conn_ptr, .stream_id = test_stream_id }) == null);
        try std.testing.expect(server.h3_dgram_flows.get(.{ .conn = conn_ptr, .flow_id = flow_id }) == null);

        // Deinit maps
        server.stream_states.deinit();
        server.h3_dgram_flows.deinit();
    }

    /// Increment H3 DATAGRAM sent counter (for use by callbacks)
    pub fn incrementH3DatagramSent(self: *QuicServer) void {
        self.h3_dgrams_sent += 1;
    }

    fn onTimeout(self: *QuicServer, conn: *connection.Connection) void {
        conn.conn.onTimeout();

        // Drain egress after timeout using the connection's socket
        self.drainEgress(conn) catch {};

        if (conn.conn.isClosed()) {
            self.closeConnection(conn);
        }
    }

    fn closeConnection(self: *QuicServer, conn: *connection.Connection) void {
        // Clean up any pending stream states for this connection first
        var to_remove = std.ArrayList(StreamKey){};
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
                self.cleanupStreamState(conn, k.stream_id, kv.value);
            }
        }

        // Purge any remaining H3 DATAGRAM flow mappings for this connection
        {
            var it2 = self.h3_dgram_flows.iterator();
            var flow_keys_to_remove = std.ArrayList(FlowKey){};
            defer flow_keys_to_remove.deinit(self.allocator);
            while (it2.next()) |entry| {
                const fk = entry.key_ptr.*;
                if (fk.conn == conn) {
                    flow_keys_to_remove.append(self.allocator, fk) catch {};
                }
            }
            for (flow_keys_to_remove.items) |fk| {
                _ = self.h3_dgram_flows.remove(fk);
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

        self.stop();
    }
};
