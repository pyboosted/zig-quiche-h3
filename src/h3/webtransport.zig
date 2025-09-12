const std = @import("std");
const quiche = @import("quiche");
const h3_datagram = @import("datagram.zig");
const h3_conn_mod = @import("connection.zig");

/// WebTransport session representing an established WebTransport connection
/// Session ID is the CONNECT stream ID per WebTransport over HTTP/3 spec
pub const WebTransportSession = struct {
    /// The CONNECT stream ID that established this session
    session_id: u64,

    /// QUIC connection reference
    quic_conn: *quiche.Connection,

    /// H3 connection reference
    h3_conn: *h3_conn_mod.H3Connection,

    /// Memory allocator for session data
    allocator: std.mem.Allocator,

    /// User data pointer for application state
    user_data: ?*anyopaque = null,

    /// Optional callback to notify when a WT datagram is sent successfully
    /// This allows the server to keep counters without creating a module cycle
    on_datagram_sent: ?*const fn (ctx: *anyopaque, bytes: usize) void = null,
    on_datagram_ctx: ?*anyopaque = null,

    /// Path that was used in the CONNECT request
    path: []const u8,

    /// Session state
    state: State = .active,

    pub const State = enum {
        active,
        closing,
        closed,
    };

    /// WT uni/bidi stream descriptor
    pub const StreamDir = enum { uni, bidi };
    pub const StreamRole = enum { incoming, outgoing };

    pub const WebTransportStream = struct {
        stream_id: u64,
        dir: StreamDir,
        role: StreamRole,
        session_id: u64,
        allocator: std.mem.Allocator,
        pending: std.ArrayListUnmanaged(u8) = .{},
        fin_on_flush: bool = false,

        pub fn isServerInitiated(self: *const WebTransportStream) bool {
            // QUIC stream id bit 0 == 1 => server-initiated
            return (self.stream_id & 0x1) == 1;
        }

        pub fn isUnidirectional(self: *const WebTransportStream) bool {
            // QUIC stream id bit 1 == 1 => unidirectional
            return (self.stream_id & 0x2) == 0x2;
        }
    };

    /// WebTransport unidirectional stream type (HTTP/3 Stream Type Registry)
    /// See WebTransport over HTTP/3 draft: stream type 0x54.
    /// https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-07.html
    pub const UNI_STREAM_TYPE: u64 = 0x54;

    /// WebTransport bidirectional stream preface signal (a varint value)
    /// This is written as the first varint on a bidi stream, followed by the
    /// session_id varint to bind the stream to a session. Capsules are not
    /// required for this binding path.
    pub const BIDI_STREAM_TYPE: u64 = 0x41;

    /// Try to parse a WebTransport uni-stream preface from buf.
    /// Returns: number of bytes consumed and the parsed session_id.
    pub fn parseUniPreface(buf: []const u8) !struct { consumed: usize, session_id: u64 } {
        // Need two varints: stream_type then session_id
        const v1 = try h3_datagram.decodeVarint(buf);
        if (v1.value != UNI_STREAM_TYPE) return error.UnexpectedStreamType;
        if (v1.consumed >= buf.len) return error.BufferTooShort;
        const v2 = try h3_datagram.decodeVarint(buf[v1.consumed..]);
        return .{ .consumed = v1.consumed + v2.consumed, .session_id = v2.value };
    }

    /// Initialize a new WebTransport session
    pub fn init(
        allocator: std.mem.Allocator,
        session_id: u64,
        quic_conn: *quiche.Connection,
        h3_conn: *anyopaque,
        path: []const u8,
    ) !*WebTransportSession {
        const session = try allocator.create(WebTransportSession);
        session.* = .{
            .session_id = session_id,
            .quic_conn = quic_conn,
            .h3_conn = @ptrCast(@alignCast(h3_conn)),
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
        };
        return session;
    }

    /// Clean up session resources
    pub fn deinit(self: *WebTransportSession) void {
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Send a session-bound datagram
    /// The flow_id is the session_id per WebTransport spec
    pub fn sendDatagram(self: *WebTransportSession, payload: []const u8) !void {
        if (self.state != .active) {
            return error.SessionClosed;
        }

        // Calculate space needed for varint-encoded session_id
        const varint_len = h3_datagram.varintLen(self.session_id);
        const total_len = varint_len + payload.len;

        // Check if datagram would exceed maximum size
        const max_dgram = self.quic_conn.dgramMaxWritableLen() orelse return error.DatagramNotEnabled;
        if (total_len > max_dgram) {
            return error.DatagramTooLarge;
        }

        // Use a small stack buffer for typical MTU-sized datagrams to reduce
        // allocation pressure; fall back to heap if larger
        var stack_buf: [2048]u8 = undefined;
        const use_stack = total_len <= stack_buf.len;
        const buf = if (use_stack) stack_buf[0..total_len] else try self.allocator.alloc(u8, total_len);
        defer if (!use_stack) self.allocator.free(buf);

        // Encode session_id as varint (flow_id)
        _ = try h3_datagram.encodeVarint(buf[0..varint_len], self.session_id);

        // Copy payload after varint
        @memcpy(buf[varint_len..], payload);

        // Send via QUIC DATAGRAM
        const written = self.quic_conn.dgramSend(buf) catch |err| {
            // Normalize backpressure to WouldBlock for consistency with server APIs
            if (err == error.Done) return error.WouldBlock;
            return err;
        };

        // Notify caller for accounting if configured
        if (self.on_datagram_sent) |cb| {
            if (self.on_datagram_ctx) |ctx| cb(ctx, written);
        }
    }

    /// Close the WebTransport session
    /// Sends FIN on the CONNECT stream to signal session termination
    pub fn close(self: *WebTransportSession, code: u64, reason: []const u8) !void {
        _ = code; // Close code not used at H3 layer yet
        _ = reason; // Reason text reserved for future use / headers

        if (self.state != .active) return; // Already closing/closed
        self.state = .closing;

        // Send an empty body with FIN on the CONNECT stream to signal
        // WebTransport session termination.
        // The server event loop will drain egress and handle final cleanup.
        _ = self.h3_conn.sendBody(self.quic_conn, self.session_id, "", true) catch |err| {
            // Map backpressure to WouldBlock; caller may retry later.
            if (err == error.Done or err == quiche.h3.Error.StreamBlocked) return error.WouldBlock;
            return err;
        };
    }

    /// Check if session is active
    pub fn isActive(self: *const WebTransportSession) bool {
        return self.state == .active;
    }
};

/// WebTransport session state maintained by the server
pub const WebTransportSessionState = struct {
    /// The session object
    session: *WebTransportSession,

    /// Request headers from the CONNECT request
    request_headers: []const quiche.h3.Header,

    /// Handler callbacks
    on_datagram: ?*const fn (sess: *anyopaque, payload: []const u8) anyerror!void = null,
    on_uni_open: ?*const fn (sess: *anyopaque, stream: *anyopaque) anyerror!void = null,
    on_bidi_open: ?*const fn (sess: *anyopaque, stream: *anyopaque) anyerror!void = null,
    on_stream_data: ?*const fn (stream: *anyopaque, data: []const u8, fin: bool) anyerror!void = null,
    on_stream_closed: ?*const fn (stream: *anyopaque) void = null,

    /// Arena allocator for session lifetime
    arena: std.heap.ArenaAllocator,
    last_activity_ms: i64 = 0,

    /// Initialize session state
    pub fn init(
        allocator: std.mem.Allocator,
        session: *WebTransportSession,
        headers: []const quiche.h3.Header,
        on_datagram: ?*const fn (sess: *anyopaque, payload: []const u8) anyerror!void,
    ) !*WebTransportSessionState {
        const state = try allocator.create(WebTransportSessionState);
        state.* = .{
            .session = session,
            .request_headers = headers,
            .on_datagram = on_datagram,
            .on_uni_open = null,
            .on_bidi_open = null,
            .on_stream_data = null,
            .on_stream_closed = null,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return state;
    }

    /// Clean up session state
    pub fn deinit(self: *WebTransportSessionState, allocator: std.mem.Allocator) void {
        self.session.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    // No capsule types are needed; binding uses per-stream prefaces.
};

// Application error codes for QUIC stream shutdown in WT control paths
// These are internal to the server; adjust or standardize during interop.
pub const APP_ERR_STREAM_LIMIT: u64 = 0x1000;
pub const APP_ERR_INVALID_STREAM: u64 = 0x1001;

// Tests
test "WebTransportSession initialization" {
    const allocator = std.testing.allocator;

    // Mock connection pointers (would be real in production)
    var quic_conn: quiche.Connection = undefined;
    var fake_h3: h3_conn_mod.H3Connection = undefined;

    const session = try WebTransportSession.init(
        allocator,
        42, // session_id
        &quic_conn,
        &fake_h3,
        "/wt/echo",
    );
    defer session.deinit();

    try std.testing.expectEqual(@as(u64, 42), session.session_id);
    try std.testing.expectEqualStrings("/wt/echo", session.path);
    try std.testing.expectEqual(WebTransportSession.State.active, session.state);
}

test "WebTransport varint flow_id encoding" {
    // Test that session_id values encode correctly as varints
    // Session IDs are stream IDs, which can be large values

    var buf: [8]u8 = undefined;

    // Small session_id (1-byte varint)
    {
        const len = try h3_datagram.encodeVarint(&buf, 4); // Client-initiated bidi stream
        try std.testing.expectEqual(@as(usize, 1), len);
    }

    // Medium session_id (2-byte varint)
    {
        const len = try h3_datagram.encodeVarint(&buf, 256); // Larger stream ID
        try std.testing.expectEqual(@as(usize, 2), len);
    }

    // Large session_id (4-byte varint)
    {
        const len = try h3_datagram.encodeVarint(&buf, 65536); // Very large stream ID
        try std.testing.expectEqual(@as(usize, 4), len);
    }
}

test "parseUniPreface success and wrong type" {
    // Build a preface: [UNI_STREAM_TYPE][session_id]
    var buf: [16]u8 = undefined;
    var off: usize = 0;
    off += try h3_datagram.encodeVarint(buf[off..], WebTransportSession.UNI_STREAM_TYPE);
    off += try h3_datagram.encodeVarint(buf[off..], 1234);

    const ok = try WebTransportSession.parseUniPreface(buf[0..off]);
    try std.testing.expectEqual(@as(usize, off), ok.consumed);
    try std.testing.expectEqual(@as(u64, 1234), ok.session_id);

    // Wrong type should fail with UnexpectedStreamType
    var bad: [8]u8 = undefined;
    var o2: usize = 0;
    o2 += try h3_datagram.encodeVarint(bad[o2..], WebTransportSession.UNI_STREAM_TYPE + 1);
    o2 += try h3_datagram.encodeVarint(bad[o2..], 1);
    try std.testing.expectError(error.UnexpectedStreamType, WebTransportSession.parseUniPreface(bad[0..o2]));
}
