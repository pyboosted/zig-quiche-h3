const std = @import("std");
// Import modules with inline tests so they get compiled and executed
const _server_tests = @import("quic/server.zig");
const _routing_api_tests = @import("routing");
const _routing_gen_tests = @import("routing_gen");
const http = @import("http");
const _errors_tests = @import("errors_test.zig");

extern fn quiche_version() [*:0]const u8;

test "print quiche version" {
    const ver = std.mem.span(quiche_version());
    std.debug.print("[test] quiche version: {s}\n", .{ver});
    // Sanity: ensure non-empty
    try std.testing.expect(ver.len > 0);
}

test "http: formatAllowFromEnumSet" {
    var set = std.enums.EnumSet(http.Method){};
    set.insert(.GET);
    set.insert(.POST);
    const allow = try http.formatAllowFromEnumSet(std.testing.allocator, set);
    defer std.testing.allocator.free(allow);
    try std.testing.expect(std.mem.eql(u8, allow, "GET, POST"));
}
