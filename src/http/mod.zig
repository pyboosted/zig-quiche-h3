// HTTP module - exports all HTTP-related types and functions

pub const handler = @import("handler.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const json = @import("json.zig");
pub const streaming = @import("streaming.zig");
pub const range = @import("range.zig");

// Re-export commonly used types at the module level
pub const Request = request.Request;
pub const Response = response.Response;
pub const Handler = handler.Handler;
pub const HandlerError = handler.HandlerError;
pub const Method = handler.Method;
pub const Status = handler.Status;
pub const Headers = handler.Headers;
pub const MimeTypes = handler.MimeTypes;
pub const Header = request.Header;

// Streaming callback types
pub const OnHeaders = handler.OnHeaders;
pub const OnBodyChunk = handler.OnBodyChunk;
pub const OnBodyComplete = handler.OnBodyComplete;
pub const StreamingError = handler.StreamingError;

// Datagram & WebTransport types
pub const OnH3Datagram = handler.OnH3Datagram;
pub const DatagramError = handler.DatagramError;
pub const WebTransportError = handler.WebTransportError;
pub const WebTransportStreamError = handler.WebTransportStreamError;

// Generator error type
pub const GeneratorError = handler.GeneratorError;

// Utility functions
pub const errorToStatus = handler.errorToStatus;

// Helpers
const std = @import("std");

/// Format an Allow header value from an EnumSet of methods.
pub fn formatAllowFromEnumSet(
    allocator: std.mem.Allocator,
    set: std.enums.EnumSet(Method),
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    const all = [_]Method{ .GET, .POST, .PUT, .DELETE, .HEAD, .OPTIONS, .PATCH, .CONNECT, .CONNECT_UDP, .TRACE };
    var first = true;
    inline for (all) |m| {
        if (set.contains(m)) {
            if (!first) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, m.toString());
            first = false;
        }
    }
    return allocator.dupe(u8, out.items);
}
