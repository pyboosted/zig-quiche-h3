const std = @import("std");
const quiche = @import("quiche");
const streaming = @import("../streaming.zig");
const Headers = @import("../handler.zig").Headers;
const MimeTypes = @import("../handler.zig").MimeTypes;
const Status = @import("../handler.zig").Status;

pub fn sendFile(comptime Response: type, self: *Response, file_path: []const u8) !void {
    if (self.ended) return error.ResponseEnded;

    const file = try std.fs.cwd().openFile(file_path, .{ .read = true });
    defer file.close();

    const stat = try file.stat();
    try self.setContentLength(stat.size);

    if (std.mem.endsWith(u8, file_path, ".html")) {
        try self.header(Headers.ContentType, MimeTypes.TextHtml);
    } else if (std.mem.endsWith(u8, file_path, ".txt")) {
        try self.header(Headers.ContentType, MimeTypes.TextPlain);
    } else if (std.mem.endsWith(u8, file_path, ".css")) {
        try self.header(Headers.ContentType, MimeTypes.TextCss);
    } else if (std.mem.endsWith(u8, file_path, ".js")) {
        try self.header(Headers.ContentType, MimeTypes.TextJavascript);
    } else if (std.mem.endsWith(u8, file_path, ".json")) {
        try self.header(Headers.ContentType, MimeTypes.ApplicationJson);
    } else {
        try self.header(Headers.ContentType, MimeTypes.ApplicationOctetStream);
    }

    const chunk_sz = streaming.getDefaultChunkSize();
    self.partial_response = try streaming.PartialResponse.initFile(self.allocator, file, stat.size, chunk_sz, true);
    try self.processPartialResponse();
}

pub fn processPartialResponse(comptime Response: type, self: *Response) !void {
    const partial = self.partial_response orelse return;

    if (!self.limiter_checked and self.on_start_streaming != null) {
        const source_kind: u8 = switch (partial.body_source) {
            .memory => 0,
            .file => 1,
            .generator => 2,
        };

        if (source_kind != 0) {
            const ok = self.on_start_streaming.?(self.limiter_ctx.?, self.quic_conn, self.stream_id, source_kind);
            self.limiter_checked = true;
            if (!ok) {
                var status_buf: [4]u8 = undefined;
                const code: u16 = @intFromEnum(Status.ServiceUnavailable);
                const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{code});
                const headers = [_]quiche.h3.Header{
                    .{ .name = ":status", .name_len = 7, .value = status_str.ptr, .value_len = status_str.len },
                    .{ .name = Headers.ContentLength, .name_len = Headers.ContentLength.len, .value = "0", .value_len = 1 },
                };
                self.h3_conn.sendResponse(self.quic_conn, self.stream_id, headers[0..], true) catch {};
                partial.deinit();
                self.partial_response = null;
                self.ended = true;
                return;
            }
        } else {
            self.limiter_checked = true;
        }
    }

    if (self.is_head_request) {
        if (!self.headers_sent) try self.sendHeaders(true);
        self.ended = true;
        partial.deinit();
        self.partial_response = null;
        return;
    }

    if (!self.headers_sent) try self.sendHeaders(false);

    while (!partial.isComplete()) {
        const chunk = try partial.getNextChunk();

        if (chunk.data.len == 0 and chunk.is_final) {
            _ = self.h3_conn.sendBody(self.quic_conn, self.stream_id, "", true) catch |err| {
                if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                    _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                    return;
                }
                return err;
            };
            self.ended = true;
            partial.deinit();
            self.partial_response = null;
            return;
        }

        const written = self.h3_conn.sendBody(self.quic_conn, self.stream_id, chunk.data, chunk.is_final and partial.fin_on_complete) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                return;
            }
            return err;
        };

        if (written == 0) {
            _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
            return;
        }

        partial.updateWritten(written);
        if (written < chunk.data.len) return;
    }

    if (partial.fin_on_complete) {
        switch (partial.body_source) {
            .generator => {
                _ = self.h3_conn.sendBody(self.quic_conn, self.stream_id, "", true) catch |err| {
                    if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                        _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                        return;
                    }
                    return err;
                };
                self.ended = true;
            },
            else => self.ended = true,
        }
    }
    partial.deinit();
    self.partial_response = null;
}
