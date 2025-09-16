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

fn levelEnabled(self: anytype, level: config_mod.ServerConfig.LogLevel) bool {
    // Always allow error/warn; for info/debug/trace gate by config
    const current = self.config.log_level;
    return @intFromEnum(level) <= @intFromEnum(current);
}

pub fn logf(self: anytype, level: config_mod.ServerConfig.LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (levelEnabled(self, level)) std.debug.print(fmt, args);
}

pub fn errorf(self: anytype, comptime fmt: []const u8, args: anytype) void { logf(self, config_mod.ServerConfig.LogLevel.err, fmt, args); }
pub fn warnf(self: anytype, comptime fmt: []const u8, args: anytype) void { logf(self, config_mod.ServerConfig.LogLevel.warn, fmt, args); }
pub fn infof(self: anytype, comptime fmt: []const u8, args: anytype) void { logf(self, config_mod.ServerConfig.LogLevel.info, fmt, args); }
pub fn debugf(self: anytype, comptime fmt: []const u8, args: anytype) void { logf(self, config_mod.ServerConfig.LogLevel.debug, fmt, args); }
pub fn tracef(self: anytype, comptime fmt: []const u8, args: anytype) void { logf(self, config_mod.ServerConfig.LogLevel.trace, fmt, args); }

pub fn parseLevel(s: []const u8) ?config_mod.ServerConfig.LogLevel {
    const lower = std.mem.trim(u8, std.ascii.allocLowerString(std.heap.page_allocator, s) catch return null, " \t\r\n");
    defer std.heap.page_allocator.free(lower);
    if (std.mem.eql(u8, lower, "error")) return .err;
    if (std.mem.eql(u8, lower, "warn") or std.mem.eql(u8, lower, "warning")) return .warn;
    if (std.mem.eql(u8, lower, "info")) return .info;
    if (std.mem.eql(u8, lower, "debug")) return .debug;
    if (std.mem.eql(u8, lower, "trace")) return .trace;
    return null;
}

// Back-compat helper used by existing call sites; mapped to debug level
pub fn debugPrint(self: anytype, comptime fmt: []const u8, args: anytype) void {
    debugf(self, fmt, args);
}
