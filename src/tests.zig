const std = @import("std");
// Import modules with inline tests so they get compiled and executed
const _server_tests = @import("quic/server.zig");
const _client_tests = @import("client");
const _goaway_tests = @import("quic/client/goaway_test.zig");
const _errors_tests = @import("errors_test.zig");
// Header validation tests are included via the http module

extern fn quiche_version() [*:0]const u8;

test "print quiche version" {
    const ver = std.mem.span(quiche_version());
    std.debug.print("[test] quiche version: {s}\n", .{ver});
    // Sanity: ensure non-empty
    try std.testing.expect(ver.len > 0);
}

// HTTP tests are included via the http module import in server/client modules
