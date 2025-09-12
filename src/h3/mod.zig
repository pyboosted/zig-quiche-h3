// HTTP/3 module exports
pub const config = @import("config.zig");
pub const connection = @import("connection.zig");
pub const event = @import("event.zig");
pub const datagram = @import("datagram.zig");
pub const webtransport = @import("webtransport.zig");

// Re-export commonly used types
pub const H3Config = config.H3Config;
pub const H3Connection = connection.H3Connection;
pub const Header = event.Header;
pub const RequestInfo = event.RequestInfo;
pub const WebTransportSession = webtransport.WebTransportSession;
pub const WebTransportSessionState = webtransport.WebTransportSessionState;

// Re-export helper functions
pub const collectHeaders = event.collectHeaders;
pub const freeHeaders = event.freeHeaders;
pub const parseRequestHeaders = event.parseRequestHeaders;
