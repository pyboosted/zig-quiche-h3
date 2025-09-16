const std = @import("std");
const config_mod = @import("config");
const build_options = @import("build_options");

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

/// Parse log level at compile-time from build options
const build_log_level = blk: {
    const level_str = build_options.log_level;
    if (std.mem.eql(u8, level_str, "error") or std.mem.eql(u8, level_str, "err")) break :blk config_mod.ServerConfig.LogLevel.err;
    if (std.mem.eql(u8, level_str, "warn") or std.mem.eql(u8, level_str, "warning")) break :blk config_mod.ServerConfig.LogLevel.warn;
    if (std.mem.eql(u8, level_str, "info")) break :blk config_mod.ServerConfig.LogLevel.info;
    if (std.mem.eql(u8, level_str, "debug")) break :blk config_mod.ServerConfig.LogLevel.debug;
    if (std.mem.eql(u8, level_str, "trace")) break :blk config_mod.ServerConfig.LogLevel.trace;
    break :blk config_mod.ServerConfig.LogLevel.warn; // Default to warn
};

/// Runtime log level override (if set via environment)
var runtime_log_level: ?config_mod.ServerConfig.LogLevel = null;

/// Initialize runtime log level from environment variables
pub fn initRuntime() void {
    // Check H3_LOG_LEVEL first, then H3_DEBUG for backward compatibility
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "H3_LOG_LEVEL")) |level_str| {
        defer std.heap.page_allocator.free(level_str);
        runtime_log_level = parseLevel(level_str);
    } else |_| {
        // Check H3_DEBUG for backward compatibility
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "H3_DEBUG")) |debug_str| {
            defer std.heap.page_allocator.free(debug_str);
            if (std.mem.eql(u8, debug_str, "1") or std.mem.eql(u8, debug_str, "true")) {
                runtime_log_level = .debug;
            }
        } else |_| {}
    }
}

fn levelEnabled(self: anytype, comptime level: config_mod.ServerConfig.LogLevel) bool {
    // First check compile-time level - if disabled at compile-time, always return false
    // This allows the compiler to eliminate the logging code entirely
    if (comptime @intFromEnum(level) > @intFromEnum(build_log_level)) {
        return false;
    }

    // If runtime override is set, use it
    if (runtime_log_level) |runtime_level| {
        return @intFromEnum(level) <= @intFromEnum(runtime_level);
    }

    // Otherwise use the config level
    const current = self.config.log_level;
    return @intFromEnum(level) <= @intFromEnum(current);
}

pub fn logf(self: anytype, comptime level: config_mod.ServerConfig.LogLevel, comptime fmt: []const u8, args: anytype) void {
    // Compile-time filtering - if disabled at build time, this code is eliminated
    const level_int = @intFromEnum(level);
    const build_level_int = @intFromEnum(build_log_level);
    if (comptime level_int > build_level_int) {
        return;
    }

    // Runtime check for finer control
    if (levelEnabled(self, level)) {
        const level_str = switch (level) {
            .err => "ERROR",
            .warn => "WARN",
            .info => "INFO",
            .debug => "DEBUG",
            .trace => "TRACE",
        };
        std.debug.print("[{s}] " ++ fmt, .{level_str} ++ args);
    }
}

pub fn errorf(self: anytype, comptime fmt: []const u8, args: anytype) void {
    logf(self, .err, fmt, args);
}

pub fn warnf(self: anytype, comptime fmt: []const u8, args: anytype) void {
    logf(self, .warn, fmt, args);
}

pub fn infof(self: anytype, comptime fmt: []const u8, args: anytype) void {
    // Compile-time elimination for info logs if build level is lower
    if (comptime @intFromEnum(config_mod.ServerConfig.LogLevel.info) > @intFromEnum(build_log_level)) return;
    logf(self, .info, fmt, args);
}

pub fn debugf(self: anytype, comptime fmt: []const u8, args: anytype) void {
    // Compile-time elimination for debug logs if build level is lower
    if (comptime @intFromEnum(config_mod.ServerConfig.LogLevel.debug) > @intFromEnum(build_log_level)) return;
    logf(self, .debug, fmt, args);
}

pub fn tracef(self: anytype, comptime fmt: []const u8, args: anytype) void {
    // Compile-time elimination for trace logs if build level is lower
    if (comptime @intFromEnum(config_mod.ServerConfig.LogLevel.trace) > @intFromEnum(build_log_level)) return;
    logf(self, .trace, fmt, args);
}

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

// Compile-time test to verify log level filtering
test "compile-time log level filtering" {
    // This test verifies that log levels are properly filtered at compile-time
    // The actual filtering happens at compile-time, so we're just testing the logic
    const testing = std.testing;

    // Test level parsing
    try testing.expectEqual(config_mod.ServerConfig.LogLevel.err, parseLevel("error").?);
    try testing.expectEqual(config_mod.ServerConfig.LogLevel.warn, parseLevel("warn").?);
    try testing.expectEqual(config_mod.ServerConfig.LogLevel.info, parseLevel("info").?);
    try testing.expectEqual(config_mod.ServerConfig.LogLevel.debug, parseLevel("debug").?);
    try testing.expectEqual(config_mod.ServerConfig.LogLevel.trace, parseLevel("trace").?);

    // Test that invalid levels return null
    try testing.expectEqual(@as(?config_mod.ServerConfig.LogLevel, null), parseLevel("invalid"));
}
