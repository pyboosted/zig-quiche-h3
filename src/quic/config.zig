const std = @import("std");

// QUIC server configuration with safe defaults for M3 (HTTP/3)
pub const ServerConfig = struct {
    pub const LogLevel = enum(u8) { err, warn, info, debug, trace };
    // Network
    bind_addr: []const u8 = "0.0.0.0",
    bind_port: u16 = 4433,

    // TLS
    cert_path: []const u8 = "third_party/quiche/quiche/examples/cert.crt",
    key_path: []const u8 = "third_party/quiche/quiche/examples/cert.key",
    verify_peer: bool = false, // Disable peer verification for testing

    // QUIC Transport Parameters (safe defaults for M3)
    idle_timeout_ms: u64 = 30_000, // 30 seconds
    initial_max_data: u64 = 2 * 1024 * 1024, // 2 MiB
    initial_max_stream_data_bidi_local: u64 = 1024 * 1024, // 1 MiB
    initial_max_stream_data_bidi_remote: u64 = 1024 * 1024, // 1 MiB
    initial_max_stream_data_uni: u64 = 1024 * 1024, // 1 MiB
    initial_max_streams_bidi: u64 = 10,
    initial_max_streams_uni: u64 = 10,
    max_recv_udp_payload_size: usize = 1350, // Conservative for M3
    max_send_udp_payload_size: usize = 1350,

    // Features
    disable_active_migration: bool = true, // Simplify for M3
    enable_pacing: bool = true, // Good default
    cc_algorithm: []const u8 = "cubic", // Standard choice
    enable_dgram: bool = false, // Off for M3 (M4 will enable)
    dgram_recv_queue_len: usize = 0,
    dgram_send_queue_len: usize = 0,
    grease: bool = true, // Improve interop

    // Debug
    qlog_dir: ?[]const u8 = "qlogs", // Enable qlog by default
    keylog_path: ?[]const u8 = null, // Optional SSLKEYLOGFILE
    enable_debug_logging: bool = true,
    log_level: LogLevel = .warn,
    debug_log_throttle: u32 = 10, // Print every Nth line to avoid spam

    // ALPN protocols - support both HTTP/3 and HTTP/0.9 like quiche examples
    alpn_protocols: []const []const u8 = &.{
        "h3", // HTTP/3 (default for quiche-client)
        "hq-interop", // HTTP/0.9 over QUIC (interop testing)
        "hq-29", // HTTP/0.9 draft-29
        "hq-28", // HTTP/0.9 draft-28
        "hq-27", // HTTP/0.9 draft-27
        "http/0.9", // HTTP/0.9
    },

    // HTTP configuration limits
    max_request_headers_size: usize = 16384, // 16KB
    max_request_body_size: usize = 104857600, // 100MB (increased for testing)
    max_path_length: usize = 2048,
    /// Max bytes buffered in-memory for non-streaming request bodies.
    /// Larger bodies should use streaming handlers; exceeding this cap returns 413.
    max_non_streaming_body_bytes: usize = 1 * 1024 * 1024, // 1 MiB

    /// Phase 2: concurrency caps (0 = unlimited)
    /// Maximum number of simultaneously active HTTP requests per connection.
    /// Requests are considered active from headers received until the response
    /// is fully ended and stream state is cleaned up.
    max_active_requests_per_conn: usize = 0,

    /// Maximum number of simultaneously active download streams per connection.
    /// A "download" is defined as a response that streams from a file or
    /// generator source (PartialResponse.file/generator). Memory-backed partials
    /// created for backpressure are not counted.
    max_active_downloads_per_conn: usize = 0,

    // WebTransport server-side limits (experimental)
    wt_max_streams_uni: u32 = 32,
    wt_max_streams_bidi: u32 = 32,
    wt_write_quota_per_tick: usize = 64 * 1024, // limit WT stream writes per tick per connection
    wt_session_idle_ms: u64 = 60_000, // idle close for inactive sessions
    wt_stream_pending_max: usize = 256 * 1024, // max pending bytes per WT stream
    // WT QUIC application error codes for control paths
    wt_app_err_stream_limit: u64 = 0x1000,
    wt_app_err_invalid_stream: u64 = 0x1001,

    // Retry
    enable_retry: bool = false, // Optional for M3

    // Buffer sizes
    recv_buffer_size: usize = 2048, // Good for M3, increase later
    send_buffer_size: usize = 2048,

    /// Compile-time configuration validation
    /// This validates a configuration at compile-time to catch errors during build
    pub fn validateComptime(comptime cfg: ServerConfig) void {
        // Port validation
        if (cfg.bind_port == 0 or cfg.bind_port > 65535) {
            @compileError(std.fmt.comptimePrint("Invalid port: {d}. Port must be between 1 and 65535", .{cfg.bind_port}));
        }

        // Path validation
        if (cfg.cert_path.len == 0) {
            @compileError("Certificate path cannot be empty");
        }
        if (cfg.key_path.len == 0) {
            @compileError("Key path cannot be empty");
        }

        // ALPN validation
        if (cfg.alpn_protocols.len == 0) {
            @compileError("At least one ALPN protocol must be specified");
        }
        for (cfg.alpn_protocols) |proto| {
            if (proto.len == 0) {
                @compileError("ALPN protocol cannot be empty string");
            }
            if (proto.len > 255) {
                @compileError(std.fmt.comptimePrint("ALPN protocol '{s}' exceeds 255 bytes", .{proto}));
            }
        }

        // Transport parameters validation
        if (cfg.initial_max_data == 0) {
            @compileError("initial_max_data must be greater than 0");
        }
        if (cfg.initial_max_streams_bidi == 0 and cfg.initial_max_streams_uni == 0) {
            @compileError("At least one stream type must be allowed (bidi or uni)");
        }

        // Buffer size validation
        if (cfg.recv_buffer_size < 1350) {
            @compileError(std.fmt.comptimePrint("recv_buffer_size ({d}) must be at least 1350 bytes for QUIC MTU", .{cfg.recv_buffer_size}));
        }
        if (cfg.send_buffer_size < 1350) {
            @compileError(std.fmt.comptimePrint("send_buffer_size ({d}) must be at least 1350 bytes for QUIC MTU", .{cfg.send_buffer_size}));
        }
        if (cfg.max_recv_udp_payload_size < 1200 or cfg.max_recv_udp_payload_size > 65527) {
            @compileError(std.fmt.comptimePrint("max_recv_udp_payload_size ({d}) must be between 1200 and 65527", .{cfg.max_recv_udp_payload_size}));
        }
        if (cfg.max_send_udp_payload_size < 1200 or cfg.max_send_udp_payload_size > 65527) {
            @compileError(std.fmt.comptimePrint("max_send_udp_payload_size ({d}) must be between 1200 and 65527", .{cfg.max_send_udp_payload_size}));
        }

        // HTTP limits validation
        if (cfg.max_request_headers_size < 1024) {
            @compileError(std.fmt.comptimePrint("max_request_headers_size ({d}) must be at least 1024 bytes", .{cfg.max_request_headers_size}));
        }
        if (cfg.max_path_length < 16) {
            @compileError(std.fmt.comptimePrint("max_path_length ({d}) must be at least 16 characters", .{cfg.max_path_length}));
        }
        if (cfg.max_non_streaming_body_bytes < 1024) {
            @compileError(std.fmt.comptimePrint("max_non_streaming_body_bytes ({d}) must be at least 1024 bytes", .{cfg.max_non_streaming_body_bytes}));
        }

        // Timeout validation
        if (cfg.idle_timeout_ms == 0) {
            @compileError("idle_timeout_ms must be greater than 0 (use a large value to effectively disable)");
        }

        // Debug settings validation
        if (cfg.debug_log_throttle == 0) {
            @compileError("debug_log_throttle must be at least 1 (1 = no throttling)");
        }

        // WebTransport validation (when enabled)
        if (cfg.wt_write_quota_per_tick == 0) {
            @compileError("wt_write_quota_per_tick must be greater than 0");
        }
        if (cfg.wt_session_idle_ms == 0) {
            @compileError("wt_session_idle_ms must be greater than 0");
        }
        if (cfg.wt_stream_pending_max == 0) {
            @compileError("wt_stream_pending_max must be greater than 0");
        }
    }

    /// Runtime validation (kept for dynamic configurations)
    pub fn validate(self: *const ServerConfig) !void {
        // Basic validation
        if (self.bind_port == 0) return error.InvalidPort;
        if (self.cert_path.len == 0) return error.MissingCertPath;
        if (self.key_path.len == 0) return error.MissingKeyPath;
        if (self.alpn_protocols.len == 0) return error.NoAlpnProtocols;

        // Validate transport parameters
        if (self.initial_max_data == 0) return error.InvalidMaxData;
        if (self.initial_max_streams_bidi == 0 and self.initial_max_streams_uni == 0) {
            return error.NoStreamsAllowed;
        }

        // Check buffer sizes
        if (self.recv_buffer_size < 1350) return error.RecvBufferTooSmall;
        if (self.send_buffer_size < 1350) return error.SendBufferTooSmall;

        // Validate debug log throttle
        if (self.debug_log_throttle == 0) return error.InvalidDebugLogThrottle;

        // Basic sanity for WT limits
        if (self.wt_max_streams_uni == 0 and self.wt_max_streams_bidi == 0) {
            // Allow zero if WT is disabled via env; otherwise harmless.
        }
    }

    // Compile-time hex lookup table for fast conversion
    const HexTable = struct {
        const table = blk: {
            var t: [256][2]u8 = undefined;
            const hex_chars = "0123456789abcdef";
            for (0..256) |i| {
                t[i][0] = hex_chars[i >> 4];
                t[i][1] = hex_chars[i & 0x0f];
            }
            break :blk t;
        };
    };

    pub fn createQlogPath(self: *const ServerConfig, allocator: std.mem.Allocator, conn_id: []const u8) ![:0]u8 {
        if (self.qlog_dir) |dir| {
            // Format connection ID as hex using compile-time lookup table
            var hex_buf: [40]u8 = undefined; // Max 20 bytes * 2

            var hex_len: usize = 0;
            for (conn_id) |byte| {
                if (hex_len >= hex_buf.len - 1) break;
                // Direct lookup - no computation needed
                const hex_pair = HexTable.table[byte];
                hex_buf[hex_len] = hex_pair[0];
                hex_len += 1;
                hex_buf[hex_len] = hex_pair[1];
                hex_len += 1;
            }

            // Use allocPrint to create the path
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}.qlog", .{ dir, hex_buf[0..hex_len] });
            // Add null terminator for C interop
            const path_z = try allocator.alloc(u8, path.len + 1);
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            allocator.free(path);
            return path_z[0..path.len :0];
        }
        return error.QlogDisabled;
    }

    pub fn ensureQlogDir(self: *const ServerConfig) !void {
        if (self.qlog_dir) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {}, // OK
                    else => return err,
                }
            };
        }
    }
};

// Tests for compile-time validation
test "ServerConfig compile-time validation catches invalid configs" {
    // These would cause compile errors if uncommented:

    // Invalid port (0)
    // const bad_port_config = ServerConfig{ .bind_port = 0 };
    // comptime ServerConfig.validateComptime(bad_port_config);

    // Port out of range
    // const bad_port_high = ServerConfig{ .bind_port = 70000 };
    // comptime ServerConfig.validateComptime(bad_port_high);

    // Empty certificate path
    // const bad_cert = ServerConfig{ .cert_path = "" };
    // comptime ServerConfig.validateComptime(bad_cert);

    // Buffer too small
    // const bad_buffer = ServerConfig{ .recv_buffer_size = 1000 };
    // comptime ServerConfig.validateComptime(bad_buffer);

    // No ALPN protocols
    // const bad_alpn = ServerConfig{ .alpn_protocols = &.{} };
    // comptime ServerConfig.validateComptime(bad_alpn);

    // Valid configuration should pass
    const valid_config = ServerConfig{};
    comptime ServerConfig.validateComptime(valid_config);

    try std.testing.expect(true); // Test passes if compilation succeeds
}

test "ServerConfig runtime validation" {
    // Test runtime validation still works
    var config = ServerConfig{};
    try config.validate();

    // Invalid port
    config.bind_port = 0;
    try std.testing.expectError(error.InvalidPort, config.validate());
    config.bind_port = 4433;

    // Empty cert path
    config.cert_path = "";
    try std.testing.expectError(error.MissingCertPath, config.validate());
    config.cert_path = "test.crt";

    // Empty key path
    config.key_path = "";
    try std.testing.expectError(error.MissingKeyPath, config.validate());
    config.key_path = "test.key";

    // Buffer too small
    config.recv_buffer_size = 1000;
    try std.testing.expectError(error.RecvBufferTooSmall, config.validate());
}
