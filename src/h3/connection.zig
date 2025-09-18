const std = @import("std");
const quiche = @import("quiche");
const H3Config = @import("config.zig").H3Config;

// H3 Connection wrapper
pub const H3Connection = struct {
    conn: quiche.h3.Connection,
    allocator: std.mem.Allocator,

    pub fn newWithTransport(
        allocator: std.mem.Allocator,
        quic_conn: *quiche.Connection,
        config: *H3Config,
    ) !H3Connection {
        const h3_conn = try quiche.h3.Connection.newWithTransport(quic_conn, &config.config);
        return H3Connection{
            .conn = h3_conn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *H3Connection) void {
        self.conn.deinit();
    }

    // Poll for events - returns null on Done error
    pub fn poll(self: *H3Connection, quic_conn: *quiche.Connection) ?PollResult {
        const result = self.conn.poll(quic_conn) catch |err| {
            if (err == quiche.h3.Error.Done) {
                return null; // No more events
            }
            // Log other errors but continue
            std.debug.print("H3 poll error: {}\n", .{err});
            return null;
        };

        if (result.event) |event| {
            return PollResult{
                .stream_id = result.stream_id,
                .event_type = quiche.h3.eventType(event),
                .raw_event = event,
            };
        }

        return null;
    }

    pub fn sendResponse(
        self: *H3Connection,
        quic_conn: *quiche.Connection,
        stream_id: u64,
        headers: []const quiche.h3.Header,
        fin: bool,
    ) !void {
        // Propagate all errors including StreamBlocked for proper retry handling
        try self.conn.sendResponse(quic_conn, stream_id, headers, fin);
    }

    pub fn sendBody(
        self: *H3Connection,
        quic_conn: *quiche.Connection,
        stream_id: u64,
        body: []const u8,
        fin: bool,
    ) !usize {
        return self.conn.sendBody(quic_conn, stream_id, body, fin) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked) {
                // Will retry on next poll
                return 0;
            }
            return err;
        };
    }

    pub fn sendRequest(
        self: *H3Connection,
        quic_conn: *quiche.Connection,
        headers: []const quiche.h3.Header,
        fin: bool,
    ) !u64 {
        return self.conn.sendRequest(quic_conn, headers, fin);
    }

    pub fn sendAdditionalHeaders(
        self: *H3Connection,
        quic_conn: *quiche.Connection,
        stream_id: u64,
        headers: []const quiche.h3.Header,
        is_trailer_section: bool,
        fin: bool,
    ) !void {
        try self.conn.sendAdditionalHeaders(quic_conn, stream_id, headers, is_trailer_section, fin);
    }

    pub fn recvBody(
        self: *H3Connection,
        quic_conn: *quiche.Connection,
        stream_id: u64,
        out: []u8,
    ) !usize {
        return self.conn.recvBody(quic_conn, stream_id, out) catch |err| {
            if (err == quiche.h3.Error.Done) {
                return 0; // No more data
            }
            return err;
        };
    }

    /// Check if H3 DATAGRAM is enabled by peer (negotiated via SETTINGS)
    pub fn dgramEnabledByPeer(self: *H3Connection, quic_conn: *quiche.Connection) bool {
        return self.conn.dgramEnabledByPeer(quic_conn);
    }

    /// Check if Extended CONNECT is enabled by peer (negotiated via SETTINGS)
    pub fn extendedConnectEnabledByPeer(self: *H3Connection) bool {
        return self.conn.extendedConnectEnabledByPeer();
    }

    /// Client-specific: Send request with header validation
    /// Validates that required pseudo-headers are present before sending
    pub fn sendClientRequest(
        self: *H3Connection,
        quic_conn: *quiche.Connection,
        headers: []const quiche.h3.Header,
        fin: bool,
    ) !u64 {
        // Validate required pseudo-headers for client requests
        var has_method = false;
        var has_scheme = false;
        var has_authority = false;
        var has_path = false;

        for (headers) |h| {
            if (h.name.len > 0 and h.name[0] == ':') {
                if (std.mem.eql(u8, h.name, ":method")) has_method = true;
                if (std.mem.eql(u8, h.name, ":scheme")) has_scheme = true;
                if (std.mem.eql(u8, h.name, ":authority")) has_authority = true;
                if (std.mem.eql(u8, h.name, ":path")) has_path = true;
            }
        }

        if (!has_method or !has_scheme or !has_authority or !has_path) {
            return error.MissingRequiredPseudoHeaders;
        }

        // Use the existing sendRequest after validation
        return self.sendRequest(quic_conn, headers, fin);
    }

    /// Client-specific: Send Extended CONNECT for WebTransport
    /// Automatically adds the :protocol pseudo-header if missing
    pub fn sendExtendedConnect(
        self: *H3Connection,
        quic_conn: *quiche.Connection,
        headers: []const quiche.h3.Header,
        fin: bool,
    ) !u64 {
        // Check if peer supports Extended CONNECT
        if (!self.extendedConnectEnabledByPeer()) {
            return error.ExtendedConnectNotSupported;
        }

        // Validate that this is a CONNECT request with :protocol
        var has_method_connect = false;
        var has_protocol = false;

        for (headers) |h| {
            if (std.mem.eql(u8, h.name, ":method") and std.mem.eql(u8, h.value, "CONNECT")) {
                has_method_connect = true;
            }
            if (std.mem.eql(u8, h.name, ":protocol")) {
                has_protocol = true;
            }
        }

        if (!has_method_connect) {
            return error.NotConnectMethod;
        }
        if (!has_protocol) {
            return error.MissingProtocolPseudoHeader;
        }

        // Send as regular request - quiche handles Extended CONNECT internally
        return self.sendRequest(quic_conn, headers, fin);
    }

    /// Client-specific: Check if we can send new requests
    /// Returns false if connection is closing or GOAWAY received
    pub fn canSendRequest(self: *H3Connection) bool {
        // This would need access to GOAWAY state
        // For now, always return true - will be enhanced when GOAWAY tracking is added
        _ = self;
        return true;
    }

    pub const PollResult = struct {
        stream_id: u64,
        event_type: quiche.h3.EventType,
        raw_event: *quiche.c.quiche_h3_event,

        pub fn deinit(self: *PollResult) void {
            quiche.h3.eventFree(self.raw_event);
        }
    };
};
