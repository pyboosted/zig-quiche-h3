const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const h3_datagram = h3.datagram;
const client = @import("mod.zig");

/// Client-side WebTransport session management
/// IMPORTANT: Client can only originate WebTransport streams - peer-initiated
/// streams are not surfaced by the quiche C API
pub const WebTransportSession = struct {
    /// The CONNECT stream ID that established this session (reuses FetchState stream_id)
    session_id: u64,

    /// Reference to the client that owns this session
    client: *client.QuicClient,

    /// Session state tracking
    state: State = .connecting,

    /// Path used in the CONNECT request
    path: []const u8,

    /// Datagram statistics for this session
    datagrams_sent: u64 = 0,
    datagrams_received: u64 = 0,

    /// User data pointer for application state
    user_data: ?*anyopaque = null,

    /// Queue for received datagrams
    datagram_queue: std.ArrayList([]u8),

    pub const State = enum {
        connecting, // CONNECT request sent, awaiting response
        established, // 200 response received
        closed, // Session terminated
    };

    /// Check if this session is affected by GOAWAY
    pub fn isGoingAway(self: *const WebTransportSession) bool {
        return self.client.goaway_received and
            self.session_id > (self.client.goaway_stream_id orelse std.math.maxInt(u64));
    }

    /// Send a datagram on this WebTransport session
    /// The datagram will be prefixed with the session_id as a varint
    pub fn sendDatagram(self: *WebTransportSession, payload: []const u8) !void {
        if (self.state != .established) {
            return error.SessionNotEstablished;
        }

        if (self.isGoingAway()) {
            return error.GoAwayReceived;
        }

        const conn = try self.client.requireConn();

        // Calculate varint size for session_id prefix
        const varint_len = h3_datagram.varintLen(self.session_id);
        const total_len = varint_len + payload.len;

        // Check datagram capacity
        const max_len = conn.dgramMaxWritableLen() orelse
            return error.DatagramNotEnabled;
        if (total_len > max_len) {
            return error.DatagramTooLarge;
        }

        // Allocate buffer for prefixed datagram
        var stack_buf: [2048]u8 = undefined; // Hoist outside to maintain scope
        var buf: []u8 = undefined;
        var use_heap = false;

        if (total_len <= 2048) {
            // Use stack buffer for small datagrams
            buf = stack_buf[0..total_len];
        } else {
            // Allocate on heap for large datagrams
            buf = try self.client.allocator.alloc(u8, total_len);
            use_heap = true;
        }
        defer if (use_heap) self.client.allocator.free(buf);

        // Encode session_id as varint prefix
        const written = try h3_datagram.encodeVarint(buf, self.session_id);
        std.debug.assert(written == varint_len);

        // Copy payload after prefix
        @memcpy(buf[written..], payload);

        // Send via QUIC datagram
        const sent = conn.dgramSend(buf) catch |err| {
            if (err == error.Done) return error.DatagramSendFailed;
            return error.DatagramSendFailed;
        };

        if (sent != buf.len) {
            return error.DatagramSendFailed;
        }

        self.datagrams_sent += 1;
        self.client.datagram_stats.sent += 1;

        // Flush and update timers
        self.client.flushSend() catch |err| return err;
        self.client.afterQuicProgress();
    }

    /// Receive a queued datagram if available
    /// Caller owns the returned memory and must free it
    pub fn receiveDatagram(self: *WebTransportSession) ?[]u8 {
        if (self.datagram_queue.items.len == 0) return null;
        return self.datagram_queue.orderedRemove(0);
    }

    /// Queue an incoming datagram for this session
    /// Called internally by the client when processing H3 datagrams
    pub fn queueDatagram(self: *WebTransportSession, payload: []const u8) !void {
        const copy = try self.client.allocator.dupe(u8, payload);
        errdefer self.client.allocator.free(copy);
        try self.datagram_queue.append(self.client.allocator, copy);
        self.datagrams_received += 1;
    }

    /// Handle state transition when CONNECT response is received
    pub fn handleConnectResponse(self: *WebTransportSession, status: u16) void {
        switch (status) {
            200 => {
                self.state = .established;
                // Session successfully established
            },
            else => {
                self.state = .closed;
                // Session rejected by server
            },
        }
    }

    /// Close the WebTransport session and free all resources
    /// After calling this, the session pointer is no longer valid
    pub fn close(self: *WebTransportSession) void {
        // Save these before potential destruction
        const session_id = self.session_id;
        const client_ref = self.client;

        // Mark as closed first
        self.state = .closed;

        // Clean up the FetchState if it still exists (for successful sessions)
        if (client_ref.requests.get(session_id)) |state| {
            _ = client_ref.requests.remove(session_id);
            state.destroy();
        }

        // Check if we're still tracked by the client
        if (client_ref.wt_sessions.contains(session_id)) {
            // If tracked, let cleanup helper handle everything including queue cleanup
            client_ref.cleanupWebTransportSession(session_id);
        } else {
            // If not tracked (user owns it after finalizeFetch), handle cleanup here
            // Clean up any queued datagrams
            for (self.datagram_queue.items) |dgram| {
                client_ref.allocator.free(dgram);
            }
            self.datagram_queue.deinit(client_ref.allocator);
            // Free path and destroy
            client_ref.allocator.free(self.path);
            client_ref.allocator.destroy(self);
        }
        // Do not access self after this point
    }
};

/// Helper to check if headers indicate WebTransport CONNECT
pub fn isWebTransportConnect(headers: []const client.HeaderPair) bool {
    var has_connect = false;
    var has_protocol = false;

    for (headers) |pair| {
        if (std.mem.eql(u8, pair.name, ":method") and std.mem.eql(u8, pair.value, "CONNECT")) {
            has_connect = true;
        } else if (std.mem.eql(u8, pair.name, ":protocol") and std.mem.eql(u8, pair.value, "webtransport")) {
            has_protocol = true;
        }
    }

    return has_connect and has_protocol;
}

/// Build Extended CONNECT headers for WebTransport
pub fn buildWebTransportHeaders(
    allocator: std.mem.Allocator,
    authority: []const u8,
    path: []const u8,
    extra_headers: []const client.HeaderPair,
) ![]quiche.h3.Header {
    const base_count: usize = 5; // Core WebTransport headers
    const total = base_count + extra_headers.len;

    var headers = try allocator.alloc(quiche.h3.Header, total);
    headers[0] = makeHeader(":method", "CONNECT");
    headers[1] = makeHeader(":protocol", "webtransport");
    headers[2] = makeHeader(":scheme", "https");
    headers[3] = makeHeader(":authority", authority);
    headers[4] = makeHeader(":path", path);

    // Add any extra headers
    for (extra_headers, base_count..) |pair, idx| {
        headers[idx] = makeHeader(pair.name, pair.value);
    }

    return headers;
}

fn makeHeader(name_literal: []const u8, value_slice: []const u8) quiche.h3.Header {
    return .{
        .name = name_literal.ptr,
        .name_len = name_literal.len,
        .value = value_slice.ptr,
        .value_len = value_slice.len,
    };
}

// ===== Unit Tests =====
const testing = std.testing;

test "WebTransport: isWebTransportConnect identifies Extended CONNECT" {
    const headers_wt = [_]client.HeaderPair{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":protocol", .value = "webtransport" },
        .{ .name = ":path", .value = "/wt" },
    };

    const headers_regular = [_]client.HeaderPair{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
    };

    const headers_connect_only = [_]client.HeaderPair{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":path", .value = "/" },
    };

    try testing.expect(isWebTransportConnect(&headers_wt));
    try testing.expect(!isWebTransportConnect(&headers_regular));
    try testing.expect(!isWebTransportConnect(&headers_connect_only));
}

test "WebTransport: buildWebTransportHeaders creates valid headers" {
    const allocator = testing.allocator;
    const authority = "example.com:443";
    const path = "/webtransport";
    const extra_headers = [_]client.HeaderPair{
        .{ .name = "origin", .value = "https://example.com" },
    };

    const headers = try buildWebTransportHeaders(
        allocator,
        authority,
        path,
        &extra_headers,
    );
    defer allocator.free(headers);

    try testing.expect(headers.len == 6);

    // Check core headers
    try testing.expectEqualStrings(headers[0].name[0..headers[0].name_len], ":method");
    try testing.expectEqualStrings(headers[0].value[0..headers[0].value_len], "CONNECT");

    try testing.expectEqualStrings(headers[1].name[0..headers[1].name_len], ":protocol");
    try testing.expectEqualStrings(headers[1].value[0..headers[1].value_len], "webtransport");

    try testing.expectEqualStrings(headers[2].name[0..headers[2].name_len], ":scheme");
    try testing.expectEqualStrings(headers[2].value[0..headers[2].value_len], "https");

    try testing.expectEqualStrings(headers[3].name[0..headers[3].name_len], ":authority");
    try testing.expectEqualStrings(headers[3].value[0..headers[3].value_len], authority);

    try testing.expectEqualStrings(headers[4].name[0..headers[4].name_len], ":path");
    try testing.expectEqualStrings(headers[4].value[0..headers[4].value_len], path);

    // Check extra header
    try testing.expectEqualStrings(headers[5].name[0..headers[5].name_len], "origin");
    try testing.expectEqualStrings(headers[5].value[0..headers[5].value_len], "https://example.com");
}

test "WebTransport: varint encoding for session IDs" {
    // Test various session ID sizes
    const test_cases = [_]struct { id: u64, expected_len: usize }{
        .{ .id = 0, .expected_len = 1 },
        .{ .id = 63, .expected_len = 1 },
        .{ .id = 64, .expected_len = 2 },
        .{ .id = 16383, .expected_len = 2 },
        .{ .id = 16384, .expected_len = 4 },
        .{ .id = 1073741823, .expected_len = 4 },
        .{ .id = 1073741824, .expected_len = 8 },
    };

    for (test_cases) |tc| {
        const len = h3_datagram.varintLen(tc.id);
        try testing.expectEqual(tc.expected_len, len);

        // Test encoding/decoding round-trip
        var buf: [8]u8 = undefined;
        const encoded_len = try h3_datagram.encodeVarint(&buf, tc.id);
        try testing.expectEqual(tc.expected_len, encoded_len);

        const decoded = try h3_datagram.decodeVarint(buf[0..encoded_len]);
        try testing.expectEqual(tc.id, decoded.value);
        try testing.expectEqual(tc.expected_len, decoded.len);
    }
}
