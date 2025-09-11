const std = @import("std");
const Method = @import("handler.zig").Method;

/// HTTP/3 header representation
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// HTTP request object with parameter extraction and body buffering
pub const Request = struct {
    method: Method,
    path_raw: []const u8,           // original :path pseudo-header
    path_decoded: []const u8,        // percent-decoded, no query string
    query_raw: ?[]const u8,          // everything after '?'
    authority: ?[]const u8,          // :authority pseudo-header
    headers: []Header,               // All headers including pseudo-headers
    params: std.StringHashMapUnmanaged([]const u8), // Route parameters
    query: std.StringHashMapUnmanaged([]const u8),  // Query parameters
    stream_id: u64,
    arena: *std.heap.ArenaAllocator,
    body_buffer: std.ArrayList(u8),  // Bounded body buffer for M4
    body_complete: bool,
    body_received_bytes: usize,      // Track bytes in streaming mode
    user_data: ?*anyopaque = null,   // User context for streaming handlers
    
    /// Initialize a new request with an arena allocator
    pub fn init(
        arena: *std.heap.ArenaAllocator,
        method: Method,
        path_raw: []const u8,
        authority: ?[]const u8,
        headers: []Header,
        stream_id: u64,
    ) !Request {
        const allocator = arena.allocator();
        
        // Parse path and query
        const path_query = try parsePath(allocator, path_raw);
        
        // Parse query parameters if present
        var query_params = std.StringHashMapUnmanaged([]const u8){};
        if (path_query.query) |q| {
            try parseQuery(allocator, q, &query_params);
        }
        
        return Request{
            .method = method,
            .path_raw = path_raw,
            .path_decoded = path_query.path,
            .query_raw = path_query.query,
            .authority = authority,
            .headers = headers,
            .params = std.StringHashMapUnmanaged([]const u8){},
            .query = query_params,
            .stream_id = stream_id,
            .arena = arena,
            .body_buffer = std.ArrayList(u8){},
            .body_complete = false,
            .body_received_bytes = 0,
            .user_data = null,
        };
    }
    
    /// Get the HTTP/3 :protocol pseudo-header (for CONNECT semantics)
    pub fn h3Protocol(self: *Request) ?[]const u8 {
        return self.getHeader(":protocol");
    }

    /// Parse datagram-flow-id header as u64 if present (CONNECT-UDP)
    pub fn datagramFlowId(self: *Request) ?u64 {
        const v = self.getHeader("datagram-flow-id") orelse return null;
        return std.fmt.parseInt(u64, v, 10) catch null;
    }

    /// Read all body data (up to max_bytes)
    pub fn readAll(self: *Request, max_bytes: usize) ![]const u8 {
        if (self.body_buffer.items.len > max_bytes) {
            return error.PayloadTooLarge;
        }
        return self.body_buffer.items;
    }
    
    /// Get a route parameter by name
    pub fn getParam(self: *Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }
    
    /// Get a query parameter by name
    pub fn getQuery(self: *Request, name: []const u8) ?[]const u8 {
        return self.query.get(name);
    }
    
    /// Get a header value by name (case-insensitive)
    pub fn getHeader(self: *Request, name: []const u8) ?[]const u8 {
        for (self.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }
    
    /// Add body data to the buffer
    pub fn appendBody(self: *Request, data: []const u8, max_size: usize) !void {
        const allocator = self.arena.allocator();
        
        if (self.body_buffer.items.len + data.len > max_size) {
            return error.PayloadTooLarge;
        }
        
        try self.body_buffer.appendSlice(allocator, data);
    }
    
    /// Get current body size (for streaming mode tracking)
    pub fn getBodySize(self: Request) usize {
        // In streaming mode, return the counter
        // In buffering mode, return buffer size
        if (self.body_received_bytes > 0) {
            return self.body_received_bytes;
        }
        return self.body_buffer.items.len;
    }
    
    /// Add to body size tracker (for streaming mode)
    pub fn addToBodySize(self: *Request, bytes: usize) void {
        // In streaming mode, just increment the counter
        // This avoids allocating memory for data we're not buffering
        self.body_received_bytes += bytes;
    }
    
    /// Mark body as complete
    pub fn setBodyComplete(self: *Request) void {
        self.body_complete = true;
    }
    
    /// Check if this is a HEAD request (no body expected)
    pub fn isHead(self: Request) bool {
        return self.method == .HEAD;
    }
    
    /// Get content type from headers
    pub fn contentType(self: *Request) ?[]const u8 {
        return self.getHeader("content-type");
    }
    
    /// Get content length from headers
    pub fn contentLength(self: *Request) ?usize {
        const len_str = self.getHeader("content-length") orelse return null;
        return std.fmt.parseInt(usize, len_str, 10) catch null;
    }

    test "datagram-flow-id and :protocol parsing" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Build headers including pseudo-headers and datagram-flow-id
        var hdrs = try alloc.alloc(Header, 4);
        hdrs[0] = .{ .name = ":method", .value = "CONNECT" };
        hdrs[1] = .{ .name = ":protocol", .value = "webtransport" };
        hdrs[2] = .{ .name = "datagram-flow-id", .value = "12345" };
        hdrs[3] = .{ .name = ":path", .value = "/" };

        var req = try Request.init(&arena, .CONNECT, "/", null, hdrs, 9);

        try std.testing.expect(req.h3Protocol() != null);
        try std.testing.expectEqualStrings("webtransport", req.h3Protocol().?);
        try std.testing.expect(req.datagramFlowId() != null);
        try std.testing.expectEqual(@as(u64, 12345), req.datagramFlowId().?);
    }
};

/// Result of parsing a path
const PathQueryResult = struct {
    path: []const u8,
    query: ?[]const u8,
};

/// Parse path and extract query string
fn parsePath(allocator: std.mem.Allocator, raw_path: []const u8) !PathQueryResult {
    if (raw_path.len == 0) {
        return PathQueryResult{
            .path = try allocator.dupe(u8, "/"),
            .query = null,
        };
    }
    
    // Find query separator
    if (std.mem.indexOf(u8, raw_path, "?")) |query_start| {
        const path_part = raw_path[0..query_start];
        const query_part = if (query_start + 1 < raw_path.len) 
            raw_path[query_start + 1..] 
        else 
            null;
        
        // Percent-decode the path ('+' should be literal in paths)
        const decoded_path = try percentDecodePath(allocator, path_part);
        
        return PathQueryResult{
            .path = decoded_path,
            .query = if (query_part) |q| try allocator.dupe(u8, q) else null,
        };
    }
    
    // No query string, just decode the path
    const decoded_path = try percentDecodePath(allocator, raw_path);
    return PathQueryResult{
        .path = decoded_path,
        .query = null,
    };
}

/// Parse query string into key-value pairs
fn parseQuery(
    allocator: std.mem.Allocator,
    query_string: []const u8,
    params: *std.StringHashMapUnmanaged([]const u8),
) !void {
    var iter = std.mem.tokenizeScalar(u8, query_string, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq_pos| {
            const key = try percentDecodeQuery(allocator, pair[0..eq_pos]);
            const value = if (eq_pos + 1 < pair.len)
                try percentDecodeQuery(allocator, pair[eq_pos + 1..])
            else
                try allocator.dupe(u8, "");
            
            try params.put(allocator, key, value);
        } else {
            // Key without value
            const key = try percentDecodeQuery(allocator, pair);
            try params.put(allocator, key, try allocator.dupe(u8, ""));
        }
    }
}

/// Percent-decode a URL component
fn percentDecode(allocator: std.mem.Allocator, input: []const u8, plus_as_space: bool) ![]const u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);
    
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            // Try to parse hex digits
            const hex_str = input[i + 1..i + 3];
            if (std.fmt.parseInt(u8, hex_str, 16)) |byte| {
                try result.append(allocator, byte);
                i += 3;
                continue;
            } else |_| {
                // Invalid hex, keep the '%' as-is
                try result.append(allocator, input[i]);
                i += 1;
            }
        } else if (input[i] == '+' and plus_as_space) {
            // '+' decodes to space only in query strings
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    
    return allocator.dupe(u8, result.items);
}

/// Percent-decode a URL path component ('+' is literal)
fn percentDecodePath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    return percentDecode(allocator, input, false);
}

/// Percent-decode a query string component ('+' becomes space)
fn percentDecodeQuery(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    return percentDecode(allocator, input, true);
}

// Tests
test "path parsing" {
    const allocator = std.testing.allocator;
    
    // Test simple path
    {
        const result = try parsePath(allocator, "/api/users");
        defer allocator.free(result.path);
        defer if (result.query) |q| allocator.free(q);
        
        try std.testing.expectEqualStrings("/api/users", result.path);
        try std.testing.expect(result.query == null);
    }
    
    // Test path with query
    {
        const result = try parsePath(allocator, "/search?q=test&page=1");
        defer allocator.free(result.path);
        defer if (result.query) |q| allocator.free(q);
        
        try std.testing.expectEqualStrings("/search", result.path);
        try std.testing.expectEqualStrings("q=test&page=1", result.query.?);
    }
    
    // Test percent-encoded path
    {
        const result = try parsePath(allocator, "/files/hello%20world.txt");
        defer allocator.free(result.path);
        defer if (result.query) |q| allocator.free(q);
        
        try std.testing.expectEqualStrings("/files/hello world.txt", result.path);
    }
}

test "query parsing" {
    const allocator = std.testing.allocator;
    
    var params = std.StringHashMapUnmanaged([]const u8){};
    defer {
        var iter = params.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit(allocator);
    }
    
    try parseQuery(allocator, "q=hello+world&page=1&empty=", &params);
    
    try std.testing.expectEqualStrings("hello world", params.get("q").?);
    try std.testing.expectEqualStrings("1", params.get("page").?);
    try std.testing.expectEqualStrings("", params.get("empty").?);
}

test "percent decoding" {
    const allocator = std.testing.allocator;
    
    // Test basic percent encoding
    {
        const decoded = try percentDecode(allocator, "hello%20world", false);
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings("hello world", decoded);
    }
    
    // Test plus in path (should be literal)
    {
        const decoded = try percentDecodePath(allocator, "hello+world");
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings("hello+world", decoded);
    }
    
    // Test plus in query (should be space)
    {
        const decoded = try percentDecodeQuery(allocator, "hello+world");
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings("hello world", decoded);
    }
    
    // Test special characters
    {
        const decoded = try percentDecode(allocator, "%2F%3D%26%3F", false);
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings("/=&?", decoded);
    }
}
