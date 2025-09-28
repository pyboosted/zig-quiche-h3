const std = @import("std");

pub const zig_h3_server_module = @import("ffi/server.zig");

extern fn quiche_version() [*:0]const u8;

// Exported symbol for Bun FFI smoke tests
pub export fn zig_h3_version() [*:0]const u8 {
    return quiche_version();
}
