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
        self.conn.sendResponse(quic_conn, stream_id, headers, fin) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked) {
                // Will retry on next poll
                return;
            }
            return err;
        };
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
    
    pub const PollResult = struct {
        stream_id: u64,
        event_type: quiche.h3.EventType,
        raw_event: *quiche.c.quiche_h3_event,
        
        pub fn deinit(self: *PollResult) void {
            quiche.h3.eventFree(self.raw_event);
        }
    };
};