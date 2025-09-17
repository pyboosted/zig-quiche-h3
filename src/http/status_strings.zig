const std = @import("std");
const Status = @import("handler.zig").Status;

pub const StatusString = struct {
    code: u16,
    text: []const u8,
};

// Table of canonical status texts.
const status_table = [_]StatusString{
    .{ .code = 200, .text = "OK" },
    .{ .code = 201, .text = "Created" },
    .{ .code = 202, .text = "Accepted" },
    .{ .code = 204, .text = "No Content" },
    .{ .code = 205, .text = "Reset Content" },
    .{ .code = 206, .text = "Partial Content" },
    .{ .code = 301, .text = "Moved Permanently" },
    .{ .code = 302, .text = "Found" },
    .{ .code = 303, .text = "See Other" },
    .{ .code = 304, .text = "Not Modified" },
    .{ .code = 307, .text = "Temporary Redirect" },
    .{ .code = 308, .text = "Permanent Redirect" },
    .{ .code = 400, .text = "Bad Request" },
    .{ .code = 401, .text = "Unauthorized" },
    .{ .code = 403, .text = "Forbidden" },
    .{ .code = 404, .text = "Not Found" },
    .{ .code = 405, .text = "Method Not Allowed" },
    .{ .code = 406, .text = "Not Acceptable" },
    .{ .code = 408, .text = "Request Timeout" },
    .{ .code = 409, .text = "Conflict" },
    .{ .code = 410, .text = "Gone" },
    .{ .code = 411, .text = "Length Required" },
    .{ .code = 412, .text = "Precondition Failed" },
    .{ .code = 413, .text = "Payload Too Large" },
    .{ .code = 414, .text = "URI Too Long" },
    .{ .code = 415, .text = "Unsupported Media Type" },
    .{ .code = 416, .text = "Range Not Satisfiable" },
    .{ .code = 417, .text = "Expectation Failed" },
    .{ .code = 418, .text = "I'm a teapot" },
    .{ .code = 421, .text = "Misdirected Request" },
    .{ .code = 422, .text = "Unprocessable Entity" },
    .{ .code = 429, .text = "Too Many Requests" },
    .{ .code = 431, .text = "Request Header Fields Too Large" },
    .{ .code = 500, .text = "Internal Server Error" },
    .{ .code = 501, .text = "Not Implemented" },
    .{ .code = 502, .text = "Bad Gateway" },
    .{ .code = 503, .text = "Service Unavailable" },
    .{ .code = 504, .text = "Gateway Timeout" },
    .{ .code = 505, .text = "HTTP Version Not Supported" },
};

pub fn getText(code: u16) []const u8 {
    inline for (status_table) |entry| {
        if (entry.code == code) return entry.text;
    }
    return "";
}
