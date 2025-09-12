const std = @import("std");
const config_mod = @import("config");

// Local debug counter for throttled quiche debug logging
var debug_counter = std.atomic.Value(u32).init(0);

/// C-callback used by quiche for debug logging. Throttled via ServerConfig.
pub fn debugLog(line: [*c]const u8, argp: ?*anyopaque) callconv(.c) void {
    const count = debug_counter.fetchAdd(1, .monotonic);
    const cfg = @as(*const config_mod.ServerConfig, @ptrCast(@alignCast(argp orelse return)));
    if (cfg.debug_log_throttle != 0 and count % cfg.debug_log_throttle == 0) {
        std.debug.print("[QUICHE] {s}\n", .{line});
    }
}

/// Simple helpers that depend on the server instance only through fields
/// available on its type. Use via `server_logging.debugPrint(self, ...)`.
pub fn appDebug(self: anytype) bool {
    return self.config.enable_debug_logging;
}

pub fn debugPrint(self: anytype, comptime fmt: []const u8, args: anytype) void {
    if (appDebug(self)) {
        std.debug.print(fmt, args);
    }
}
