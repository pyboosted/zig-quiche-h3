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

    pub fn loadVerifyLocationsFromFile(self: *Config, path: [:0]const u8) error{LoadVerifyFailed}!void {
        const res = c.quiche_config_load_verify_locations_from_file(self.ptr, path.ptr);
        if (res < 0) return error.LoadVerifyFailed;
    }

    pub fn loadVerifyLocationsFromDirectory(self: *Config, path: [:0]const u8) error{LoadVerifyFailed}!void {
        const res = c.quiche_config_load_verify_locations_from_directory(self.ptr, path.ptr);
        if (res < 0) return error.LoadVerifyFailed;
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

    pub fn verifyPeer(self: *Config, verify: bool) void {
        c.quiche_config_verify_peer(self.ptr, verify);
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
        var reason: [*c]const u8 = undefined;
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

    pub fn streamCapacity(self: *Connection, stream_id: u64) !usize {
        const res = c.quiche_conn_stream_capacity(self.ptr, stream_id);
        if (res < 0) {
            // Try to map the error, but return specific error for unmapped negatives
            try mapError(@intCast(res));
            return QuicheError.InvalidState; // Fallback for unmapped errors
        }
        return @intCast(res);
    }

    pub fn streamWritableNext(self: *Connection) ?u64 {
        const res = c.quiche_conn_stream_writable_next(self.ptr);
        if (res < 0) return null;
        return @intCast(res);
    }

    pub fn streamWritable(self: *Connection, stream_id: u64, len: usize) !bool {
        const res = c.quiche_conn_stream_writable(self.ptr, stream_id, len);
        // Positive means writable, 0 means not writable, negative is error
        if (res < 0) {
            // Propagate the actual error instead of returning false
            try mapError(@intCast(res));
            return false; // Shouldn't reach here but needed for type safety
        }
        return res > 0;
    }

    // -------- QUIC streams (RFC 9000) wrappers --------
    pub const StreamRecvResult = struct {
        n: usize,
        fin: bool,
        error_code: u64 = 0,
    };

    pub const Shutdown = enum(c_uint) {
        read = c.QUICHE_SHUTDOWN_READ,
        write = c.QUICHE_SHUTDOWN_WRITE,
    };

    pub fn streamRecv(self: *Connection, stream_id: u64, out: []u8) !StreamRecvResult {
        var fin_flag: bool = false;
        var err_code: u64 = 0;
        const res = c.quiche_conn_stream_recv(self.ptr, stream_id, out.ptr, out.len, &fin_flag, &err_code);
        if (res < 0) {
            try mapError(@intCast(res));
            return error.RecvFailed; // Should not reach (mapError throws), keep type happy
        }
        return .{ .n = @intCast(res), .fin = fin_flag, .error_code = err_code };
    }

    pub fn streamSend(self: *Connection, stream_id: u64, buf: []const u8, fin: bool) !usize {
        var err_code: u64 = 0;
        const res = c.quiche_conn_stream_send(self.ptr, stream_id, buf.ptr, buf.len, fin, &err_code);
        if (res < 0) {
            try mapError(@intCast(res));
            return error.SendFailed; // Should not reach; preserves return type
        }
        return @intCast(res);
    }

    pub fn streamShutdown(self: *Connection, stream_id: u64, dir: Shutdown, err: u64) !void {
        const r = c.quiche_conn_stream_shutdown(self.ptr, stream_id, @as(c_uint, @intFromEnum(dir)), err);
        if (r < 0) try mapError(@intCast(r));
    }

    pub fn streamReadable(self: *const Connection, stream_id: u64) bool {
        return c.quiche_conn_stream_readable(self.ptr, stream_id);
    }

    pub fn streamReadableNext(self: *Connection) ?u64 {
        const res = c.quiche_conn_stream_readable_next(self.ptr);
        if (res < 0) return null;
        return @intCast(res);
    }

    pub fn streamFinished(self: *const Connection, stream_id: u64) bool {
        return c.quiche_conn_stream_finished(self.ptr, stream_id);
    }

    // -------- QUIC DATAGRAM (RFC 9221) wrappers --------
    pub fn dgramMaxWritableLen(self: *const Connection) ?usize {
        const res = c.quiche_conn_dgram_max_writable_len(self.ptr);
        if (res == c.QUICHE_ERR_DONE) return null;
        if (res < 0) return null; // treat unexpected negatives as no-space
        return @intCast(res);
    }

    pub fn dgramRecvFrontLen(self: *const Connection) ?usize {
        const res = c.quiche_conn_dgram_recv_front_len(self.ptr);
        if (res == c.QUICHE_ERR_DONE) return null;
        if (res < 0) return null;
        return @intCast(res);
    }

    pub fn dgramRecv(self: *Connection, out: []u8) !usize {
        const res = c.quiche_conn_dgram_recv(self.ptr, out.ptr, out.len);
        if (res == c.QUICHE_ERR_DONE) return QuicheError.Done;
        if (res < 0) {
            try mapError(@intCast(res));
            return error.RecvFailed;
        }
        return @intCast(res);
    }

    pub fn dgramSend(self: *Connection, buf: []const u8) !usize {
        const res = c.quiche_conn_dgram_send(self.ptr, buf.ptr, buf.len);
        if (res == c.QUICHE_ERR_DONE) return QuicheError.Done;
        if (res < 0) {
            try mapError(@intCast(res));
            return error.SendFailed;
        }
        return @intCast(res);
    }

    pub fn dgramRecvQueueLen(self: *const Connection) usize {
        const v = c.quiche_conn_dgram_recv_queue_len(self.ptr);
        return if (v > 0) @intCast(v) else 0;
    }

    pub fn dgramRecvQueueByteSize(self: *const Connection) usize {
        const v = c.quiche_conn_dgram_recv_queue_byte_size(self.ptr);
        return if (v > 0) @intCast(v) else 0;
    }

    pub fn dgramSendQueueLen(self: *const Connection) usize {
        const v = c.quiche_conn_dgram_send_queue_len(self.ptr);
        return if (v > 0) @intCast(v) else 0;
    }

    pub fn dgramSendQueueByteSize(self: *const Connection) usize {
        const v = c.quiche_conn_dgram_send_queue_byte_size(self.ptr);
        return if (v > 0) @intCast(v) else 0;
    }

    pub fn isDgramSendQueueFull(self: *const Connection) bool {
        return c.quiche_conn_is_dgram_send_queue_full(self.ptr);
    }

    pub fn isDgramRecvQueueFull(self: *const Connection) bool {
        return c.quiche_conn_is_dgram_recv_queue_full(self.ptr);
    }

    /// Purge outgoing datagrams that match the given predicate
    pub fn dgramPurgeOutgoing(self: *Connection, comptime f: fn ([]const u8) bool) void {
        const Wrapper = struct {
            const predicate = f;
            fn callback(data: [*c]const u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
                // Be safe with potential null pointers and zero-length slices.
                if (len == 0) {
                    const empty: []const u8 = &[_]u8{};
                    return if (predicate(empty)) 1 else 0;
                }
                if (data == null) return 0;
                const slice = data[0..len];
                return if (predicate(slice)) 1 else 0;
            }
        };
        c.quiche_conn_dgram_purge_outgoing(self.ptr, Wrapper.callback, null);
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

pub fn connect(
    server_name: [:0]const u8,
    scid: []const u8,
    local: *const std.posix.sockaddr,
    local_len: std.posix.socklen_t,
    peer: *const std.posix.sockaddr,
    peer_len: std.posix.socklen_t,
    config: *Config,
) !Connection {
    const ptr = c.quiche_connect(
        server_name.ptr,
        scid.ptr,
        scid.len,
        @ptrCast(local),
        local_len,
        @ptrCast(peer),
        peer_len,
        config.ptr,
    ) orelse return error.ConnectFailed;

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

// Compile-time ALPN encoder for common protocol combinations
pub const AlpnWireFormat = struct {
    // Pre-encode common ALPN combinations at compile-time
    pub const h3 = encodeAlpnComptime(&.{"h3"});
    pub const h3_hq = encodeAlpnComptime(&.{ "h3", "hq-interop" });
    pub const hq = encodeAlpnComptime(&.{"hq-interop"});

    fn encodeAlpnComptime(comptime protocols: []const []const u8) []const u8 {
        comptime {
            var total_len: usize = 0;
            for (protocols) |proto| {
                if (proto.len > 255) @compileError("Protocol name too long");
                total_len += 1 + proto.len;
            }

            var buf: [total_len]u8 = undefined;
            var offset: usize = 0;

            for (protocols) |proto| {
                buf[offset] = @intCast(proto.len);
                offset += 1;
                @memcpy(buf[offset..][0..proto.len], proto);
                offset += proto.len;
            }

            const result = buf;
            return &result;
        }
    }
};

// Runtime ALPN encoder - still needed for dynamic protocols
pub fn encodeAlpn(allocator: std.mem.Allocator, protocols: []const []const u8) ![]u8 {
    // Check if we can use pre-encoded version
    if (protocols.len == 1 and std.mem.eql(u8, protocols[0], "h3")) {
        const encoded = try allocator.alloc(u8, AlpnWireFormat.h3.len);
        @memcpy(encoded, AlpnWireFormat.h3);
        return encoded;
    }
    if (protocols.len == 2 and std.mem.eql(u8, protocols[0], "h3") and std.mem.eql(u8, protocols[1], "hq-interop")) {
        const encoded = try allocator.alloc(u8, AlpnWireFormat.h3_hq.len);
        @memcpy(encoded, AlpnWireFormat.h3_hq);
        return encoded;
    }

    // Fallback to runtime encoding for other combinations
    var total_len: usize = 0;
    for (protocols) |proto| {
        if (proto.len > 255) return error.ProtocolNameTooLong;
        total_len += 1 + proto.len;
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

// Forward declarations to avoid ambiguity
const QuicConnection = Connection;
const QuicConfig = Config;

// HTTP/3 namespace - nested for organization
pub const h3 = struct {
    // H3 error codes
    pub const Error = error{
        Done, // H3_ERR_DONE - no work to do (non-fatal)
        BufferTooShort,
        InternalError,
        ExcessiveLoad,
        IdError,
        StreamCreationError,
        StreamBlocked,
        RequestRejected,
        RequestCancelled,
        RequestIncomplete,
        MessageError,
        ConnectError,
        VersionFallback,
        QpackDecompressionFailed,
        QpackEncoderStreamError,
        QpackDecoderStreamError,
        TransportError,
        FrameUnexpected,
        FrameError,
        MissingSettings,
        GeneralProtocolError,
    };

    pub fn mapError(err: c_int) Error!void {
        switch (err) {
            c.QUICHE_H3_ERR_DONE => return Error.Done,
            c.QUICHE_H3_ERR_BUFFER_TOO_SHORT => return Error.BufferTooShort,
            c.QUICHE_H3_ERR_INTERNAL_ERROR => return Error.InternalError,
            c.QUICHE_H3_ERR_EXCESSIVE_LOAD => return Error.ExcessiveLoad,
            c.QUICHE_H3_ERR_ID_ERROR => return Error.IdError,
            c.QUICHE_H3_ERR_STREAM_CREATION_ERROR => return Error.StreamCreationError,
            c.QUICHE_H3_ERR_STREAM_BLOCKED => return Error.StreamBlocked,
            c.QUICHE_H3_ERR_REQUEST_REJECTED => return Error.RequestRejected,
            c.QUICHE_H3_ERR_REQUEST_CANCELLED => return Error.RequestCancelled,
            c.QUICHE_H3_ERR_REQUEST_INCOMPLETE => return Error.RequestIncomplete,
            c.QUICHE_H3_ERR_MESSAGE_ERROR => return Error.MessageError,
            c.QUICHE_H3_ERR_CONNECT_ERROR => return Error.ConnectError,
            c.QUICHE_H3_ERR_VERSION_FALLBACK => return Error.VersionFallback,
            c.QUICHE_H3_ERR_QPACK_DECOMPRESSION_FAILED => return Error.QpackDecompressionFailed,
            // c.QUICHE_H3_ERR_QPACK_ENCODER_STREAM_ERROR => return Error.QpackEncoderStreamError,
            // c.QUICHE_H3_ERR_QPACK_DECODER_STREAM_ERROR => return Error.QpackDecoderStreamError,
            c.QUICHE_H3_TRANSPORT_ERR_DONE => return Error.Done, // Transport done is also non-fatal
            c.QUICHE_H3_ERR_FRAME_UNEXPECTED => return Error.FrameUnexpected,
            c.QUICHE_H3_ERR_FRAME_ERROR => return Error.FrameError,
            c.QUICHE_H3_ERR_MISSING_SETTINGS => return Error.MissingSettings,
            // c.QUICHE_H3_ERR_GENERAL_PROTOCOL_ERROR => return Error.GeneralProtocolError, // Not available in C header
            else => {
                // Log unknown error code once for debugging
                std.debug.print("[H3] Unknown error code: {d}\n", .{err});
            },
        }
    }

    // Config wrapper
    pub const Config = struct {
        ptr: *c.quiche_h3_config,

        pub fn new() !h3.Config {
            const ptr = c.quiche_h3_config_new() orelse return error.H3ConfigCreateFailed;
            return h3.Config{ .ptr = ptr };
        }

        pub fn deinit(self: *h3.Config) void {
            c.quiche_h3_config_free(self.ptr);
        }

        pub fn setMaxFieldSectionSize(self: *h3.Config, v: u64) void {
            c.quiche_h3_config_set_max_field_section_size(self.ptr, v);
        }

        pub fn setQpackMaxTableCapacity(self: *h3.Config, v: u64) void {
            c.quiche_h3_config_set_qpack_max_table_capacity(self.ptr, v);
        }

        pub fn setQpackBlockedStreams(self: *h3.Config, v: u64) void {
            c.quiche_h3_config_set_qpack_blocked_streams(self.ptr, v);
        }

        pub fn enableExtendedConnect(self: *h3.Config, enabled: bool) void {
            c.quiche_h3_config_enable_extended_connect(self.ptr, enabled);
        }
    };

    // Connection wrapper
    pub const Connection = struct {
        ptr: *c.quiche_h3_conn,

        // Use parent module's Connection type explicitly
        pub fn newWithTransport(quic_conn: *QuicConnection, config: *h3.Config) !h3.Connection {
            const ptr = c.quiche_h3_conn_new_with_transport(quic_conn.ptr, config.ptr) orelse
                return error.H3ConnectionCreateFailed;
            return h3.Connection{ .ptr = ptr };
        }

        pub fn deinit(self: *h3.Connection) void {
            c.quiche_h3_conn_free(self.ptr);
        }

        pub fn poll(self: *h3.Connection, quic_conn: *QuicConnection) !PollResult {
            var event: ?*c.quiche_h3_event = null;
            const stream_id = c.quiche_h3_conn_poll(self.ptr, quic_conn.ptr, &event);

            if (stream_id < 0) {
                try h3.mapError(@intCast(stream_id));
                return error.PollFailed;
            }

            return PollResult{
                .stream_id = @intCast(stream_id),
                .event = event,
            };
        }

        pub fn sendResponse(
            self: *h3.Connection,
            quic_conn: *QuicConnection,
            stream_id: u64,
            headers: []const Header,
            fin: bool,
        ) !void {
            const res = c.quiche_h3_send_response(
                self.ptr,
                quic_conn.ptr,
                stream_id,
                @ptrCast(headers.ptr),
                headers.len,
                fin,
            );
            if (res < 0) {
                try h3.mapError(res);
                return error.SendResponseFailed;
            }
        }

        pub fn sendRequest(
            self: *h3.Connection,
            quic_conn: *QuicConnection,
            headers: []const Header,
            fin: bool,
        ) !u64 {
            const res = c.quiche_h3_send_request(
                self.ptr,
                quic_conn.ptr,
                @ptrCast(headers.ptr),
                headers.len,
                fin,
            );
            if (res < 0) {
                try h3.mapError(@intCast(res));
                return error.SendRequestFailed;
            }
            return @intCast(res);
        }

        pub fn sendBody(
            self: *h3.Connection,
            quic_conn: *QuicConnection,
            stream_id: u64,
            body: []const u8,
            fin: bool,
        ) !usize {
            const res = c.quiche_h3_send_body(
                self.ptr,
                quic_conn.ptr,
                stream_id,
                body.ptr,
                body.len,
                fin,
            );
            if (res < 0) {
                try h3.mapError(@intCast(res));
                return error.SendBodyFailed;
            }
            return @intCast(res);
        }

        /// Send additional headers on a stream. When is_trailer_section is true, the
        /// header block is interpreted as trailers. Set fin=true to finish the stream.
        pub fn sendAdditionalHeaders(
            self: *h3.Connection,
            quic_conn: *QuicConnection,
            stream_id: u64,
            headers: []const Header,
            is_trailer_section: bool,
            fin: bool,
        ) !void {
            const res = c.quiche_h3_send_additional_headers(
                self.ptr,
                quic_conn.ptr,
                stream_id,
                @ptrCast(@constCast(headers.ptr)),
                headers.len,
                is_trailer_section,
                fin,
            );
            if (res < 0) {
                try h3.mapError(res);
                return error.SendResponseFailed;
            }
        }

        pub fn recvBody(
            self: *h3.Connection,
            quic_conn: *QuicConnection,
            stream_id: u64,
            out: []u8,
        ) !usize {
            const res = c.quiche_h3_recv_body(
                self.ptr,
                quic_conn.ptr,
                stream_id,
                out.ptr,
                out.len,
            );
            if (res < 0) {
                try h3.mapError(@intCast(res));
                return error.RecvBodyFailed;
            }
            return @intCast(res);
        }

        /// Check if H3 DATAGRAM is enabled by peer (negotiated via SETTINGS)
        pub fn dgramEnabledByPeer(self: *h3.Connection, quic_conn: *QuicConnection) bool {
            return c.quiche_h3_dgram_enabled_by_peer(self.ptr, quic_conn.ptr);
        }

        /// Check if Extended CONNECT is enabled by peer (negotiated via SETTINGS)
        pub fn extendedConnectEnabledByPeer(self: *h3.Connection) bool {
            return c.quiche_h3_extended_connect_enabled_by_peer(self.ptr);
        }

        pub const PollResult = struct {
            stream_id: u64,
            event: ?*c.quiche_h3_event,
        };
    };

    // Event types
    pub const EventType = enum(u32) {
        Headers = 0,
        Data = 1,
        Finished = 2,
        GoAway = 3,
        Reset = 4,
        PriorityUpdate = 5,
    };

    pub fn eventType(event: *c.quiche_h3_event) EventType {
        return @enumFromInt(c.quiche_h3_event_type(event));
    }

    pub fn eventFree(event: *c.quiche_h3_event) void {
        c.quiche_h3_event_free(event);
    }

    // Header struct matching C layout
    pub const Header = extern struct {
        name: [*]const u8,
        name_len: usize,
        value: [*]const u8,
        value_len: usize,
    };

    // Callback for iterating headers
    pub const HeaderCallback = *const fn (
        name: [*c]u8,
        name_len: usize,
        value: [*c]u8,
        value_len: usize,
        argp: ?*anyopaque,
    ) callconv(.c) c_int;

    pub fn eventForEachHeader(
        event: *c.quiche_h3_event,
        cb: HeaderCallback,
        argp: ?*anyopaque,
    ) !void {
        const res = c.quiche_h3_event_for_each_header(event, cb, argp);
        if (res != 0) return error.HeaderIterationFailed;
    }

    pub fn eventHeadersHasMoreFrames(event: *c.quiche_h3_event) bool {
        return c.quiche_h3_event_headers_has_more_frames(event);
    }
};
