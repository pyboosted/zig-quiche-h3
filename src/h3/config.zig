const std = @import("std");
const quiche = @import("quiche");

// H3 configuration with safe defaults
pub const H3Config = struct {
    config: quiche.h3.Config,
    enable_webtransport: bool = false,

    pub fn initWithDefaults() !H3Config {
        var cfg = try quiche.h3.Config.new();
        errdefer cfg.deinit();

        // Set safe defaults
        cfg.setMaxFieldSectionSize(16 * 1024); // 16KiB - reasonable for most headers
        // Enable QPACK dynamic table to improve header compression for many
        // small responses. Values are modest and broadly compatible.
        cfg.setQpackMaxTableCapacity(4096); // 4 KiB dynamic table
        cfg.setQpackBlockedStreams(32); // allow up to 32 blocked streams
        cfg.enableExtendedConnect(false); // Standard H3 for now

        return H3Config{
            .config = cfg,
            .enable_webtransport = false,
        };
    }

    pub fn initWithWebTransport() !H3Config {
        var cfg = try quiche.h3.Config.new();
        errdefer cfg.deinit();

        // Set safe defaults
        cfg.setMaxFieldSectionSize(16 * 1024); // 16KiB - reasonable for most headers
        cfg.setQpackMaxTableCapacity(4096); // 4 KiB dynamic table
        cfg.setQpackBlockedStreams(32); // allow up to 32 blocked streams
        cfg.enableExtendedConnect(true); // Enable Extended CONNECT for WebTransport

        return H3Config{
            .config = cfg,
            .enable_webtransport = true,
        };
    }

    pub fn deinit(self: *H3Config) void {
        self.config.deinit();
    }

    // Allow customization if needed
    pub fn setMaxFieldSectionSize(self: *H3Config, v: u64) void {
        self.config.setMaxFieldSectionSize(v);
    }

    pub fn setQpackMaxTableCapacity(self: *H3Config, v: u64) void {
        self.config.setQpackMaxTableCapacity(v);
    }

    pub fn setQpackBlockedStreams(self: *H3Config, v: u64) void {
        self.config.setQpackBlockedStreams(v);
    }

    pub fn enableExtendedConnect(self: *H3Config, enabled: bool) void {
        self.config.enableExtendedConnect(enabled);
    }

    pub fn enableWebTransport(self: *H3Config, enabled: bool) void {
        self.enable_webtransport = enabled;
        if (enabled) {
            self.config.enableExtendedConnect(true);
        }
    }
};
