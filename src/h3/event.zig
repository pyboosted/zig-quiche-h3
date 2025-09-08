const std = @import("std");
const quiche = @import("quiche");

// Header info for easier processing
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// Context for header collection
const HeaderCollector = struct {
    headers: *std.ArrayList(Header),
    allocator: std.mem.Allocator,
};

// Callback function for header iteration
fn headerCallback(
    name: [*c]u8,
    name_len: usize,
    value: [*c]u8,
    value_len: usize,
    argp: ?*anyopaque,
) callconv(.c) c_int {
    const collector = @as(*HeaderCollector, @ptrCast(@alignCast(argp orelse return -1)));
    
    // Create copies of the header data
    const name_slice = collector.allocator.dupe(u8, name[0..name_len]) catch return -1;
    const value_slice = collector.allocator.dupe(u8, value[0..value_len]) catch return -1;
    
    collector.headers.append(collector.allocator, Header{
        .name = name_slice,
        .value = value_slice,
    }) catch return -1;
    
    return 0; // Continue iteration
}

// Collect all headers from an event
pub fn collectHeaders(allocator: std.mem.Allocator, event: *quiche.c.quiche_h3_event) ![]Header {
    var headers = std.ArrayList(Header){};
    errdefer {
        for (headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers.deinit(allocator);
    }
    
    var collector = HeaderCollector{
        .headers = &headers,
        .allocator = allocator,
    };
    
    try quiche.h3.eventForEachHeader(event, headerCallback, &collector);
    
    return headers.toOwnedSlice(allocator);
}

// Free collected headers
pub fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

// Parse pseudo-headers for HTTP/3 requests
pub const RequestInfo = struct {
    method: ?[]const u8 = null,
    path: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
};

pub fn parseRequestHeaders(headers: []const Header) RequestInfo {
    var info = RequestInfo{};
    
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, ":method")) {
            info.method = h.value;
        } else if (std.mem.eql(u8, h.name, ":path")) {
            info.path = h.value;
        } else if (std.mem.eql(u8, h.name, ":authority")) {
            info.authority = h.value;
        } else if (std.mem.eql(u8, h.name, ":scheme")) {
            info.scheme = h.value;
        }
    }
    
    return info;
}