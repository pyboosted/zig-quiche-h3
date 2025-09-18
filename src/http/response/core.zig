const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const Status = @import("../handler.zig").Status;
const Headers = @import("../handler.zig").Headers;
const streaming = @import("../streaming.zig");

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
        };
    }

    pub fn deinit(self: *Response) void {
        for (self.header_buffer.items) |hdr| {
            self.allocator.free(hdr.name[0..hdr.name_len]);
            self.allocator.free(hdr.value[0..hdr.value_len]);
        }
        self.header_buffer.deinit(self.allocator);

        if (self.partial_response) |partial| {
            partial.deinit();
            self.partial_response = null;
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
