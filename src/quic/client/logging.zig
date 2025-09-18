const std = @import("std");

/// Context for debug logging with throttling support
pub const LogContext = struct {
    debug_log_throttle: u32,
    log_count: std.atomic.Value(u32),

    pub fn init(throttle: u32) LogContext {
        return .{
            .debug_log_throttle = throttle,
            .log_count = std.atomic.Value(u32).init(0),
        };
    }
};

/// Callback function for quiche debug logging
/// This function is called by quiche for each log message.
/// The argp parameter should point to a LogContext struct.
pub fn debugLogCallback(line: [*c]const u8, argp: ?*anyopaque) callconv(.c) void {
    const ptr = argp orelse return;
    const ctx: *LogContext = @ptrCast(@alignCast(ptr));
    const count = ctx.log_count.fetchAdd(1, .monotonic);

    // Only log every Nth message according to throttle setting
    if (count % ctx.debug_log_throttle == 0) {
        const msg = std.mem.span(line);
        std.debug.print("[quiche] {s}\n", .{msg});
    }
}
