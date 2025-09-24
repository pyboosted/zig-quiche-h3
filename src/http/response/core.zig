const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const Status = @import("../handler.zig").Status;
const Headers = @import("../handler.zig").Headers;
const streaming = @import("../streaming.zig");
const wt_capsules = @import("../webtransport_capsules.zig");

pub const Response = struct {
    pub const Trailer = struct {
        name: []const u8,
        value: []const u8,
    };

    h3_conn: *h3.H3Connection,
    quic_conn: *quiche.Connection,
    stream_id: u64,
    h3_flow_id: ?u64 = null,
    headers_sent: bool,
    ended: bool,
    status_code: u16,
    header_buffer: std.ArrayList(quiche.h3.Header),
    allocator: std.mem.Allocator,
    is_head_request: bool,
    partial_response: ?*streaming.PartialResponse,

    limiter_ctx: ?*anyopaque = null,
    on_start_streaming: ?*const fn (ctx: *anyopaque, quic_conn: *quiche.Connection, stream_id: u64, source_kind: u8) bool = null,
    limiter_checked: bool = false,

    cleanup_ctx: ?*anyopaque = null,
    cleanup_cb: ?*const fn (ctx: ?*anyopaque) void = null,

    auto_end_enabled: bool = true,

    // MILESTONE-1: Buffer for pending capsule data
    capsule_buffer: ?[]u8 = null,
    capsule_buffer_len: usize = 0,
    capsule_buffer_sent: usize = 0,

    pub const WebTransportAcceptOptions = struct {
        send_legacy_accept: bool = true,
        extra_capsules: []const wt_capsules.Capsule = &[_]wt_capsules.Capsule{},
    };

    pub fn init(
        allocator: std.mem.Allocator,
        h3_conn: *h3.H3Connection,
        quic_conn: *quiche.Connection,
        stream_id: u64,
        is_head_request: bool,
    ) Response {
        return Response{
            .h3_conn = h3_conn,
            .quic_conn = quic_conn,
            .stream_id = stream_id,
            .h3_flow_id = null,
            .headers_sent = false,
            .ended = false,
            .status_code = 200,
            .header_buffer = std.ArrayList(quiche.h3.Header){},
            .allocator = allocator,
            .is_head_request = is_head_request,
            .partial_response = null,
            .limiter_ctx = null,
            .on_start_streaming = null,
            .limiter_checked = false,
            .cleanup_ctx = null,
            .cleanup_cb = null,
            .auto_end_enabled = true,
        };
    }

    pub fn deinit(self: *Response) void {
        self.runCleanup();
        for (self.header_buffer.items) |hdr| {
            self.allocator.free(hdr.name[0..hdr.name_len]);
            self.allocator.free(hdr.value[0..hdr.value_len]);
        }
        self.header_buffer.deinit(self.allocator);

        if (self.partial_response) |partial| {
            partial.deinit();
            self.partial_response = null;
        }

        // Free capsule buffer if allocated
        if (self.capsule_buffer) |buf| {
            self.allocator.free(buf);
            self.capsule_buffer = null;
        }
    }

    pub fn onCleanup(self: *Response, ctx: ?*anyopaque, cb: *const fn (ctx: ?*anyopaque) void) void {
        self.cleanup_ctx = ctx;
        self.cleanup_cb = cb;
    }

    pub fn clearCleanup(self: *Response) void {
        self.cleanup_ctx = null;
        self.cleanup_cb = null;
    }

    pub fn deferEnd(self: *Response) void {
        self.auto_end_enabled = false;
    }

    pub fn enableAutoEnd(self: *Response) void {
        self.auto_end_enabled = true;
    }

    pub fn shouldAutoEnd(self: Response) bool {
        return self.auto_end_enabled;
    }

    fn runCleanup(self: *Response) void {
        if (self.cleanup_cb) |cb| {
            cb(self.cleanup_ctx);
            self.cleanup_ctx = null;
            self.cleanup_cb = null;
        }
    }

    pub fn status(self: *Response, code: u16) !void {
        if (self.headers_sent) return error.HeadersAlreadySent;
        self.status_code = code;
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        if (self.headers_sent) return error.HeadersAlreadySent;

        const name_copy = try self.allocator.dupe(u8, name);
        const value_copy = try self.allocator.dupe(u8, value);

        try self.header_buffer.append(self.allocator, quiche.h3.Header{
            .name = name_copy.ptr,
            .name_len = name_copy.len,
            .value = value_copy.ptr,
            .value_len = value_copy.len,
        });
    }

    pub fn setStreamingLimiter(
        self: *Response,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, quic_conn: *quiche.Connection, stream_id: u64, source_kind: u8) bool,
    ) void {
        self.limiter_ctx = ctx;
        self.on_start_streaming = cb;
    }

    pub fn sendTrailers(self: *Response, trailers: []const Trailer) !void {
        if (self.ended) return error.ResponseEnded;
        if (self.is_head_request) return error.InvalidState;

        if (!self.headers_sent) {
            self.sendHeaders(false) catch |err| {
                if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                    _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                    return error.StreamBlocked;
                }
                return err;
            };
        }

        var list = std.ArrayList(quiche.h3.Header){};
        defer {
            for (list.items) |hdr| {
                self.allocator.free(hdr.name[0..hdr.name_len]);
                self.allocator.free(hdr.value[0..hdr.value_len]);
            }
            list.deinit(self.allocator);
        }
        for (trailers) |t| {
            const name_copy = try self.allocator.dupe(u8, t.name);
            const value_copy = try self.allocator.dupe(u8, t.value);
            try list.append(self.allocator, quiche.h3.Header{
                .name = name_copy.ptr,
                .name_len = name_copy.len,
                .value = value_copy.ptr,
                .value_len = value_copy.len,
            });
        }

        try self.h3_conn.sendAdditionalHeaders(
            self.quic_conn,
            self.stream_id,
            list.items,
            true,
            true,
        );

        self.ended = true;
    }

    pub fn redirect(self: *Response, code: u16, location: []const u8) !void {
        if (code < 300 or code >= 400) return error.InvalidRedirectStatus;
        try self.status(code);
        try self.header(Headers.Location, location);
        try self.end(null);
    }

    pub fn setAcceptRangesBytes(self: *Response) !void {
        try self.header(Headers.AcceptRanges, "bytes");
    }

    pub fn setContentRange(self: *Response, start: u64, end_offset: u64, total_size: u64) !void {
        var buf: [100]u8 = undefined;
        const range_str = try std.fmt.bufPrint(&buf, "bytes {d}-{d}/{d}", .{ start, end_offset, total_size });
        try self.header(Headers.ContentRange, range_str);
    }

    pub fn setContentRangeUnsatisfied(self: *Response, total_size: u64) !void {
        var buf: [100]u8 = undefined;
        const range_str = try std.fmt.bufPrint(&buf, "bytes */{d}", .{total_size});
        try self.header(Headers.ContentRange, range_str);
    }

    pub fn setContentLength(self: *Response, length: u64) !void {
        var buf: [32]u8 = undefined;
        const len_str = try std.fmt.bufPrint(&buf, "{d}", .{length});
        try self.header(Headers.ContentLength, len_str);
    }

    pub fn isHeadersSent(self: Response) bool {
        return self.headers_sent;
    }

    pub fn isEnded(self: Response) bool {
        return self.ended;
    }

    /// MILESTONE-1: Send 200 OK for WebTransport CONNECT without closing the stream
    /// This enables the CONNECT stream to stay open for capsule exchange
    pub fn finishConnect(self: *Response, flow_id: ?u64) !void {
        try self.finishWebTransportConnect(flow_id, .{});
    }

    pub fn finishWebTransportConnect(
        self: *Response,
        flow_id: ?u64,
        options: WebTransportAcceptOptions,
    ) !void {
        if (self.headers_sent) return error.HeadersAlreadySent;

        try self.status(200);
        try self.header("sec-webtransport-http3-draft", "draft02");

        if (flow_id) |id| {
            var buf: [32]u8 = undefined;
            const flow_str = try std.fmt.bufPrint(&buf, "{d}", .{id});
            try self.header("datagram-flow-id", flow_str);
        }

        try self.sendHeaders(false);

        if (options.send_legacy_accept) {
            try self.sendLegacySessionAcceptCapsule();
        }

        for (options.extra_capsules) |capsule| {
            try self.sendWebTransportCapsule(capsule);
        }

        self.deferEnd();
    }

    /// Send a minimal legacy SESSION_ACCEPT capsule after 200 OK
    fn sendLegacySessionAcceptCapsule(self: *Response) !void {
        var buf: [16]u8 = undefined;
        var offset: usize = 0;
        offset += try encodeQuicVarint(buf[offset..], 0x3c);
        offset += try encodeQuicVarint(buf[offset..], 0);
        try self.writeCapsuleBytes(buf[0..offset]);
    }

    pub fn sendWebTransportCapsule(self: *Response, capsule: wt_capsules.Capsule) !void {
        var stack: [64]u8 = undefined;
        const needed = capsule.maxEncodedLen();
        const buf = if (needed <= stack.len)
            stack[0..needed]
        else
            try self.allocator.alloc(u8, needed);
        defer if (needed > stack.len) self.allocator.free(buf);

        const written = try capsule.encode(buf);
        try self.writeCapsuleBytes(buf[0..written]);
    }

    pub fn sendWebTransportClose(self: *Response, code: u32, reason: []const u8) !void {
        const capsule = wt_capsules.Capsule{
            .close_session = .{ .application_error_code = code, .reason = reason },
        };
        try self.sendWebTransportCapsule(capsule);
    }

    pub fn rejectConnect(self: *Response, status_code: u16) !void {
        if (self.headers_sent) return error.HeadersAlreadySent;
        try self.status(status_code);
        try self.sendHeaders(true);
        self.ended = true;
    }

    fn writeCapsuleBytes(self: *Response, data: []const u8) !void {
        if (data.len == 0) return;

        const sent = self.quic_conn.streamSend(self.stream_id, data, false) catch |err| {
            if (err == quiche.QuicheError.Done or err == quiche.QuicheError.FlowControl) {
                try self.bufferCapsuleData(data);
                _ = self.quic_conn.streamWritable(self.stream_id, data.len) catch {};
                return;
            }
            return err;
        };

        if (sent < data.len) {
            try self.bufferCapsuleData(data[sent..]);
            _ = self.quic_conn.streamWritable(self.stream_id, data.len - sent) catch {};
        }
    }

    /// Buffer capsule data for retry when stream becomes writable
    fn bufferCapsuleData(self: *Response, data: []const u8) !void {
        if (data.len == 0) return;

        // Allocate buffer if not already allocated
        if (self.capsule_buffer == null) {
            const initial = if (data.len > 256) data.len else 256;
            self.capsule_buffer = try self.allocator.alloc(u8, initial);
            self.capsule_buffer_len = 0;
            self.capsule_buffer_sent = 0;
        }

        // Ensure buffer has enough space
        const needed = self.capsule_buffer_len + data.len;
        if (needed > self.capsule_buffer.?.len) {
            // Grow buffer
            const new_size = @max(needed, self.capsule_buffer.?.len * 2);
            const new_buffer = try self.allocator.alloc(u8, new_size);
            @memcpy(new_buffer[0..self.capsule_buffer_len], self.capsule_buffer.?[0..self.capsule_buffer_len]);
            self.allocator.free(self.capsule_buffer.?);
            self.capsule_buffer = new_buffer;
        }

        // Copy data to buffer
        @memcpy(self.capsule_buffer.?[self.capsule_buffer_len..][0..data.len], data);
        self.capsule_buffer_len += data.len;
    }

    /// Try to flush buffered capsule data when stream becomes writable
    pub fn flushCapsuleBuffer(self: *Response) !void {
        if (self.capsule_buffer == null or self.capsule_buffer_sent >= self.capsule_buffer_len) {
            return; // Nothing to flush
        }

        const remaining = self.capsule_buffer_len - self.capsule_buffer_sent;
        const to_send = self.capsule_buffer.?[self.capsule_buffer_sent..self.capsule_buffer_len];

        const sent = self.quic_conn.streamSend(self.stream_id, to_send, false) catch |err| {
            if (err == quiche.QuicheError.Done or err == quiche.QuicheError.FlowControl) {
                // Still blocked, will retry later
                _ = self.quic_conn.streamWritable(self.stream_id, remaining) catch {};
                return;
            }
            return err;
        };

        self.capsule_buffer_sent += sent;

        // If all data sent, we can clear the buffer
        if (self.capsule_buffer_sent >= self.capsule_buffer_len) {
            self.allocator.free(self.capsule_buffer.?);
            self.capsule_buffer = null;
            self.capsule_buffer_len = 0;
            self.capsule_buffer_sent = 0;
        } else {
            // Still have data to send, register for writable again
            _ = self.quic_conn.streamWritable(self.stream_id, remaining - sent) catch {};
        }
    }

    pub fn sendHeaders(self: *Response, fin: bool) !void {
        if (self.headers_sent) return;

        var final_headers = std.ArrayList(quiche.h3.Header){};
        defer final_headers.deinit(self.allocator);

        var status_buf: [5]u8 = undefined;
        const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{self.status_code});

        // Create status header value - HTTP/3 requires only numeric status code
        // without the reason phrase in the :status pseudo-header
        const status_value = try self.allocator.dupe(u8, status_str);

        // Ensure status_value is freed after headers are sent
        defer self.allocator.free(status_value);

        // Add to final_headers for sending
        try final_headers.append(self.allocator, quiche.h3.Header{
            .name = ":status",
            .name_len = 7,
            .value = status_value.ptr,
            .value_len = status_value.len,
        });

        var has_server = false;
        for (self.header_buffer.items) |hdr| {
            const name = hdr.name[0..hdr.name_len];
            if (std.ascii.eqlIgnoreCase(name, "server")) {
                has_server = true;
                break;
            }
        }
        if (!has_server) {
            try final_headers.append(self.allocator, quiche.h3.Header{
                .name = "server",
                .name_len = 6,
                .value = "zig-quiche-h3",
                .value_len = 13,
            });
        }

        try final_headers.appendSlice(self.allocator, self.header_buffer.items);

        self.h3_conn.sendResponse(
            self.quic_conn,
            self.stream_id,
            final_headers.items,
            fin and self.is_head_request,
        ) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                if (self.partial_response == null) {
                    const empty = try self.allocator.alloc(u8, 0);
                    self.partial_response = try streaming.PartialResponse.initMemory(self.allocator, empty, false);
                }
                return err;
            }
            return err;
        };

        self.headers_sent = true;
    }

    pub fn write(self: *Response, data: []const u8) !usize {
        return @import("body.zig").write(Response, self, data);
    }

    pub fn writeAll(self: *Response, data: []const u8) !void {
        return @import("body.zig").writeAll(Response, self, data);
    }

    pub fn end(self: *Response, data: ?[]const u8) !void {
        return @import("body.zig").end(Response, self, data);
    }

    pub fn json(self: *Response, json_str: []const u8) !void {
        return @import("body.zig").json(Response, self, json_str);
    }

    pub fn jsonValue(self: *Response, value: anytype) !void {
        return @import("body.zig").jsonValue(Response, self, value);
    }

    pub fn jsonError(self: *Response, code: u16, message: []const u8) !void {
        return @import("body.zig").jsonError(Response, self, code, message);
    }

    pub fn sendFile(self: *Response, file_path: []const u8) !void {
        return @import("streaming_ext.zig").sendFile(Response, self, file_path);
    }

    pub fn processPartialResponse(self: *Response) !void {
        return @import("streaming_ext.zig").processPartialResponse(Response, self);
    }

    pub fn sendH3Datagram(self: *Response, payload: []const u8) !void {
        return @import("datagram.zig").sendH3Datagram(Response, self, payload);
    }
};

/// Encode a value as a QUIC variable-length integer
/// Follows RFC 9000 Section 16: Variable-Length Integer Encoding
fn encodeQuicVarint(buf: []u8, value: u64) !usize {
    if (value < 64) { // 6-bit value (2^6)
        if (buf.len < 1) return error.BufferTooSmall;
        buf[0] = @intCast(value);
        return 1;
    } else if (value < 16384) { // 14-bit value (2^14)
        if (buf.len < 2) return error.BufferTooSmall;
        buf[0] = @intCast(0x40 | (value >> 8));
        buf[1] = @intCast(value & 0xff);
        return 2;
    } else if (value < 1073741824) { // 30-bit value (2^30)
        if (buf.len < 4) return error.BufferTooSmall;
        buf[0] = @intCast(0x80 | (value >> 24));
        buf[1] = @intCast((value >> 16) & 0xff);
        buf[2] = @intCast((value >> 8) & 0xff);
        buf[3] = @intCast(value & 0xff);
        return 4;
    } else { // 62-bit value
        if (buf.len < 8) return error.BufferTooSmall;
        buf[0] = @intCast(0xc0 | (value >> 56));
        buf[1] = @intCast((value >> 48) & 0xff);
        buf[2] = @intCast((value >> 40) & 0xff);
        buf[3] = @intCast((value >> 32) & 0xff);
        buf[4] = @intCast((value >> 24) & 0xff);
        buf[5] = @intCast((value >> 16) & 0xff);
        buf[6] = @intCast((value >> 8) & 0xff);
        buf[7] = @intCast(value & 0xff);
        return 8;
    }
}

test "encodeQuicVarint encodes canonical lengths" {
    var buf: [8]u8 = undefined;
    var out = try encodeQuicVarint(buf[0..], 0x1f);
    try std.testing.expectEqual(@as(usize, 1), out);
    try std.testing.expectEqual(@as(u8, 0x1f), buf[0]);

    out = try encodeQuicVarint(buf[0..], 0x1234);
    try std.testing.expectEqual(@as(usize, 2), out);
    try std.testing.expectEqual(@as(u8, 0x52), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);

    out = try encodeQuicVarint(buf[0..], 0x1234abcd);
    try std.testing.expectEqual(@as(usize, 4), out);
    try std.testing.expectEqual(@as(u8, 0x92), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);
    try std.testing.expectEqual(@as(u8, 0xab), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xcd), buf[3]);

    out = try encodeQuicVarint(buf[0..], 0x1234abcd1234abcd);
    try std.testing.expectEqual(@as(usize, 8), out);
    try std.testing.expectEqual(@as(u8, 0xd2), buf[0]);
}
