const std = @import("std");
const config_mod = @import("config");
const server_logging = @import("logging.zig");
const build_options = @import("build_options");
const http = @import("http");

pub const RuntimeOverrides = struct {
    config: config_mod.ServerConfig,
    webtransport_enabled: bool,
    wt_streams: bool,
    wt_bidi: bool,
};

pub fn applyRuntimeOverrides(
    allocator: std.mem.Allocator,
    cfg: config_mod.ServerConfig,
    with_webtransport: bool,
) !RuntimeOverrides {
    var cfg_eff = cfg;

    const truthy = struct {
        fn value(bytes: []const u8) bool {
            return std.mem.eql(u8, bytes, "1") or
                std.mem.eql(u8, bytes, "true") or
                std.mem.eql(u8, bytes, "on") or
                std.mem.eql(u8, bytes, "yes") or
                std.mem.eql(u8, bytes, "enable") or
                std.mem.eql(u8, bytes, "enabled");
        }
    };

    if (server_logging.parseLevel(build_options.log_level)) |lvl| {
        cfg_eff.log_level = lvl;
    }

    if (std.process.getEnvVarOwned(allocator, "H3_LOG_LEVEL")) |lvl_s| {
        defer allocator.free(lvl_s);
        if (server_logging.parseLevel(lvl_s)) |lvl| cfg_eff.log_level = lvl;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "H3_DEBUG")) |dbg| {
        defer allocator.free(dbg);
        if (dbg.len > 0 and (std.mem.eql(u8, dbg, "1") or std.mem.eql(u8, dbg, "true") or std.mem.eql(u8, dbg, "on"))) {
            cfg_eff.enable_debug_logging = true;
            if (@intFromEnum(cfg_eff.log_level) < @intFromEnum(config_mod.ServerConfig.LogLevel.debug)) {
                cfg_eff.log_level = .debug;
            }
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "H3_MAX_BODY_MB")) |mb| {
        defer allocator.free(mb);
        const val = std.fmt.parseUnsigned(usize, mb, 10) catch 0;
        if (val > 0) {
            const bytes = val * 1024 * 1024;
            cfg_eff.max_non_streaming_body_bytes = bytes;
            if (cfg_eff.enable_debug_logging) {
                std.debug.print("[INFO] H3: max_non_streaming_body_bytes set to {} bytes via H3_MAX_BODY_MB\n", .{bytes});
            }
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "H3_CHUNK_SIZE")) |cs| {
        defer allocator.free(cs);
        const val = std.fmt.parseUnsigned(usize, cs, 10) catch 0;
        if (val > 0) {
            http.streaming.setDefaultChunkSize(val);
            if (cfg_eff.enable_debug_logging) {
                std.debug.print("[INFO] H3: streaming chunk size set to {} via H3_CHUNK_SIZE\n", .{val});
            }
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "H3_MAX_REQS_PER_CONN")) |rq| {
        defer allocator.free(rq);
        const val = std.fmt.parseUnsigned(usize, rq, 10) catch 0;
        if (val > 0) {
            cfg_eff.max_active_requests_per_conn = val;
            if (cfg_eff.enable_debug_logging) {
                std.debug.print("[INFO] H3: max_active_requests_per_conn set to {} via H3_MAX_REQS_PER_CONN\n", .{val});
            }
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "H3_MAX_DOWNLOADS_PER_CONN")) |dq| {
        defer allocator.free(dq);
        std.debug.print("[DEBUG] H3_MAX_DOWNLOADS_PER_CONN env var = '{s}'\n", .{dq});
        const val = std.fmt.parseUnsigned(usize, dq, 10) catch 0;
        if (val > 0) {
            cfg_eff.max_active_downloads_per_conn = val;
            std.debug.print("[INFO] H3: max_active_downloads_per_conn set to {} via H3_MAX_DOWNLOADS_PER_CONN\n", .{val});
        }
    } else |_| {
        std.debug.print("[DEBUG] H3_MAX_DOWNLOADS_PER_CONN env var not set\n", .{});
    }

    const wt_env_owned = std.process.getEnvVarOwned(allocator, "H3_WEBTRANSPORT") catch null;
    const webtransport_enabled = blk: {
        if (wt_env_owned) |wt| {
            defer allocator.free(wt);
            if (std.mem.eql(u8, wt, "1")) {
                if (with_webtransport) {
                    std.debug.print("WebTransport: enabled (H3_WEBTRANSPORT=1, -Dwith-webtransport=true)\n", .{});
                    break :blk true;
                } else {
                    std.debug.print("WebTransport: disabled at build time; ignoring H3_WEBTRANSPORT=1\n", .{});
                }
            }
        }
        break :blk false;
    };

    const wt_streams_env = std.process.getEnvVarOwned(allocator, "H3_WT_STREAMS") catch null;
    const wt_streams = blk: {
        if (wt_streams_env) |wts| {
            defer allocator.free(wts);
            if (std.mem.eql(u8, wts, "1")) {
                if (with_webtransport) {
                    std.debug.print("WebTransport Streams: enabled (H3_WT_STREAMS=1)\n", .{});
                    break :blk true;
                } else {
                    std.debug.print("WebTransport Streams: disabled at build time; ignoring H3_WT_STREAMS=1\n", .{});
                }
            }
        }
        break :blk false;
    };

    const wt_bidi_env = std.process.getEnvVarOwned(allocator, "H3_WT_BIDI") catch null;
    const wt_bidi = blk: {
        if (wt_bidi_env) |wtb| {
            defer allocator.free(wtb);
            if (std.mem.eql(u8, wtb, "1")) {
                if (with_webtransport) {
                    std.debug.print("WebTransport Bidi Streams: enabled (H3_WT_BIDI=1)\n", .{});
                    break :blk true;
                } else {
                    std.debug.print("WebTransport Bidi Streams: disabled at build time; ignoring H3_WT_BIDI=1\n", .{});
                }
            }
        }
        break :blk false;
    };

    var enable_h3_dgram = cfg_eff.enable_dgram;

    if (std.process.getEnvVarOwned(allocator, "H3_ENABLE_DGRAM")) |env_val| {
        defer allocator.free(env_val);
        enable_h3_dgram = truthy.value(env_val);
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "H3_DGRAM_ECHO")) |env_val| {
        defer allocator.free(env_val);
        if (truthy.value(env_val)) {
            enable_h3_dgram = true;
        }
    } else |_| {}

    if (enable_h3_dgram) {
        cfg_eff.enable_dgram = true;
        if (cfg_eff.dgram_recv_queue_len == 0) cfg_eff.dgram_recv_queue_len = 1024;
        if (cfg_eff.dgram_send_queue_len == 0) cfg_eff.dgram_send_queue_len = 1024;
    }

    return RuntimeOverrides{
        .config = cfg_eff,
        .webtransport_enabled = webtransport_enabled,
        .wt_streams = wt_streams,
        .wt_bidi = wt_bidi,
    };
}
