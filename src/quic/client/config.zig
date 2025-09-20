const std = @import("std");

pub const ClientConfig = struct {
    alpn_protocols: []const []const u8 = &.{"h3"},
    cc_algorithm: []const u8 = "cubic",
    idle_timeout_ms: u64 = 30_000,
    initial_max_data: u64 = 2 * 1024 * 1024,
    initial_max_stream_data_bidi_local: u64 = 1 * 1024 * 1024,
    initial_max_stream_data_bidi_remote: u64 = 1 * 1024 * 1024,
    initial_max_stream_data_uni: u64 = 1 * 1024 * 1024,
    initial_max_streams_bidi: u64 = 16,
    initial_max_streams_uni: u64 = 16,
    max_recv_udp_payload_size: usize = 1350,
    max_send_udp_payload_size: usize = 1350,
    disable_active_migration: bool = true,
    enable_pacing: bool = true,
    enable_dgram: bool = false,
    dgram_recv_queue_len: usize = 0,
    dgram_send_queue_len: usize = 0,
    grease: bool = true,
    verify_peer: bool = false,
    ca_bundle_path: ?[]const u8 = null,
    ca_bundle_dir: ?[]const u8 = null,
    keylog_path: ?[]const u8 = null,
    qlog_dir: ?[]const u8 = null,
    enable_debug_logging: bool = false,
    debug_log_throttle: u32 = 10,
    connect_timeout_ms: u64 = 10_000,
    enable_webtransport: bool = false,

    pub fn validate(self: *const ClientConfig) !void {
        if (self.alpn_protocols.len == 0) return error.EmptyAlpnList;
        for (self.alpn_protocols) |proto| {
            if (proto.len == 0) return error.EmptyAlpnEntry;
            if (proto.len > 255) return error.AlpnTooLong;
        }

        if (self.cc_algorithm.len == 0) return error.EmptyCcAlgorithm;
        if (self.idle_timeout_ms == 0) return error.InvalidIdleTimeout;
        if (self.initial_max_data == 0) return error.InvalidInitialMaxData;
        if (self.initial_max_streams_bidi == 0 and self.initial_max_streams_uni == 0) {
            return error.NoStreamsAllowed;
        }
        if (self.max_recv_udp_payload_size < 1200 or self.max_recv_udp_payload_size > 65_527) {
            return error.InvalidUdpPayloadSize;
        }
        if (self.max_send_udp_payload_size < 1200 or self.max_send_udp_payload_size > 65_527) {
            return error.InvalidUdpPayloadSize;
        }
        if (self.debug_log_throttle == 0) return error.InvalidDebugThrottle;
        if (self.connect_timeout_ms == 0) return error.InvalidConnectTimeout;
    }

    pub fn ensureQlogDir(self: *const ClientConfig) !void {
        if (self.qlog_dir) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    pub fn createQlogPath(self: *const ClientConfig, allocator: std.mem.Allocator, conn_id: []const u8) ![:0]u8 {
        if (self.qlog_dir) |dir| {
            var hex_buf: [40]u8 = undefined;
            var hex_len: usize = 0;
            const hex_digits = "0123456789abcdef";
            for (conn_id) |byte| {
                if (hex_len + 2 > hex_buf.len) break;
                hex_buf[hex_len] = hex_digits[(byte >> 4) & 0xF];
                hex_buf[hex_len + 1] = hex_digits[byte & 0xF];
                hex_len += 2;
            }

            const path = try std.fmt.allocPrint(allocator, "{s}/{s}.qlog", .{ dir, hex_buf[0..hex_len] });
            const path_z = try allocator.alloc(u8, path.len + 1);
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            allocator.free(path);
            return path_z[0..path.len :0];
        }
        return error.QlogDisabled;
    }
};

pub const ServerEndpoint = struct {
    host: []const u8,
    port: u16,
    sni: ?[]const u8 = null,

    pub fn validate(self: *const ServerEndpoint) !void {
        if (self.host.len == 0) return error.EmptyHost;
        if (self.port == 0) return error.InvalidPort;
    }

    pub fn sniHost(self: ServerEndpoint) []const u8 {
        return self.sni orelse self.host;
    }
};
