const std = @import("std");
const http = @import("http");
const enums = std.enums;

pub const Method = http.Method;
pub const Request = http.request.Request;
pub const Response = http.response.Response;

pub const ParamSpan = struct {
    name: []const u8,
    value: []const u8,
};

pub const FoundRoute = struct {
    handler: ?http.Handler = null,
    // Optional callbacks
    on_h3_dgram: ?http.handler.OnH3Datagram = null,
    on_headers: ?http.handler.OnHeaders = null,
    on_body_chunk: ?http.handler.OnBodyChunk = null,
    on_body_complete: ?http.handler.OnBodyComplete = null,
    on_wt_session: ?http.handler.OnWebTransportSession = null,
    on_wt_datagram: ?http.handler.OnWebTransportDatagram = null,
};

pub const MatchResult = union(enum) {
    Found: struct {
        route: *const FoundRoute,
        params: []const ParamSpan,
    },
    PathMatched: struct { allowed: enums.EnumSet(Method) },
    NotFound,
};

pub const MatcherVTable = struct {
    match_fn: *const fn (ctx: *anyopaque, method: Method, path: []const u8, out: *MatchResult) bool,
};

pub const Matcher = struct {
    vtable: *const MatcherVTable,
    ctx: *anyopaque,
};

// (Dynamic router adapter removed; we only support matchers.)
