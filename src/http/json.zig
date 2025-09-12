const std = @import("std");
const Response = @import("response.zig").Response;
const Request = @import("request.zig").Request;

/// Send a JSON response with proper headers and buffered serialization
/// Uses the request's arena allocator for temporary memory
pub fn send(req: *Request, res: *Response, value: anytype) !void {
    const allocator = req.arena.allocator();

    // Use valueAlloc to serialize directly to allocated memory
    const json_data = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .minified });
    // No defer needed - arena will clean up

    // Set content type header
    try res.header("content-type", "application/json; charset=utf-8");

    // Set content length
    var len_buf: [20]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{json_data.len});
    try res.header("content-length", len_str);

    // Write the JSON data
    _ = try res.write(json_data);

    // End the response
    try res.end(null);
}

/// Send a JSON error response
pub fn sendError(req: *Request, res: *Response, code: u16, message: []const u8) !void {
    try res.status(code);
    const error_obj = struct {
        @"error": []const u8,
        code: u16,
    }{
        .@"error" = message,
        .code = code,
    };
    try send(req, res, error_obj);
}

/// Stringify a value to JSON using the provided allocator
/// Returns the JSON string which must be freed by the caller
pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .minified });
}

/// Stringify a value to JSON with pretty printing
pub fn stringifyPretty(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
}

// Tests
test "json stringify" {
    const allocator = std.testing.allocator;

    const value = .{
        .id = 123,
        .name = "Test User",
        .active = true,
    };

    const json_str = try stringify(allocator, value);
    defer allocator.free(json_str);

    try std.testing.expectEqualStrings("{\"id\":123,\"name\":\"Test User\",\"active\":true}", json_str);
}

test "json stringify with special characters" {
    const allocator = std.testing.allocator;

    const value = .{
        .message = "Hello \"World\"\nNew line",
        .path = "/api/users/123",
    };

    const json_str = try stringify(allocator, value);
    defer allocator.free(json_str);

    // JSON should properly escape quotes and newlines
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\\\"World\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\\n") != null);
}
