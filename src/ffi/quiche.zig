const std = @import("std");

// Import quiche C header
pub const c = @cImport({
    @cInclude("quiche.h");
});

// Re-export commonly used constants
pub const PROTOCOL_VERSION = c.QUICHE_PROTOCOL_VERSION;
pub const MAX_CONN_ID_LEN = c.QUICHE_MAX_CONN_ID_LEN;
pub const MIN_CLIENT_INITIAL_LEN = c.QUICHE_MIN_CLIENT_INITIAL_LEN;

// QUIC packet types (matching quiche FFI constants)
pub const PacketType = struct {
    pub const Initial: u8 = 1;
    pub const Retry: u8 = 2;
    pub const Handshake: u8 = 3;
    pub const ZeroRTT: u8 = 4;
    pub const ShortHeader: u8 = 5;
    pub const VersionNegotiation: u8 = 6;
};

// Error mapping from negative C values to Zig errors
pub const QuicheError = error{
    Done,
    BufferTooShort,
    UnknownVersion,
    InvalidFrame,
    InvalidPacket,
    InvalidState,
    InvalidStreamState,
    InvalidTransportParam,
    CryptoFail,
    TlsFail,
    FlowControl,
    StreamLimit,
    FinalSize,
    CongestionControl,
    StreamStopped,
    StreamReset,
    IdLimit,
    OutOfIdentifiers,
    KeyUpdate,
    CryptoBufferExceeded,
    InvalidAckRange,
    OptimisticAckDetected,
};

pub fn mapError(err: c_int) QuicheError!void {
    switch (err) {
        c.QUICHE_ERR_DONE => return QuicheError.Done,
        c.QUICHE_ERR_BUFFER_TOO_SHORT => return QuicheError.BufferTooShort,
        c.QUICHE_ERR_UNKNOWN_VERSION => return QuicheError.UnknownVersion,
        c.QUICHE_ERR_INVALID_FRAME => return QuicheError.InvalidFrame,
        c.QUICHE_ERR_INVALID_PACKET => return QuicheError.InvalidPacket,
        c.QUICHE_ERR_INVALID_STATE => return QuicheError.InvalidState,
        c.QUICHE_ERR_INVALID_STREAM_STATE => return QuicheError.InvalidStreamState,
        c.QUICHE_ERR_INVALID_TRANSPORT_PARAM => return QuicheError.InvalidTransportParam,
        c.QUICHE_ERR_CRYPTO_FAIL => return QuicheError.CryptoFail,
        c.QUICHE_ERR_TLS_FAIL => return QuicheError.TlsFail,
        c.QUICHE_ERR_FLOW_CONTROL => return QuicheError.FlowControl,
        c.QUICHE_ERR_STREAM_LIMIT => return QuicheError.StreamLimit,
        c.QUICHE_ERR_FINAL_SIZE => return QuicheError.FinalSize,
        c.QUICHE_ERR_CONGESTION_CONTROL => return QuicheError.CongestionControl,
        c.QUICHE_ERR_STREAM_STOPPED => return QuicheError.StreamStopped,
        c.QUICHE_ERR_STREAM_RESET => return QuicheError.StreamReset,
        c.QUICHE_ERR_ID_LIMIT => return QuicheError.IdLimit,
        c.QUICHE_ERR_OUT_OF_IDENTIFIERS => return QuicheError.OutOfIdentifiers,
        c.QUICHE_ERR_KEY_UPDATE => return QuicheError.KeyUpdate,
        c.QUICHE_ERR_CRYPTO_BUFFER_EXCEEDED => return QuicheError.CryptoBufferExceeded,
        c.QUICHE_ERR_INVALID_ACK_RANGE => return QuicheError.InvalidAckRange,
        c.QUICHE_ERR_OPTIMISTIC_ACK_DETECTED => return QuicheError.OptimisticAckDetected,
        else => {},
    }
}

// Config wrapper
pub const Config = struct {
    ptr: *c.quiche_config,

    pub fn new(proto_version: u32) !Config {
        const ptr = c.quiche_config_new(proto_version) orelse return error.ConfigCreateFailed;
        return Config{ .ptr = ptr };
    }

    pub fn deinit(self: *Config) void {
        c.quiche_config_free(self.ptr);
    }

    pub fn loadCertChainFromPemFile(self: *Config, path: [:0]const u8) !void {
        const res = c.quiche_config_load_cert_chain_from_pem_file(self.ptr, path.ptr);
        if (res < 0) return error.CertLoadFailed;
    }

    pub fn loadPrivKeyFromPemFile(self: *Config, path: [:0]const u8) !void {
        const res = c.quiche_config_load_priv_key_from_pem_file(self.ptr, path.ptr);
        if (res < 0) return error.KeyLoadFailed;
    }

    pub fn setApplicationProtos(self: *Config, protos: []const u8) !void {
        const res = c.quiche_config_set_application_protos(self.ptr, protos.ptr, protos.len);
        if (res < 0) return error.AlpnSetFailed;
    }

    pub fn setMaxIdleTimeout(self: *Config, v: u64) void {
        c.quiche_config_set_max_idle_timeout(self.ptr, v);
    }

    pub fn setInitialMaxData(self: *Config, v: u64) void {
        c.quiche_config_set_initial_max_data(self.ptr, v);
    }

    pub fn setInitialMaxStreamDataBidiLocal(self: *Config, v: u64) void {
        c.quiche_config_set_initial_max_stream_data_bidi_local(self.ptr, v);
    }

    pub fn setInitialMaxStreamDataBidiRemote(self: *Config, v: u64) void {
        c.quiche_config_set_initial_max_stream_data_bidi_remote(self.ptr, v);
    }

    pub fn setInitialMaxStreamDataUni(self: *Config, v: u64) void {
        c.quiche_config_set_initial_max_stream_data_uni(self.ptr, v);
    }

    pub fn setInitialMaxStreamsBidi(self: *Config, v: u64) void {
        c.quiche_config_set_initial_max_streams_bidi(self.ptr, v);
    }

    pub fn setInitialMaxStreamsUni(self: *Config, v: u64) void {
        c.quiche_config_set_initial_max_streams_uni(self.ptr, v);
    }

    pub fn setDisableActiveMigration(self: *Config, v: bool) void {
        c.quiche_config_set_disable_active_migration(self.ptr, v);
    }

    pub fn enableDgram(self: *Config, enabled: bool, recv_queue_len: usize, send_queue_len: usize) void {
        c.quiche_config_enable_dgram(self.ptr, enabled, recv_queue_len, send_queue_len);
    }

    pub fn setCcAlgorithmName(self: *Config, algo: [:0]const u8) !void {
        const res = c.quiche_config_set_cc_algorithm_name(self.ptr, algo.ptr);
        if (res < 0) return error.CcAlgorithmSetFailed;
    }

    pub fn enablePacing(self: *Config, v: bool) void {
        c.quiche_config_enable_pacing(self.ptr, v);
    }

    pub fn grease(self: *Config, v: bool) void {
        c.quiche_config_grease(self.ptr, v);
    }

    pub fn setMaxRecvUdpPayloadSize(self: *Config, v: usize) void {
        c.quiche_config_set_max_recv_udp_payload_size(self.ptr, v);
    }

    pub fn setMaxSendUdpPayloadSize(self: *Config, v: usize) void {
        c.quiche_config_set_max_send_udp_payload_size(self.ptr, v);
    }
};

// Connection wrapper
pub const Connection = struct {
    ptr: *c.quiche_conn,

    pub fn deinit(self: *Connection) void {
        c.quiche_conn_free(self.ptr);
    }

    pub fn recv(self: *Connection, buf: []u8, recv_info: *const c.quiche_recv_info) !usize {
        const res = c.quiche_conn_recv(self.ptr, buf.ptr, buf.len, recv_info);
        if (res < 0) {
            try mapError(@intCast(res));
            return error.RecvFailed;
        }
        return @intCast(res);
    }

    pub fn send(self: *Connection, out: []u8, send_info: *c.quiche_send_info) !usize {
        const res = c.quiche_conn_send(self.ptr, out.ptr, out.len, send_info);
        if (res == c.QUICHE_ERR_DONE) return QuicheError.Done;
        if (res < 0) {
            try mapError(@intCast(res));
            return error.SendFailed;
        }
        return @intCast(res);
    }

    pub fn timeoutAsMillis(self: *const Connection) u64 {
        return c.quiche_conn_timeout_as_millis(self.ptr);
    }

    pub fn onTimeout(self: *Connection) void {
        c.quiche_conn_on_timeout(self.ptr);
    }

    pub fn isEstablished(self: *const Connection) bool {
        return c.quiche_conn_is_established(self.ptr);
    }

    pub fn isClosed(self: *const Connection) bool {
        return c.quiche_conn_is_closed(self.ptr);
    }

    pub fn peerError(self: *const Connection) ?struct { is_app: bool, error_code: u64, reason: []const u8 } {
        var is_app: bool = false;
        var error_code: u64 = 0;
        var reason: [*c]u8 = undefined;
        var reason_len: usize = 0;

        if (!c.quiche_conn_peer_error(self.ptr, &is_app, &error_code, &reason, &reason_len)) {
            return null;
        }

        return .{
            .is_app = is_app,
            .error_code = error_code,
            .reason = if (reason_len > 0) reason[0..reason_len] else &[_]u8{},
        };
    }

    pub fn stats(self: *const Connection, out_stats: *c.quiche_stats) void {
        c.quiche_conn_stats(self.ptr, out_stats);
    }

    pub fn setQlogPath(self: *Connection, path: [:0]const u8, log_title: [:0]const u8, log_desc: [:0]const u8) bool {
        return c.quiche_conn_set_qlog_path(self.ptr, path.ptr, log_title.ptr, log_desc.ptr);
    }

    pub fn setKeylogPath(self: *Connection, path: [:0]const u8) bool {
        return c.quiche_conn_set_keylog_path(self.ptr, path.ptr);
    }

    pub fn applicationProto(self: *const Connection) ?[]const u8 {
        var proto: [*c]const u8 = undefined;
        var proto_len: usize = 0;
        c.quiche_conn_application_proto(self.ptr, &proto, &proto_len);
        if (proto_len == 0) return null;
        return proto[0..proto_len];
    }
};

// Header parsing
pub fn headerInfo(
    buf: []const u8,
    dcil: usize,
    out_version: *u32,
    pkt_type: *u8,
    scid: []u8,
    scid_len: *usize,
    dcid: []u8,
    dcid_len: *usize,
    token: []u8,
    token_len: *usize,
) !void {
    scid_len.* = scid.len;
    dcid_len.* = dcid.len;
    token_len.* = token.len;

    const res = c.quiche_header_info(
        buf.ptr,
        buf.len,
        dcil,
        out_version,
        pkt_type,
        scid.ptr,
        scid_len,
        dcid.ptr,
        dcid_len,
        token.ptr,
        token_len,
    );
    if (res < 0) return error.HeaderParseFailed;
}

// Accept new connection
pub fn accept(
    scid: []const u8,
    odcid: ?[]const u8,
    local: *const std.posix.sockaddr,
    local_len: std.posix.socklen_t,
    peer: *const std.posix.sockaddr,
    peer_len: std.posix.socklen_t,
    config: *Config,
) !Connection {
    const odcid_ptr = if (odcid) |o| o.ptr else null;
    const odcid_len = if (odcid) |o| o.len else 0;

    const ptr = c.quiche_accept(
        scid.ptr,
        scid.len,
        odcid_ptr,
        odcid_len,
        @ptrCast(local),
        local_len,
        @ptrCast(peer),
        peer_len,
        config.ptr,
    ) orelse return error.AcceptFailed;

    return Connection{ .ptr = ptr };
}

// Version negotiation
pub fn versionIsSupported(ver: u32) bool {
    return c.quiche_version_is_supported(ver);
}

pub fn negotiateVersion(scid: []const u8, dcid: []const u8, out: []u8) !usize {
    const res = c.quiche_negotiate_version(scid.ptr, scid.len, dcid.ptr, dcid.len, out.ptr, out.len);
    if (res < 0) return error.VersionNegotiationFailed;
    return @intCast(res);
}

// Retry packet
pub fn retry(
    scid: []const u8,
    dcid: []const u8,
    new_scid: []const u8,
    token: []const u8,
    proto_version: u32,
    out: []u8,
) !usize {
    const res = c.quiche_retry(
        scid.ptr,
        scid.len,
        dcid.ptr,
        dcid.len,
        new_scid.ptr,
        new_scid.len,
        token.ptr,
        token.len,
        proto_version,
        out.ptr,
        out.len,
    );
    if (res < 0) return error.RetryFailed;
    return @intCast(res);
}

// Debug logging
pub fn enableDebugLogging(cb: ?*const fn ([*c]const u8, ?*anyopaque) callconv(.c) void, argp: ?*anyopaque) !void {
    const res = c.quiche_enable_debug_logging(cb, argp);
    if (res < 0) return error.DebugLoggingFailed;
}

// Version string
pub fn version() []const u8 {
    const ver = c.quiche_version();
    return std.mem.span(ver);
}

// ALPN encoder helper - critical for proper wire format!
pub fn encodeAlpn(allocator: std.mem.Allocator, protocols: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (protocols) |proto| {
        if (proto.len > 255) return error.ProtocolNameTooLong;
        total_len += 1 + proto.len; // 1 byte length prefix + protocol string
    }

    var buf = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    for (protocols) |proto| {
        buf[offset] = @intCast(proto.len);
        offset += 1;
        @memcpy(buf[offset..][0..proto.len], proto);
        offset += proto.len;
    }

    return buf;
}

// Helper to convert Zig sockaddr to C sockaddr
pub fn toCSockaddr(addr: *const std.posix.sockaddr) *const c.struct_sockaddr {
    return @ptrCast(addr);
}

// Helper to convert Zig sockaddr.storage to C sockaddr_storage
pub fn toCSockaddrStorage(addr: *const std.posix.sockaddr.storage) *const c.struct_sockaddr_storage {
    return @ptrCast(addr);
}