const std = @import("std");

extern fn quiche_version() [*:0]const u8;

test "print quiche version" {
    const ver = std.mem.span(quiche_version());
    std.debug.print("[test] quiche version: {s}\n", .{ver});
    // Sanity: ensure non-empty
    try std.testing.expect(ver.len > 0);
}

