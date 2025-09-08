const std = @import("std");
const quiche = @import("quiche");

// H3 configuration with safe defaults
pub const H3Config = struct {
    config: quiche.h3.Config,
    
    pub fn initWithDefaults() !H3Config {
        var cfg = try quiche.h3.Config.new();
        errdefer cfg.deinit();
        
        // Set safe defaults as specified
        cfg.setMaxFieldSectionSize(16 * 1024);  // 16KiB - reasonable for most headers
        cfg.setQpackMaxTableCapacity(0);        // Disabled - simpler for M3
        cfg.setQpackBlockedStreams(0);          // No blocking - simpler for M3
        cfg.enableExtendedConnect(false);       // Standard H3 for now
        
        return H3Config{ .config = cfg };
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
};