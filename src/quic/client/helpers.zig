const std = @import("std");
const h3 = @import("h3");
const client = @import("mod.zig");

/// Build standard HTTP/3 request headers from a URI and method
/// Caller owns returned memory
pub fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    method: []const u8,
    uri: std.Uri,
    extra_headers: []const client.HeaderPair,
) ![]h3.Header {
    const base_count = 4; // :method, :scheme, :authority, :path
    var headers = try allocator.alloc(h3.Header, base_count + extra_headers.len);
    errdefer allocator.free(headers);

    // Keep track of how many headers we've allocated so far
    var allocated_count: usize = 0;
    errdefer {
        // Free any headers we've allocated so far on error
        for (headers[0..allocated_count]) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
    }

    // Required pseudo-headers must come first
    headers[0] = .{
        .name = try allocator.dupe(u8, ":method"),
        .value = try allocator.dupe(u8, method),
    };
    allocated_count = 1;

    headers[1] = .{
        .name = try allocator.dupe(u8, ":scheme"),
        .value = try allocator.dupe(u8, uri.scheme),
    };
    allocated_count = 2;

    // Build authority from host and optional port
    const authority = if (uri.port) |port| blk: {
        if ((std.mem.eql(u8, uri.scheme, "https") and port == 443) or
            (std.mem.eql(u8, uri.scheme, "http") and port == 80)) {
            // Don't include default ports
            break :blk try allocator.dupe(u8, uri.host.?);
        } else {
            break :blk try std.fmt.allocPrint(allocator, "{s}:{d}", .{ uri.host.?, port });
        }
    } else try allocator.dupe(u8, uri.host.?);

    headers[2] = .{
        .name = try allocator.dupe(u8, ":authority"),
        .value = authority,
    };
    allocated_count = 3;

    // Build path with query string if present
    const path = if (uri.query) |query| blk: {
        break :blk try std.fmt.allocPrint(allocator, "{s}?{s}", .{
            if (uri.path.len > 0) uri.path else "/",
            query,
        });
    } else blk: {
        break :blk try allocator.dupe(u8, if (uri.path.len > 0) uri.path else "/");
    };

    headers[3] = .{
        .name = try allocator.dupe(u8, ":path"),
        .value = path,
    };
    allocated_count = 4;

    // Add extra headers after pseudo-headers
    for (extra_headers, 0..) |h, i| {
        headers[base_count + i] = .{
            .name = try allocator.dupe(u8, h.name),
            .value = try allocator.dupe(u8, h.value),
        };
        allocated_count += 1;
    }

    return headers;
}

/// Free headers allocated by buildRequestHeaders
pub fn freeHeaders(allocator: std.mem.Allocator, headers: []h3.Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

/// Build WebTransport Extended CONNECT headers
/// Caller owns returned memory
pub fn buildWebTransportHeaders(
    allocator: std.mem.Allocator,
    authority: []const u8,
    path: []const u8,
) ![]h3.Header {
    var headers = try allocator.alloc(h3.Header, 6);
    errdefer allocator.free(headers);

    var allocated_count: usize = 0;
    errdefer {
        // Only free the headers we've allocated so far
        for (headers[0..allocated_count]) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
    }

    headers[0] = .{
        .name = try allocator.dupe(u8, ":method"),
        .value = try allocator.dupe(u8, "CONNECT"),
    };
    allocated_count = 1;

    headers[1] = .{
        .name = try allocator.dupe(u8, ":protocol"),
        .value = try allocator.dupe(u8, "webtransport"),
    };
    allocated_count = 2;

    headers[2] = .{
        .name = try allocator.dupe(u8, ":scheme"),
        .value = try allocator.dupe(u8, "https"),
    };
    allocated_count = 3;

    headers[3] = .{
        .name = try allocator.dupe(u8, ":authority"),
        .value = try allocator.dupe(u8, authority),
    };
    allocated_count = 4;

    headers[4] = .{
        .name = try allocator.dupe(u8, ":path"),
        .value = try allocator.dupe(u8, path),
    };
    allocated_count = 5;

    headers[5] = .{
        .name = try allocator.dupe(u8, "sec-webtransport-http3-draft02"),
        .value = try allocator.dupe(u8, "1"),
    };
    allocated_count = 6;
    // allocated_count tracked in errdefer above

    return headers;
}

/// Validate response headers and extract status code
pub fn validateResponseHeaders(headers: []const h3.Header) !u16 {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, ":status")) {
            return std.fmt.parseInt(u16, h.value, 10) catch {
                return error.InvalidStatusCode;
            };
        }
    }
    return error.MissingStatusHeader;
}

/// Check if response has all required headers
pub fn hasRequiredResponseHeaders(headers: []const h3.Header) bool {
    var has_status = false;

    for (headers) |h| {
        if (std.mem.eql(u8, h.name, ":status")) {
            has_status = true;
            break;
        }
    }

    return has_status;
}

/// Check if request has all required pseudo-headers
pub fn hasRequiredRequestHeaders(headers: []const h3.Header) bool {
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

    return has_method and has_scheme and has_authority and has_path;
}

/// Find a header value by name (case-sensitive for pseudo-headers, case-insensitive for others)
pub fn findHeader(headers: []const h3.Header, name: []const u8) ?[]const u8 {
    const is_pseudo = name.len > 0 and name[0] == ':';

    for (headers) |h| {
        if (is_pseudo) {
            // Pseudo-headers are case-sensitive
            if (std.mem.eql(u8, h.name, name)) {
                return h.value;
            }
        } else {
            // Regular headers are case-insensitive
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
    }

    return null;
}

/// Convert client HeaderPair array to H3 Header array
/// Caller owns returned memory
pub fn convertHeaders(allocator: std.mem.Allocator, pairs: []const client.HeaderPair) ![]h3.Header {
    var headers = try allocator.alloc(h3.Header, pairs.len);
    errdefer allocator.free(headers);

    var allocated_count: usize = 0;
    errdefer {
        for (headers[0..allocated_count]) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
    }

    for (pairs, 0..) |pair, i| {
        headers[i] = .{
            .name = try allocator.dupe(u8, pair.name),
            .value = try allocator.dupe(u8, pair.value),
        };
        allocated_count = i + 1;
    }

    return headers;
}

test "buildRequestHeaders basic" {
    const allocator = std.testing.allocator;

    const uri = try std.Uri.parse("https://example.com/path");
    const extra = [_]client.HeaderPair{
        .{ .name = "user-agent", .value = "test/1.0" },
    };

    const headers = try buildRequestHeaders(allocator, "GET", uri, &extra);
    defer freeHeaders(allocator, headers);

    try std.testing.expectEqual(@as(usize, 5), headers.len);
    try std.testing.expectEqualStrings(":method", headers[0].name);
    try std.testing.expectEqualStrings("GET", headers[0].value);
    try std.testing.expectEqualStrings(":scheme", headers[1].name);
    try std.testing.expectEqualStrings("https", headers[1].value);
    try std.testing.expectEqualStrings(":authority", headers[2].name);
    try std.testing.expectEqualStrings("example.com", headers[2].value);
    try std.testing.expectEqualStrings(":path", headers[3].name);
    try std.testing.expectEqualStrings("/path", headers[3].value);
    try std.testing.expectEqualStrings("user-agent", headers[4].name);
    try std.testing.expectEqualStrings("test/1.0", headers[4].value);
}

test "buildRequestHeaders with port" {
    const allocator = std.testing.allocator;

    const uri = try std.Uri.parse("https://example.com:8443/");
    const headers = try buildRequestHeaders(allocator, "POST", uri, &.{});
    defer freeHeaders(allocator, headers);

    try std.testing.expectEqual(@as(usize, 4), headers.len);
    try std.testing.expectEqualStrings(":authority", headers[2].name);
    try std.testing.expectEqualStrings("example.com:8443", headers[2].value);
}

test "buildRequestHeaders default port omitted" {
    const allocator = std.testing.allocator;

    const uri = try std.Uri.parse("https://example.com:443/test");
    const headers = try buildRequestHeaders(allocator, "GET", uri, &.{});
    defer freeHeaders(allocator, headers);

    try std.testing.expectEqualStrings(":authority", headers[2].name);
    try std.testing.expectEqualStrings("example.com", headers[2].value);
}

test "buildWebTransportHeaders" {
    const allocator = std.testing.allocator;

    const headers = try buildWebTransportHeaders(allocator, "localhost:4433", "/wt/echo");
    defer freeHeaders(allocator, headers);

    try std.testing.expectEqual(@as(usize, 6), headers.len);
    try std.testing.expectEqualStrings(":method", headers[0].name);
    try std.testing.expectEqualStrings("CONNECT", headers[0].value);
    try std.testing.expectEqualStrings(":protocol", headers[1].name);
    try std.testing.expectEqualStrings("webtransport", headers[1].value);
}

test "validateResponseHeaders" {
    const headers = [_]h3.Header{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
    };

    const status = try validateResponseHeaders(&headers);
    try std.testing.expectEqual(@as(u16, 200), status);
}

test "findHeader" {
    const headers = [_]h3.Header{
        .{ .name = ":status", .value = "404" },
        .{ .name = "Content-Type", .value = "text/html" },
        .{ .name = "content-length", .value = "1234" },
    };

    // Pseudo-header (case-sensitive)
    try std.testing.expectEqualStrings("404", findHeader(&headers, ":status").?);
    try std.testing.expect(findHeader(&headers, ":Status") == null);

    // Regular header (case-insensitive)
    try std.testing.expectEqualStrings("text/html", findHeader(&headers, "content-type").?);
    try std.testing.expectEqualStrings("text/html", findHeader(&headers, "Content-Type").?);
    try std.testing.expectEqualStrings("1234", findHeader(&headers, "CONTENT-LENGTH").?);
}