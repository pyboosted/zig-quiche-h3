const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const Status = @import("handler.zig").Status;
const Headers = @import("handler.zig").Headers;
const MimeTypes = @import("handler.zig").MimeTypes;
const streaming = @import("streaming.zig");

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
    partial_response: ?*streaming.PartialResponse, // Track partial sends
    
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
            .partial_response = null,
        };
    }
    
    /// Clean up resources
    pub fn deinit(self: *Response) void {
        // Free duplicated header strings
        for (self.header_buffer.items) |hdr| {
            // We now own these strings, so free them
            self.allocator.free(hdr.name[0..hdr.name_len]);
            self.allocator.free(hdr.value[0..hdr.value_len]);
        }
        self.header_buffer.deinit(self.allocator);
        
        // Clean up partial response if exists
        if (self.partial_response) |partial| {
            partial.deinit();
            self.partial_response = null; // Belt-and-suspenders
        }
    }
    
    /// Set the response status code
    pub fn status(self: *Response, code: u16) !void {
        if (self.headers_sent) {
            return error.HeadersAlreadySent;
        }
        self.status_code = code;
    }
    
    /// Add a response header (duplicates name and value for safety)
    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        if (self.headers_sent) {
            return error.HeadersAlreadySent;
        }
        
        // Duplicate name and value to ensure they remain valid
        const name_copy = try self.allocator.dupe(u8, name);
        const value_copy = try self.allocator.dupe(u8, value);
        
        // Buffer the header for later sending
        try self.header_buffer.append(self.allocator, quiche.h3.Header{
            .name = name_copy.ptr,
            .name_len = name_copy.len,
            .value = value_copy.ptr,
            .value_len = value_copy.len,
        });
    }
    
    /// Write data to the response body
    /// Returns the number of bytes written (may be less than requested on StreamBlocked)
    pub fn write(self: *Response, data: []const u8) !usize {
        if (self.ended) {
            return error.ResponseEnded;
        }
        
        // HEAD requests should not have a body
        if (self.is_head_request) {
            return data.len; // Pretend we wrote it
        }
        
        // Send headers if not yet sent. If headers are temporarily blocked,
        // queue the entire body as a partial so it can be sent once headers
        // are accepted, and signal backpressure to the caller.
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
        
        // Send body data
        const written = self.h3_conn.sendBody(self.quic_conn, self.stream_id, data, false) catch |err| {
            if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                // Stream is blocked; register interest for any future capacity.
                // Passing 0 means "notify when any amount is writable".
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                return 0;
            }
            return err;
        };
        
        return written;
    }
    
    /// Write all data, handling partial writes and backpressure
    pub fn writeAll(self: *Response, data: []const u8) !void {
        if (self.ended) {
            return error.ResponseEnded;
        }
        
        // HEAD requests should not have a body
        if (self.is_head_request) {
            return;
        }
        
        // Send headers if not yet sent. If blocked, keep placeholder partial
        // created by sendHeaders() and return backpressure; the queued partial
        // will be processed when writable.
        if (!self.headers_sent) {
            self.sendHeaders(false) catch |err| {
                if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                    _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                    return; // processPartialResponse will retry later
                }
                return err;
            };
        }
        
        var written: usize = 0;
        while (written < data.len) {
            const remaining = data[written..];
            const n = self.h3_conn.sendBody(self.quic_conn, self.stream_id, remaining, false) catch |err| {
                if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                    // Arm writability hint for any capacity (0 = any).
                    _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};

                    // Create partial response to resume later
                    if (self.partial_response == null) {
                        // Duplicate the remaining data since we need to own it
                        const data_copy = try self.allocator.dupe(u8, remaining);
                        self.partial_response = try streaming.PartialResponse.initMemory(
                            self.allocator,
                            data_copy,
                            true
                        );
                    }
                    return error.StreamBlocked;
                }
                return err;
            };
            
            if (n == 0) {
                // Stream is blocked, arm writability hint for any capacity
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};

                // Save state for retry
                if (self.partial_response == null) {
                    const data_copy = try self.allocator.dupe(u8, remaining);
                    self.partial_response = try streaming.PartialResponse.initMemory(
                        self.allocator,
                        data_copy,
                        true
                    );
                }
                return error.StreamBlocked;
            }
            
            written += n;
        }
    }
    
    /// End the response, optionally with final data
    pub fn end(self: *Response, data: ?[]const u8) !void {
        if (self.ended) {
            return error.ResponseEnded;
        }
        
        // Send headers if not yet sent
        if (!self.headers_sent) {
            // For HEAD requests, always send FIN with headers
            try self.sendHeaders(self.is_head_request or data == null or data.?.len == 0);
        }
        
        // Send final body chunk if provided
        if (data) |final_data| {
            if (final_data.len > 0 and !self.is_head_request) {
            _ = self.h3_conn.sendBody(self.quic_conn, self.stream_id, final_data, true) catch |err| {
                if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                    // Register interest so processWritableStreams can finish FIN later.
                    _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                    return error.StreamBlocked;
                }
                return err;
            };
            }
        } else {
            // Send empty body with fin=true to close the stream
            // For HEAD requests, this ensures the stream is properly closed
            _ = try self.h3_conn.sendBody(self.quic_conn, self.stream_id, "", true);
        }
        
        self.ended = true;
    }
    
    /// Send JSON response with appropriate headers
    pub fn json(self: *Response, json_str: []const u8) !void {
        try self.header(Headers.ContentType, "application/json; charset=utf-8");
        
        // Add content-length if known
        var len_buf: [20]u8 = undefined;
        const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{json_str.len});
        try self.header(Headers.ContentLength, len_str);
        
        // Use writeAll for proper handling of partial writes
        try self.writeAll(json_str);
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
        // Duplicate status string to ensure it remains valid
        var status_buf: [4]u8 = undefined;
        const status_str = try std.fmt.bufPrint(&status_buf, "{d}", .{self.status_code});
        const status_copy = try self.allocator.dupe(u8, status_str);
        defer self.allocator.free(status_copy);
        
        try final_headers.append(self.allocator, quiche.h3.Header{
            .name = ":status",
            .name_len = 7,
            .value = status_copy.ptr,
            .value_len = status_copy.len,
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
        
        // Send response headers (propagate StreamBlocked for retry)
        self.h3_conn.sendResponse(
            self.quic_conn,
            self.stream_id,
            final_headers.items,
            fin and self.is_head_request, // For HEAD, headers are the full response
        ) catch |err| {
            // Don't mark headers as sent if blocked - will retry later.
            if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                // Arm writability hint for any future capacity.
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                // Ensure there's a partial response placeholder so the server's
                // processWritableStreams() path will revisit this stream and call
                // processPartialResponse(), which re-attempts sendHeaders().
                if (self.partial_response == null) {
                    const empty = try self.allocator.alloc(u8, 0);
                    self.partial_response = try streaming.PartialResponse.initMemory(
                        self.allocator,
                        empty,
                        false
                    );
                }
                return err;
            }
            return err;
        };
        
        // Only mark headers as sent on success
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
    
    /// Send a file with zero-copy streaming
    pub fn sendFile(self: *Response, file_path: []const u8) !void {
        if (self.ended) {
            return error.ResponseEnded;
        }
        
        const file = try std.fs.openFileAbsolute(file_path, .{});
        errdefer file.close();
        
        const stat = try file.stat();
        
        // Set content-length header
        var len_buf: [20]u8 = undefined;
        const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{stat.size});
        try self.header(Headers.ContentLength, len_str);
        
        // Detect content type from extension
        const ext = std.fs.path.extension(file_path);
        if (std.mem.eql(u8, ext, ".html")) {
            try self.header(Headers.ContentType, MimeTypes.TextHtml);
        } else if (std.mem.eql(u8, ext, ".css")) {
            try self.header(Headers.ContentType, MimeTypes.TextCss);
        } else if (std.mem.eql(u8, ext, ".js")) {
            try self.header(Headers.ContentType, MimeTypes.TextJavascript);
        } else if (std.mem.eql(u8, ext, ".json")) {
            try self.header(Headers.ContentType, MimeTypes.ApplicationJson);
        } else {
            try self.header(Headers.ContentType, MimeTypes.ApplicationOctetStream);
        }
        
        // Create partial response for file (use global default chunk size)
        const chunk_sz = streaming.getDefaultChunkSize();
        self.partial_response = try streaming.PartialResponse.initFile(
            self.allocator,
            file,
            stat.size,
            chunk_sz,
            true // Send FIN when complete
        );
        
        // Start processing the partial response
        try self.processPartialResponse();
    }
    
    /// Process a partial response (resume sending)
    pub fn processPartialResponse(self: *Response) !void {
        const partial = self.partial_response orelse return;
        
        // HEAD requests should not have body
        if (self.is_head_request) {
            // Send headers with FIN if not yet sent
            if (!self.headers_sent) {
                try self.sendHeaders(true);
            }
            self.ended = true;
            partial.deinit();
            self.partial_response = null;
            return;
        }
        
        // Send headers if not yet sent
        if (!self.headers_sent) {
            try self.sendHeaders(false);
        }
        
        // Get next chunk and try to send it
        while (!partial.isComplete()) {
            const chunk = try partial.getNextChunk();
            
            if (chunk.data.len == 0 and chunk.is_final) {
                // Send empty body with FIN to close stream
                _ = self.h3_conn.sendBody(
                    self.quic_conn,
                    self.stream_id,
                    "",
                    true
                ) catch |err| {
                    if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                        // Arm writability hint for final send (any capacity)
                        _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                        return; // Will retry later
                    }
                    return err;
                };
                self.ended = true;
                partial.deinit();
                self.partial_response = null;
                return;
            }
            
            const written = self.h3_conn.sendBody(
                self.quic_conn,
                self.stream_id,
                chunk.data,
                chunk.is_final and partial.fin_on_complete
            ) catch |err| {
                if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                    // Arm writability hint (any capacity)
                    _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                    return; // Will retry when stream becomes writable
                }
                return err;
            };
            
            if (written == 0) {
                // Stream blocked, arm writability hint for any capacity
                _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                // Will retry later
                return;
            }
            
            partial.updateWritten(written);
            
            // If we didn't write everything, save position and return
            if (written < chunk.data.len) {
                return;
            }
        }
        
        // Complete - ensure FIN is transmitted. For generator sources with a known
        // total size, the loop may exit exactly at total without producing a
        // zero-length final chunk, so we must explicitly send an empty FIN.
        if (partial.fin_on_complete) {
            // For generator sources (which may never mark a non-empty chunk as
            // final), explicitly send a zero-length FIN when total completes.
            switch (partial.body_source) {
                .generator => {
                    _ = self.h3_conn.sendBody(self.quic_conn, self.stream_id, "", true) catch |err| {
                        if (err == quiche.h3.Error.StreamBlocked or err == quiche.h3.Error.Done) {
                            _ = self.quic_conn.streamWritable(self.stream_id, 0) catch {};
                            return; // retry later
                        }
                        return err;
                    };
                    self.ended = true;
                },
                else => {
                    // Memory/file paths set FIN on the last non-empty chunk.
                    self.ended = true;
                },
            }
        }
        partial.deinit();
        self.partial_response = null;
    }
};
