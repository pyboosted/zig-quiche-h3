const std = @import("std");
const quiche = @import("quiche");
const connection = @import("connection");
const config_mod = @import("config");
const EventLoop = @import("event_loop").EventLoop;
const udp = @import("udp");
const h3 = @import("h3");

const c = quiche.c;
const posix = std.posix;

// Debug logging state
var debug_counter = std.atomic.Value(u32).init(0);

fn debugLog(line: [*c]const u8, argp: ?*anyopaque) callconv(.c) void {
    const count = debug_counter.fetchAdd(1, .monotonic);
    const cfg = @as(*const config_mod.ServerConfig, @ptrCast(@alignCast(argp orelse return)));
    if (count % cfg.debug_log_throttle == 0) {
        std.debug.print("[QUICHE] {s}\n", .{line});
    }
}

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
    
    // Statistics
    connections_accepted: usize = 0,
    packets_received: usize = 0,
    packets_sent: usize = 0,
    
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
        try q_cfg.setCcAlgorithmName(cc_algo);
        
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
        
        if (self.h3_config) |*h| h.deinit();
        self.quiche_config.deinit();
        self.event_loop.deinit();
        if (self.socket_v4) |*s| s.*.close();
        if (self.socket_v6) |*s| s.*.close();
        self.allocator.destroy(self);
    }
    
    pub fn bind(self: *QuicServer) !void {
        // Try to bind both IPv6 and IPv4
        const sockets = udp.bindAny(self.config.bind_port, true);
        if (!sockets.hasAny()) return error.FailedToBind;
        
        if (sockets.v6) |sock| {
            self.socket_v6 = sock;
            try self.event_loop.addUdpIo(sock.fd, onUdpReadable, self);
            std.debug.print("QUIC server bound to [::]:{d}\n", .{self.config.bind_port});
        }
        
        if (sockets.v4) |sock| {
            self.socket_v4 = sock;
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
        var buf: [2048]u8 = undefined; // Good size for M2
        
        // Loop until EWOULDBLOCK
        while (true) {
            var peer_addr: posix.sockaddr.storage = undefined;
            var peer_addr_len: posix.socklen_t = @sizeOf(@TypeOf(peer_addr));
            
            const n = posix.recvfrom(fd, &buf, 0, @ptrCast(&peer_addr), &peer_addr_len) catch |err| {
                if (err == error.WouldBlock) break;
                std.debug.print("recvfrom error: {}\n", .{err});
                continue;
            };
            
            self.packets_received += 1;
            
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
                buf[0..n],
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
                    derived_conn_id,  // Use HMAC-derived ID as our SCID
                    fd,
                    buf[0..n],  // Pass the initial packet
                );
                if (conn == null) continue;
                
                // Initial packet was already processed in acceptConnection, skip to drain
                try self.drainEgress(conn.?);
                const timeout_ms = conn.?.conn.timeoutAsMillis();
                try self.updateTimer(conn.?, timeout_ms);
                continue;
            }
            
            // Get local address for recv_info.to (critical!)
            var local_addr: posix.sockaddr.storage = undefined;
            var local_addr_len: posix.socklen_t = @sizeOf(@TypeOf(local_addr));
            _ = posix.getsockname(fd, @ptrCast(&local_addr), &local_addr_len) catch {
                // Failed to get local address
                continue;
            };
            
            // Process packet with quiche
            const recv_info = c.quiche_recv_info{
                .from = @ptrCast(&peer_addr),
                .from_len = peer_addr_len,
                .to = @ptrCast(&local_addr),
                .to_len = local_addr_len,
            };
            
            _ = conn.?.conn.recv(buf[0..n], &recv_info) catch |err| {
                if (err == error.Done) {
                    // This is normal - just means no more data to process
                } else if (err != error.CryptoFail) {
                    // Log non-crypto errors (crypto errors are common during handshake)
                    std.debug.print("quiche_conn_recv failed: {}\n", .{err});
                }
                
                // ALWAYS drain egress and update timer, even on errors
                // This is critical for the handshake to progress
                try self.drainEgress(conn.?);
                
                const timeout_ms = conn.?.conn.timeoutAsMillis();
                try self.updateTimer(conn.?, timeout_ms);
                
                // Don't skip to next packet - fall through to check connection state
            };
            
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
            
            // Process H3 events if H3 connection exists
            if (conn.?.http3 != null) {
                self.processH3(conn.?) catch |err| {
                    if (err != quiche.h3.Error.StreamBlocked) {
                        std.debug.print("H3 processing error: {}\n", .{err});
                    }
                };
            }
            
            // Drain egress after recv
            try self.drainEgress(conn.?);
            
            // Update timer
            const timeout_ms = conn.?.conn.timeoutAsMillis();
            try self.updateTimer(conn.?, timeout_ms);
            
            // Check if closed
            if (conn.?.conn.isClosed()) {
                self.closeConnection(conn.?);
            }
        }
    }
    
    fn acceptConnection(
        self: *QuicServer,
        peer_addr: *const posix.sockaddr.storage,
        peer_addr_len: posix.socklen_t,
        dcid: []const u8,
        scid: [16]u8,  // Use the HMAC-derived ID as our SCID
        fd: posix.socket_t,
        initial_packet: []const u8,  // Add the initial packet to process
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
            .from = @constCast(@ptrCast(peer_addr)),
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
        var out: [2048]u8 = undefined;
        
        while (true) {
            var send_info: c.quiche_send_info = undefined;
            
            const written = conn.conn.send(&out, &send_info) catch |err| {
                if (err == error.Done) break;
                return err;
            };
            
            // Send packet to the address specified by quiche (important for path migration)
            // Use send_info.to if provided (to_len > 0), otherwise fall back to peer_addr
            const dest_addr = if (send_info.to_len > 0) @as(*const posix.sockaddr, @ptrCast(&send_info.to)) else @as(*const posix.sockaddr, @ptrCast(&conn.peer_addr));
            const dest_len = if (send_info.to_len > 0) send_info.to_len else conn.peer_addr_len;
            
            _ = posix.sendto(
                conn.socket_fd,
                out[0..written],
                0,
                dest_addr,
                dest_len,
            ) catch {
                // sendto failed, continue with next packet
                continue;
            };
            
            self.packets_sent += 1;
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
                    // Collect headers
                    const headers = try h3.collectHeaders(self.allocator, result.raw_event);
                    defer h3.freeHeaders(self.allocator, headers);
                    
                    // Parse request info
                    const req_info = h3.parseRequestHeaders(headers);
                    
                    std.debug.print("→ HTTP/3 request: {s} {s}\n", .{
                        req_info.method orelse "?",
                        req_info.path orelse "?",
                    });
                    
                    // Prepare body and compute content-length
                    const body = "Hello, HTTP/3!\n";
                    var len_buf: [20]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable;
                    
                    // Build response headers with careful lifetime management
                    const response_headers = [_]quiche.h3.Header{
                        .{ .name = ":status", .name_len = 7, .value = "200", .value_len = 3 },
                        .{ .name = "server", .name_len = 6, .value = "zig-quiche-h3", .value_len = 13 },
                        .{ .name = "content-type", .name_len = 12, .value = "text/plain", .value_len = 10 },
                        .{ .name = "content-length", .name_len = 14, .value = len_str.ptr, .value_len = len_str.len },
                    };
                    
                    // Send response (pass slice, not pointer to array)
                    try h3_conn.sendResponse(&conn.conn, result.stream_id, response_headers[0..], false);
                    
                    // Send body
                    // Note: For larger bodies in future, consider retry queue on StreamBlocked
                    _ = try h3_conn.sendBody(&conn.conn, result.stream_id, body, true);
                    
                    std.debug.print("← Sent HTTP/3 response on stream {}\n", .{result.stream_id});
                    
                    // Check if there are more frames (e.g., request body)
                    if (quiche.h3.eventHeadersHasMoreFrames(result.raw_event)) {
                        // Client is sending a body, we'll receive it in subsequent Data events
                        std.debug.print("  Request has body, will be received in Data events\n", .{});
                    }
                },
                .Data => {
                    // Drain body for M3 (ignore content)
                    var buf: [1024]u8 = undefined;
                    _ = h3_conn.recvBody(&conn.conn, result.stream_id, &buf) catch 0;
                },
                .Finished => {
                    std.debug.print("  Stream {} finished\n", .{result.stream_id});
                },
                .GoAway, .Reset => {
                    std.debug.print("  Stream {} closed ({})\n", .{ result.stream_id, result.event_type });
                },
                .PriorityUpdate => {
                    // Log for telemetry
                },
            }
        }
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
    
    fn onTimeout(self: *QuicServer, conn: *connection.Connection) void {
        conn.conn.onTimeout();
        
        // Drain egress after timeout using the connection's socket
        self.drainEgress(conn) catch {};
        
        if (conn.conn.isClosed()) {
            self.closeConnection(conn);
        }
    }
    
    fn closeConnection(self: *QuicServer, conn: *connection.Connection) void {
        // Log stats
        var stats: c.quiche_stats = undefined;
        conn.conn.stats(&stats);
        
        var hex_buf: [40]u8 = undefined;
        const hex_dcid = connection.formatCid(conn.dcid[0..conn.dcid_len], &hex_buf) catch "???";
        
        std.debug.print("Connection closed {s}: recv={d} sent={d} lost={d}\n", .{
            hex_dcid,
            stats.recv,
            stats.sent,
            stats.lost,
        });
        
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