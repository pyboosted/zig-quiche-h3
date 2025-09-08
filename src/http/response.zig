const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const Status = @import("handler.zig").Status;
const Headers = @import("handler.zig").Headers;
const MimeTypes = @import("handler.zig").MimeTypes;

/// HTTP/3 response writer with header buffering and streaming support
pub const Response = struct {
    h3_conn: *h3.H3Connection,
    quic_conn: *quiche.Connection,
    stream_id: u64,
    headers_sent: bool,
    ended: bool,
    status_code: u16,
    header_buffer: std.ArrayList(quiche.h3.Header),
    allocator: std.mem.Allocator,
    is_head_request: bool, // Track if this is a HEAD request
    
    /// Initialize a new response writer
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
            .headers_sent = false,
            .ended = false,
            .status_code = 200,
            .header_buffer = std.ArrayList(quiche.h3.Header){},
            .allocator = allocator,
            .is_head_request = is_head_request,
        };
    }
    
    /// Clean up resources
    pub fn deinit(self: *Response) void {
        // Free any buffered header values that we own
        for (self.header_buffer.items) |hdr| {
            // Headers are borrowed from caller, don't free
            _ = hdr;
        }
        self.header_buffer.deinit(self.allocator);
    }
    
    /// Set the response status code
    pub fn status(self: *Response, code: u16) !void {
        if (self.headers_sent) {
            return error.HeadersAlreadySent;
        }
        self.status_code = code;
    }
    
    /// Add a response header
    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        if (self.headers_sent) {
            return error.HeadersAlreadySent;
        }
        
        // Buffer the header for later sending
        try self.header_buffer.append(self.allocator, quiche.h3.Header{
            .name = name.ptr,
            .name_len = name.len,
            .value = value.ptr,
            .value_len = value.len,
        });
    }
    
    /// Write data to the response body
    /// Returns the number of bytes written (may be less than requested on StreamBlocked)
    pub fn write(self: *Response, data: []const u8) !usize {
        if (self.ended) {
            return error.ResponseEnded;
        }
        
        // Send headers if not yet sent
        if (!self.headers_sent) {
            try self.sendHeaders(false);
        }
        
        // HEAD requests should not have a body
        if (self.is_head_request) {
            return data.len; // Pretend we wrote it
        }
        
        // Send body data
        const written = self.h3_conn.sendBody(self.quic_conn, self.stream_id, data, false) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked) {
                // Stream is blocked, return 0 to indicate retry needed
                return 0;
            }
            return err;
        };
        
        return written;
    }
    
    /// End the response, optionally with final data
    pub fn end(self: *Response, data: ?[]const u8) !void {
        if (self.ended) {
            return error.ResponseEnded;
        }
        
        // Send headers if not yet sent
        if (!self.headers_sent) {
            try self.sendHeaders(data == null or data.?.len == 0);
        }
        
        // Send final body chunk if provided
        if (data) |final_data| {
            if (final_data.len > 0 and !self.is_head_request) {
                _ = self.h3_conn.sendBody(self.quic_conn, self.stream_id, final_data, true) catch |err| {
                    if (err == quiche.h3.Error.StreamBlocked) {
                        // For final send, we can't retry, so this is an error
                        return error.StreamBlocked;
                    }
                    return err;
                };
            }
        } else if (!self.is_head_request) {
            // Send empty body with fin=true to close the stream
            _ = try self.h3_conn.sendBody(self.quic_conn, self.stream_id, "", true);
        }
        
        self.ended = true;
    }
    
    /// Send JSON response with appropriate headers (legacy string-based)
    pub fn json(self: *Response, json_str: []const u8) !void {
        try self.header(Headers.ContentType, "application/json; charset=utf-8");
        
        // Add content-length if known
        var len_buf: [20]u8 = undefined;
        const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{json_str.len});
        try self.header(Headers.ContentLength, len_str);
        
        _ = try self.write(json_str);
        try self.end(null);
    }
    
    /// Send JSON response using std.json serialization
    pub fn jsonValue(self: *Response, value: anytype) !void {
        // Use valueAlloc to serialize directly to allocated memory
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{ .whitespace = .minified });
        defer self.allocator.free(json_str);
        try self.json(json_str);
    }
    
    /// Send JSON error response
    pub fn jsonError(self: *Response, code: u16, message: []const u8) !void {
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
    
    /// Send a redirect response
    pub fn redirect(self: *Response, code: u16, location: []const u8) !void {
        // Validate redirect status code
        if (code < 300 or code >= 400) {
            return error.InvalidRedirectStatus;
        }
        
        try self.status(code);
        try self.header(Headers.Location, location);
        try self.end(null);
    }
    
    /// Helper to send accumulated headers
    fn sendHeaders(self: *Response, fin: bool) !void {
        if (self.headers_sent) return;
        
        // Build final headers array with status
        var final_headers = std.ArrayList(quiche.h3.Header){};
        defer final_headers.deinit(self.allocator);
        
        // Add :status pseudo-header first
        var status_buf: [4]u8 = undefined;
        const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{self.status_code});
        try final_headers.append(self.allocator, quiche.h3.Header{
            .name = ":status",
            .name_len = 7,
            .value = status_str.ptr,
            .value_len = status_str.len,
        });
        
        // Add server header if not present
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
        
        // Add buffered headers
        try final_headers.appendSlice(self.allocator, self.header_buffer.items);
        
        // Send response headers
        try self.h3_conn.sendResponse(
            self.quic_conn,
            self.stream_id,
            final_headers.items,
            fin and self.is_head_request, // For HEAD, headers are the full response
        );
        
        self.headers_sent = true;
    }
    
    /// Check if headers have been sent
    pub fn isHeadersSent(self: Response) bool {
        return self.headers_sent;
    }
    
    /// Check if response has ended
    pub fn isEnded(self: Response) bool {
        return self.ended;
    }
};
