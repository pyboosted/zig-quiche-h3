const std = @import("std");
const errors = @import("errors.zig");
const ClientError = errors.ClientError;

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const DatagramEvent = struct {
    flow_id: u64,
    payload: []const u8,
};

pub const ResponseEvent = union(enum) {
    headers: []const HeaderPair,
    data: []const u8,
    trailers: []const HeaderPair,
    finished,
    datagram: DatagramEvent,
};

pub const ResponseCallback = *const fn (event: ResponseEvent, ctx: ?*anyopaque) ClientError!void;

pub const BodyChunkResult = union(enum) {
    chunk: []const u8,
    finished,
};

pub const RequestBodyProvider = struct {
    ctx: ?*anyopaque = null,
    next: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) ClientError!BodyChunkResult,
};

pub const FetchOptions = struct {
    method: []const u8 = "GET",
    path: []const u8,
    headers: []const HeaderPair = &.{},
    body: []const u8 = &.{},
    body_provider: ?RequestBodyProvider = null,
    on_event: ?ResponseCallback = null,
    event_ctx: ?*anyopaque = null,
    timeout_override_ms: ?u32 = null,
};

pub const FetchResponse = struct {
    status: u16,
    body: []u8,
    headers: []HeaderPair,
    trailers: []HeaderPair,

    pub fn deinit(self: *FetchResponse, allocator: std.mem.Allocator) void {
        if (self.body.len > 0) allocator.free(self.body);
        for (self.headers) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        if (self.headers.len > 0) allocator.free(self.headers);
        for (self.trailers) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        if (self.trailers.len > 0) allocator.free(self.trailers);
        self.* = undefined;
    }
};
