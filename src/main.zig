const std = @import("std");

extern fn quiche_version() [*:0]const u8;

pub fn main() !void {
    const ver_c = quiche_version();
    const ver = std.mem.span(ver_c);
    std.debug.print("quiche version: {s}\n", .{ver});
}
