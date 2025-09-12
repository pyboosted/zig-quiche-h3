const std = @import("std");

// QUIC server configuration with safe defaults for M3 (HTTP/3)
pub const ServerConfig = struct {
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

    pub fn createQlogPath(self: *const ServerConfig, allocator: std.mem.Allocator, conn_id: []const u8) ![:0]u8 {
        if (self.qlog_dir) |dir| {
            // Format connection ID as hex
            var hex_buf: [40]u8 = undefined; // Max 20 bytes * 2
            const hex_chars = "0123456789abcdef";

            var hex_len: usize = 0;
            for (conn_id) |byte| {
                if (hex_len >= hex_buf.len - 1) break;
                hex_buf[hex_len] = hex_chars[byte >> 4];
                hex_len += 1;
                hex_buf[hex_len] = hex_chars[byte & 0x0f];
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
