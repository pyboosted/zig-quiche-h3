const std = @import("std");
const http = @import("http");
const routing = @import("routing");
const enums = std.enums;

pub const RouteDef = struct {
    pattern: []const u8,
    method: http.Method,
    handler: ?http.Handler = null,
    on_h3_dgram: ?http.handler.OnH3Datagram = null,
    on_headers: ?http.handler.OnHeaders = null,
    on_body_chunk: ?http.handler.OnBodyChunk = null,
    on_body_complete: ?http.handler.OnBodyComplete = null,
};

const LiteralEntry = struct {
    path: []const u8,
    method: http.Method,
    route: routing.FoundRoute,
};

const Segment = union(enum) {
    Literal: []const u8,
    Param: []const u8,
    Wildcard,
};

const PatternEntry = struct {
    off: usize, // offset into segments array
    len: usize, // number of segments for this pattern
    method: http.Method,
    route: routing.FoundRoute,
};

pub fn compileRoutes(comptime routes: []const RouteDef) type {
    comptime var lit_count: usize = 0;
    comptime var pat_count: usize = 0;
    comptime var total_segments: usize = 0;
    inline for (routes) |r| {
        if (isStaticPath(r.pattern)) {
            lit_count += 1;
        } else {
            pat_count += 1;
            total_segments += countSegments(r.pattern);
        }
    }

    const Self = struct {
        pub const literals: [lit_count]LiteralEntry = buildLiterals();
        pub const segments: [total_segments]Segment = buildSegments();
        pub const patterns: [pat_count]PatternEntry = buildPatterns();

        fn buildLiterals() [lit_count]LiteralEntry {
            var out: [lit_count]LiteralEntry = undefined;
            var i: usize = 0;
            inline for (routes) |r| {
                if (isStaticPath(r.pattern)) {
                    out[i] = .{ .path = r.pattern, .method = r.method, .route = .{
                        .handler = r.handler,
                        .on_h3_dgram = r.on_h3_dgram,
                        .on_headers = r.on_headers,
                        .on_body_chunk = r.on_body_chunk,
                        .on_body_complete = r.on_body_complete,
                        .on_wt_session = null,
                        .on_wt_datagram = null,
                    } };
                    i += 1;
                }
            }
            return out;
        }

        fn buildPatterns() [pat_count]PatternEntry {
            var out: [pat_count]PatternEntry = undefined;
            var i: usize = 0;
            var off: usize = 0;
            inline for (routes) |r| {
                if (!isStaticPath(r.pattern)) {
                    const segs_len = countSegments(r.pattern);
                    out[i] = .{
                        .off = off,
                        .len = segs_len,
                        .method = r.method,
                        .route = .{
                            .handler = r.handler,
                            .on_h3_dgram = r.on_h3_dgram,
                            .on_headers = r.on_headers,
                            .on_body_chunk = r.on_body_chunk,
                            .on_body_complete = r.on_body_complete,
                            .on_wt_session = null,
                            .on_wt_datagram = null,
                        },
                    };
                    off += segs_len;
                    i += 1;
                }
            }
            return out;
        }

        fn buildSegments() [total_segments]Segment {
            var out: [total_segments]Segment = undefined;
            var off: usize = 0;
            inline for (routes) |r| {
                if (!isStaticPath(r.pattern)) {
                    off = writeSegments(r.pattern, &out, off);
                }
            }
            return out;
        }

        pub fn instance() GeneratedMatcher {
            return .{
                .literals = literals[0..],
                .segments = segments[0..],
                .patterns = patterns[0..],
            };
        }
    };
    return Self;
}

pub const GeneratedMatcher = struct {
    literals: []const LiteralEntry,
    segments: []const Segment,
    patterns: []const PatternEntry,
    scratch_params: [16]routing.ParamSpan = undefined,

    pub fn intoMatcher(self: *GeneratedMatcher) routing.Matcher {
        return .{ .vtable = &VTABLE, .ctx = self };
    }

    pub fn asMatcher(self: *GeneratedMatcher) routing.Matcher {
        return self.intoMatcher();
    }

    const VTABLE = routing.MatcherVTable{ .match_fn = matchFn };

    fn matchFn(ctx: *anyopaque, method: http.Method, path: []const u8, out: *routing.MatchResult) bool {
        const self: *GeneratedMatcher = @ptrCast(@alignCast(ctx));
        // Literal fast path (use stable pointer into literals array) with 405 aggregation
        var lit_allowed = enums.EnumSet(http.Method){};
        for (self.literals, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, path)) {
                if (e.method == method) {
                    out.* = .{ .Found = .{ .route = &self.literals[i].route, .params = &.{} } };
                    return true;
                }
                // HEAD fallback to GET
                if (method == .HEAD and e.method == .GET) {
                    out.* = .{ .Found = .{ .route = &self.literals[i].route, .params = &.{} } };
                    return true;
                }
                lit_allowed.insert(e.method);
            }
        }
        if (lit_allowed.count() > 0) {
            out.* = .{ .PathMatched = .{ .allowed = lit_allowed } };
            return true;
        }

        // Pattern routes with 405 aggregation
        var allowed = enums.EnumSet(http.Method){};
        for (self.patterns, 0..) |e, i| {
            // Defensive bound check in case of a bad compile-time accounting bug
            if (e.off + e.len > self.segments.len) {
                // Treat as not found rather than reading OOB
                continue;
            }
            var span_count: usize = 0;
            if (matchSegments(self.segments[e.off .. e.off + e.len], path, self.scratch_params[0..], &span_count)) {
                allowed.insert(e.method);
                if (e.method == method or (method == .HEAD and e.method == .GET)) {
                    out.* = .{ .Found = .{ .route = &self.patterns[i].route, .params = self.scratch_params[0..span_count] } };
                    return true;
                }
            }
        }
        if (allowed.count() > 0) {
            out.* = .{ .PathMatched = .{ .allowed = allowed } };
            return true;
        }
        out.* = .NotFound;
        return true;
    }
};

/// Convenience: build a GeneratedMatcher state from routes.
///
/// The returned state must be kept alive and mutable for the lifetime
/// of the server because it contains a small internal scratch buffer
/// used to expose borrowed ParamSpan slices during match().
/// Prefer holding this in a `var` and pass `state.asMatcher()` to
/// `QuicServer.init(...)`.
pub fn compileMatcher(comptime routes: []const RouteDef) GeneratedMatcher {
    const Gen = compileRoutes(routes);
    const gen = Gen.instance();
    return gen;
}

// ---- Helper constructors for compile-time RouteDef arrays ----
pub const StreamOpts = struct {
    method: http.Method = .POST,
    on_headers: ?http.handler.OnHeaders = null,
    on_body_chunk: ?http.handler.OnBodyChunk = null,
    on_body_complete: ?http.handler.OnBodyComplete = null,
    on_h3_dgram: ?http.handler.OnH3Datagram = null,
};

pub fn route(method: http.Method, pattern: []const u8, handler: http.Handler) RouteDef {
    return .{ .pattern = pattern, .method = method, .handler = handler };
}

pub fn GET(pattern: []const u8, handler: http.Handler) RouteDef {
    return route(.GET, pattern, handler);
}

pub fn POST(pattern: []const u8, handler: http.Handler) RouteDef {
    return route(.POST, pattern, handler);
}

pub fn PUT(pattern: []const u8, handler: http.Handler) RouteDef {
    return route(.PUT, pattern, handler);
}

pub fn DELETE(pattern: []const u8, handler: http.Handler) RouteDef {
    return route(.DELETE, pattern, handler);
}

pub fn PATCH(pattern: []const u8, handler: http.Handler) RouteDef {
    return route(.PATCH, pattern, handler);
}

pub fn STREAM(comptime pattern: []const u8, comptime opts: StreamOpts) RouteDef {
    if (opts.on_headers == null and opts.on_body_chunk == null and opts.on_body_complete == null) {
        @compileError("STREAM requires at least one of on_headers/on_body_chunk/on_body_complete");
    }
    return .{
        .pattern = pattern,
        .method = opts.method,
        .on_headers = opts.on_headers,
        .on_body_chunk = opts.on_body_chunk,
        .on_body_complete = opts.on_body_complete,
        .on_h3_dgram = opts.on_h3_dgram,
    };
}

pub fn ROUTE_OPTS(comptime method: http.Method, comptime pattern: []const u8, handler: http.Handler, comptime opts: StreamOpts) RouteDef {
    return .{
        .pattern = pattern,
        .method = method,
        .handler = handler,
        .on_headers = opts.on_headers,
        .on_body_chunk = opts.on_body_chunk,
        .on_body_complete = opts.on_body_complete,
        .on_h3_dgram = opts.on_h3_dgram,
    };
}

/// Returns a tiny wrapper type that embeds the matcher state.
///
/// Usage:
///   var router = compileMatcherType(&routes){};
///   const matcher = router.matcher();
///
/// The wrapper holds the same mutable state described in compileMatcher().
pub fn compileMatcherType(comptime routes: []const RouteDef) type {
    const Gen = compileRoutes(routes);
    return struct {
        state: GeneratedMatcher = Gen.instance(),

        pub fn matcher(self: *@This()) routing.Matcher {
            return self.state.asMatcher();
        }
    };
}

fn isStaticPath(comptime s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, ':') == null and std.mem.indexOfScalar(u8, s, '*') == null;
}

// ---- Unit Tests ----
const testing = std.testing;

test "generator: literal match and HEAD fallback" {
    const routes = [_]RouteDef{
        .{ .pattern = "/api/health", .method = .GET, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
    };
    const Gen = compileRoutes(&routes);
    var gen = Gen.instance();
    const m = gen.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .GET, "/api/health", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 0), out.Found.params.len);

    out = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .HEAD, "/api/health", &out);
    try testing.expect(out == .Found);
}

test "generator: params and wildcard" {
    const routes = [_]RouteDef{
        .{ .pattern = "/api/users/:id", .method = .GET, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
        .{ .pattern = "/static/*", .method = .GET, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
    };
    const Gen = compileRoutes(&routes);
    var gen = Gen.instance();
    const m = gen.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .GET, "/api/users/123", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 1), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "id"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "123"));

    out = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .GET, "/static/a/b.txt", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 1), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "*"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "a/b.txt"));
}

test "generator: 405 PathMatched via EnumSet" {
    const routes = [_]RouteDef{
        .{ .pattern = "/api/users", .method = .GET, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
        .{ .pattern = "/api/users", .method = .POST, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
    };
    const Gen = compileRoutes(&routes);
    var gen = Gen.instance();
    const m = gen.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .DELETE, "/api/users", &out);
    try testing.expect(out == .PathMatched);
    try testing.expect(out.PathMatched.allowed.contains(.GET));
    try testing.expect(out.PathMatched.allowed.contains(.POST));
}

test "generator: precedence literal > param > wildcard" {
    const routes = [_]RouteDef{
        // literal must win over param
        .{ .pattern = "/api/users/profile", .method = .GET, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
        // param before wildcard so it wins for /api/users/123
        .{ .pattern = "/api/users/:id", .method = .GET, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
        .{ .pattern = "/api/*", .method = .GET, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
    };
    const Gen = compileRoutes(&routes);
    var gen = Gen.instance();
    const m = gen.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .GET, "/api/users/profile", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 0), out.Found.params.len);

    out = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .GET, "/api/users/123", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 1), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "id"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "123"));

    out = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .GET, "/api/other/stuff", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 1), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "*"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "other/stuff"));
}

test "generator: multiple params in order" {
    const routes = [_]RouteDef{
        .{ .pattern = "/a/:x/b/:y", .method = .GET, .handler = struct {
            fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
                return;
            }
        }.h },
    };
    const Gen = compileRoutes(&routes);
    var gen = Gen.instance();
    const m = gen.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .GET, "/a/1/b/2", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 2), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "x"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "1"));
    try testing.expect(std.mem.eql(u8, out.Found.params[1].name, "y"));
    try testing.expect(std.mem.eql(u8, out.Found.params[1].value, "2"));
}

test "generator: helper constructors GET/POST/STREAM" {
    const H = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
        fn hs(_: *http.Request, _: *http.Response) http.StreamingError!void {
            return;
        }
        fn cs(_: *http.Request, _: *http.Response, _: []const u8) http.StreamingError!void {
            return;
        }
    };

    const routes = [_]RouteDef{
        GET("/", H.h),
        POST("/api/echo", H.h),
        STREAM("/upload/echo", .{ .on_headers = H.hs, .on_body_chunk = H.cs, .on_body_complete = H.hs }),
    };
    const Gen = compileRoutes(&routes);
    var gen = Gen.instance();
    const m = gen.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .GET, "/", &out);
    try testing.expect(out == .Found);

    out = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .POST, "/api/echo", &out);
    try testing.expect(out == .Found);

    out = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .POST, "/upload/echo", &out);
    try testing.expect(out == .Found);
    try testing.expect(out.Found.route.handler == null);
    try testing.expect(out.Found.route.on_headers != null);
}

test "generator: streaming-only route (no handler)" {
    const routes = [_]RouteDef{
        .{ .pattern = "/upload/echo", .method = .POST, .on_headers = struct {
            fn h(_: *http.Request, _: *http.Response) http.StreamingError!void {
                return;
            }
        }.h, .on_body_chunk = struct {
            fn h(_: *http.Request, _: *http.Response, _: []const u8) http.StreamingError!void {
                return;
            }
        }.h, .on_body_complete = struct {
            fn h(_: *http.Request, _: *http.Response) http.StreamingError!void {
                return;
            }
        }.h },
    };
    const Gen = compileRoutes(&routes);
    var gen = Gen.instance();
    const m = gen.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = m.vtable.match_fn(m.ctx, .POST, "/upload/echo", &out);
    try testing.expect(out == .Found);
    try testing.expect(out.Found.route.on_headers != null);
    try testing.expect(out.Found.route.handler == null);
}

fn nextSeg(s: []const u8, idx: *usize) ?[]const u8 {
    var i = idx.*;
    while (i < s.len and s[i] == '/') : (i += 1) {}
    if (i >= s.len) {
        idx.* = i;
        return null;
    }
    const start = i;
    while (i < s.len and s[i] != '/') : (i += 1) {}
    const seg = s[start..i];
    idx.* = i;
    return seg;
}

fn matchSegments(segments: []const Segment, path: []const u8, spans: []routing.ParamSpan, span_count: *usize) bool {
    var ix: usize = 0;
    span_count.* = 0;
    var i: usize = 0;
    while (i < segments.len) : (i += 1) {
        switch (segments[i]) {
            .Wildcard => {
                // Capture the remainder of the path; skip a leading '/' if present
                var start = ix;
                if (start < path.len and path[start] == '/') start += 1;
                if (span_count.* < spans.len) {
                    spans[span_count.*] = .{ .name = "*", .value = path[start..] };
                    span_count.* += 1;
                }
                return true;
            },
            .Param => |name| {
                const seg_path = nextSeg(path, &ix) orelse return false;
                if (span_count.* < spans.len) {
                    spans[span_count.*] = .{ .name = name, .value = seg_path };
                    span_count.* += 1;
                }
            },
            .Literal => |lit| {
                const seg_path = nextSeg(path, &ix) orelse return false;
                if (!std.mem.eql(u8, lit, seg_path)) return false;
            },
        }
    }
    var tmp = ix;
    return nextSeg(path, &tmp) == null;
}

fn countSegments(comptime pattern: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (true) {
        const seg = nextSeg(pattern, &i) orelse break;
        _ = seg;
        count += 1;
    }
    return count;
}

fn writeSegments(comptime pattern: []const u8, out: []Segment, start_off: usize) usize {
    var off = start_off;
    var i: usize = 0;
    while (true) {
        const seg = nextSeg(pattern, &i) orelse break;
        if (seg.len == 1 and seg[0] == '*') {
            out[off] = .Wildcard;
        } else if (seg.len > 0 and seg[0] == ':') {
            out[off] = .{ .Param = seg[1..] };
        } else {
            out[off] = .{ .Literal = seg };
        }
        off += 1;
    }
    return off;
}
