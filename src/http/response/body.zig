const std = @import("std");
const quiche = @import("quiche");
const Headers = @import("../handler.zig").Headers;
const streaming = @import("../streaming.zig");

pub fn write(comptime Response: type, self: *Response, data: []const u8) !usize {
    if (self.ended) return error.ResponseEnded;
    if (self.is_head_request) return data.len;

    if (!self.headers_sent) {
        self.sendHeaders(false) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                if (self.partial_response == null) {
                    const data_copy = try self.allocator.dupe(u8, data);
                    self.partial_response = try streaming.PartialResponse.initMemory(
                        self.allocator,
                        data_copy,
                        true,
                    );
                }
                return error.StreamBlocked;
            }
            return err;
        };
    }

    const written = self.h3_conn.sendBody(self.quic_conn, self.stream_id, data, false) catch |err| {
        if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
            _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
            return 0;
        }
        return err;
    };

    return written;
}

pub fn writeAll(comptime Response: type, self: *Response, data: []const u8) !void {
    if (self.ended) return error.ResponseEnded;
    if (self.is_head_request) return;

    if (!self.headers_sent) {
        self.sendHeaders(false) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                return;
            }
            return err;
        };
    }

    var written: usize = 0;
    while (written < data.len) {
        const remaining = data[written..];
        const n = self.h3_conn.sendBody(self.quic_conn, self.stream_id, remaining, false) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                if (self.partial_response == null) {
                    const data_copy = try self.allocator.dupe(u8, remaining);
                    self.partial_response = try streaming.PartialResponse.initMemory(self.allocator, data_copy, true);
                }
                return error.StreamBlocked;
            }
            return err;
        };

        if (n == 0) {
            _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
            if (self.partial_response == null) {
                const data_copy = try self.allocator.dupe(u8, remaining);
                self.partial_response = try streaming.PartialResponse.initMemory(self.allocator, data_copy, true);
            }
            return error.StreamBlocked;
        }

        written += n;
    }
}

pub fn end(comptime Response: type, self: *Response, data: ?[]const u8) !void {
    if (self.ended) return error.ResponseEnded;

    if (!self.headers_sent) {
        try self.sendHeaders(self.is_head_request or data == null or data.?.len == 0);
    }

    if (data) |final_data| {
        if (final_data.len > 0 and !self.is_head_request) {
            _ = self.h3_conn.sendBody(self.quic_conn, self.stream_id, final_data, true) catch |err| {
                if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                    _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                    return error.StreamBlocked;
                }
                return err;
            };
        }
    } else {
        _ = try self.h3_conn.sendBody(self.quic_conn, self.stream_id, "", true);
    }

    self.ended = true;
}

pub fn json(comptime Response: type, self: *Response, json_str: []const u8) !void {
    try self.header(Headers.ContentType, "application/json; charset=utf-8");
    try self.setContentLength(json_str.len);
    try self.writeAll(json_str);
    try self.end(null);
}

pub fn jsonValue(comptime Response: type, self: *Response, value: anytype) !void {
    const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{ .whitespace = .minified });
    defer self.allocator.free(json_str);
    try self.json(json_str);
}

pub fn jsonError(comptime Response: type, self: *Response, code: u16, message: []const u8) !void {
    try self.status(code);
    const error_obj = struct {
        @"error": []const u8,
        code: u16,
    }{
        .@"error" = message,
        .code = code,
    };
    try self.jsonValue(error_obj);
}
