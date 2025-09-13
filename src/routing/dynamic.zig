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

const PatternEntry = struct {
    pattern: []const u8,
    method: http.Method,
    route: routing.FoundRoute,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    lits: std.ArrayListUnmanaged(LiteralEntry) = .{},
    pats: std.ArrayListUnmanaged(PatternEntry) = .{},

    pub const Error = error{MissingStreamingCallbacks};

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        // Free copied strings and the arrays
        for (self.lits.items) |e| self.allocator.free(e.path);
        for (self.pats.items) |e| self.allocator.free(e.pattern);
        self.lits.deinit(self.allocator);
        self.pats.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn add(self: *Builder, def: RouteDef) !void {
        const pat_copy = try self.allocator.dupe(u8, def.pattern);
        const fr: routing.FoundRoute = .{
            .handler = def.handler,
            .on_h3_dgram = def.on_h3_dgram,
            .on_headers = def.on_headers,
            .on_body_chunk = def.on_body_chunk,
            .on_body_complete = def.on_body_complete,
            .on_wt_session = null,
            .on_wt_datagram = null,
        };
        if (isStaticPath(pat_copy)) {
            try self.lits.append(self.allocator, .{ .path = pat_copy, .method = def.method, .route = fr });
        } else {
            try self.pats.append(self.allocator, .{ .pattern = pat_copy, .method = def.method, .route = fr });
        }
    }

    pub fn fromRoutes(self: *Builder, routes: []const RouteDef) !void {
        for (routes) |r| try self.add(r);
    }

    // --- Chainers (ergonomics) ---
    pub fn route(self: *Builder, method: http.Method, pattern: []const u8, handler: http.Handler) !*Builder {
        try self.add(.{ .pattern = pattern, .method = method, .handler = handler });
        return self;
    }

    pub fn get(self: *Builder, pattern: []const u8, handler: http.Handler) !*Builder {
        return self.route(.GET, pattern, handler);
    }

    pub fn post(self: *Builder, pattern: []const u8, handler: http.Handler) !*Builder {
        return self.route(.POST, pattern, handler);
    }

    pub fn put(self: *Builder, pattern: []const u8, handler: http.Handler) !*Builder {
        return self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: *Builder, pattern: []const u8, handler: http.Handler) !*Builder {
        return self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: *Builder, pattern: []const u8, handler: http.Handler) !*Builder {
        return self.route(.PATCH, pattern, handler);
    }

    pub fn routeWithOpts(self: *Builder, method: http.Method, pattern: []const u8, handler: http.Handler, opts: StreamingOpts) !*Builder {
        try self.add(.{
            .pattern = pattern,
            .method = method,
            .handler = handler,
            .on_headers = opts.on_headers,
            .on_body_chunk = opts.on_body_chunk,
            .on_body_complete = opts.on_body_complete,
            .on_h3_dgram = opts.on_h3_dgram,
        });
        return self;
    }

    pub fn getWithOpts(self: *Builder, pattern: []const u8, handler: http.Handler, opts: StreamingOpts) !*Builder {
        return self.routeWithOpts(.GET, pattern, handler, opts);
    }

    pub fn postWithOpts(self: *Builder, pattern: []const u8, handler: http.Handler, opts: StreamingOpts) !*Builder {
        return self.routeWithOpts(.POST, pattern, handler, opts);
    }

    pub fn putWithOpts(self: *Builder, pattern: []const u8, handler: http.Handler, opts: StreamingOpts) !*Builder {
        return self.routeWithOpts(.PUT, pattern, handler, opts);
    }

    pub fn deleteWithOpts(self: *Builder, pattern: []const u8, handler: http.Handler, opts: StreamingOpts) !*Builder {
        return self.routeWithOpts(.DELETE, pattern, handler, opts);
    }

    pub fn patchWithOpts(self: *Builder, pattern: []const u8, handler: http.Handler, opts: StreamingOpts) !*Builder {
        return self.routeWithOpts(.PATCH, pattern, handler, opts);
    }

    pub const StreamingOpts = struct {
        method: http.Method = .POST,
        on_headers: ?http.handler.OnHeaders = null,
        on_body_chunk: ?http.handler.OnBodyChunk = null,
        on_body_complete: ?http.handler.OnBodyComplete = null,
        on_h3_dgram: ?http.handler.OnH3Datagram = null,
    };

    pub fn streaming(self: *Builder, pattern: []const u8, opts: StreamingOpts) !*Builder {
        if (opts.on_headers == null and opts.on_body_chunk == null and opts.on_body_complete == null) {
            return Error.MissingStreamingCallbacks;
        }
        try self.add(.{
            .pattern = pattern,
            .method = opts.method,
            .on_headers = opts.on_headers,
            .on_body_chunk = opts.on_body_chunk,
            .on_body_complete = opts.on_body_complete,
            .on_h3_dgram = opts.on_h3_dgram,
        });
        return self;
    }

    pub fn build(self: *Builder) !DynMatcher {
        // Move entries into owned slices; keep strings owned as-is
        const lits = try self.lits.toOwnedSlice(self.allocator);
        const pats = try self.pats.toOwnedSlice(self.allocator);
        // Reset builder containers to avoid double-free
        self.lits = .{};
        self.pats = .{};
        return DynMatcher{ .allocator = self.allocator, .literals = lits, .patterns = pats };
    }
};

pub const DynMatcher = struct {
    allocator: std.mem.Allocator,
    literals: []LiteralEntry,
    patterns: []PatternEntry,
    scratch_params: [16]routing.ParamSpan = undefined,

    pub fn intoMatcher(self: *DynMatcher) routing.Matcher {
        return .{ .vtable = &VTABLE, .ctx = self };
    }

    pub fn deinit(self: *DynMatcher) void {
        for (self.literals) |e| self.allocator.free(e.path);
        for (self.patterns) |e| self.allocator.free(e.pattern);
        self.allocator.free(self.literals);
        self.allocator.free(self.patterns);
        self.* = undefined;
    }

    const VTABLE = routing.MatcherVTable{ .match_fn = matchFn };

    fn matchFn(ctx: *anyopaque, method: http.Method, path: []const u8, out: *routing.MatchResult) bool {
        const self: *DynMatcher = @ptrCast(@alignCast(ctx));
        // Literal fast path with 405 aggregation
        var lit_allowed = enums.EnumSet(http.Method){};
        for (self.literals, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, path)) {
                if (e.method == method) {
                    out.* = .{ .Found = .{ .route = &self.literals[i].route, .params = &.{} } };
                    return true;
                }
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
            var span_count: usize = 0;
            if (matchPattern(e.pattern, path, self.scratch_params[0..], &span_count)) {
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

fn isStaticPath(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, ':') == null and std.mem.indexOfScalar(u8, s, '*') == null;
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

fn matchPattern(pattern: []const u8, path: []const u8, spans: []routing.ParamSpan, span_count: *usize) bool {
    var ip: usize = 0;
    var ix: usize = 0;
    span_count.* = 0;
    while (true) {
        const sp = nextSeg(pattern, &ip) orelse break;
        if (sp.len == 1 and sp[0] == '*') {
            // Capture the remainder of the path; skip a leading '/' if present
            var start = ix;
            if (start < path.len and path[start] == '/') start += 1;
            if (span_count.* < spans.len) {
                spans[span_count.*] = .{ .name = "*", .value = path[start..] };
                span_count.* += 1;
            }
            return true;
        }
        if (sp.len > 0 and sp[0] == ':') {
            const seg = nextSeg(path, &ix) orelse return false;
            if (span_count.* < spans.len) {
                spans[span_count.*] = .{ .name = sp[1..], .value = seg };
                span_count.* += 1;
            }
            continue;
        }
        const seg_path = nextSeg(path, &ix) orelse return false;
        if (!std.mem.eql(u8, sp, seg_path)) return false;
    }
    var tmp = ix;
    return nextSeg(path, &tmp) == null;
}

// ---- Unit Tests ----
const testing = std.testing;

test "dynamic: literal match and HEAD fallback" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.add(.{ .pattern = "/api/health", .method = .GET, .handler = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
    }.h });
    var m = try b.build();
    defer m.deinit();
    const mm = m.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .GET, "/api/health", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 0), out.Found.params.len);

    out = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .HEAD, "/api/health", &out);
    try testing.expect(out == .Found);
}

test "dynamic: params and wildcard" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.add(.{ .pattern = "/api/users/:id", .method = .GET, .handler = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
    }.h });
    try b.add(.{ .pattern = "/static/*", .method = .GET, .handler = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
    }.h });
    var m = try b.build();
    defer m.deinit();
    const mm = m.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .GET, "/api/users/123", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 1), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "id"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "123"));

    out = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .GET, "/static/a/b.txt", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 1), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "*"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "a/b.txt"));
}

test "dynamic: 405 PathMatched via EnumSet (patterns)" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.add(.{ .pattern = "/api/users", .method = .GET, .handler = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
    }.h });
    try b.add(.{ .pattern = "/api/users", .method = .POST, .handler = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
    }.h });
    var m = try b.build();
    defer m.deinit();
    const mm = m.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .DELETE, "/api/users", &out);
    try testing.expect(out == .PathMatched);
    try testing.expect(out.PathMatched.allowed.contains(.GET));
    try testing.expect(out.PathMatched.allowed.contains(.POST));
}

test "dynamic: precedence literal > param > wildcard (by order)" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.add(.{ .pattern = "/api/users/profile", .method = .GET, .handler = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
    }.h });
    try b.add(.{ .pattern = "/api/users/:id", .method = .GET, .handler = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
    }.h });
    try b.add(.{ .pattern = "/api/*", .method = .GET, .handler = struct {
        fn h(_: *http.Request, _: *http.Response) http.HandlerError!void {
            return;
        }
    }.h });
    var m = try b.build();
    defer m.deinit();
    const mm = m.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .GET, "/api/users/profile", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 0), out.Found.params.len);

    out = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .GET, "/api/users/123", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 1), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "id"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "123"));

    out = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .GET, "/api/other/stuff", &out);
    try testing.expect(out == .Found);
    try testing.expectEqual(@as(usize, 1), out.Found.params.len);
    try testing.expect(std.mem.eql(u8, out.Found.params[0].name, "*"));
    try testing.expect(std.mem.eql(u8, out.Found.params[0].value, "other/stuff"));
}

test "dynamic: streaming-only route (no handler)" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.add(.{ .pattern = "/upload/echo", .method = .POST, .on_headers = struct {
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
    }.h });
    var m = try b.build();
    defer m.deinit();
    const mm = m.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .POST, "/upload/echo", &out);
    try testing.expect(out == .Found);
    try testing.expect(out.Found.route.on_headers != null);
    try testing.expect(out.Found.route.handler == null);
}

test "dynamic: chainers get/post/streaming" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

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

    try (try b.get("/", H.h)).post("/api/echo", H.h);
    try b.streaming("/upload/echo", .{ .on_headers = H.hs, .on_body_chunk = H.cs, .on_body_complete = H.hs });

    var m = try b.build();
    defer m.deinit();
    const mm = m.intoMatcher();

    var out: routing.MatchResult = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .GET, "/", &out);
    try testing.expect(out == .Found);
    try testing.expect(out.Found.route.handler != null);

    out = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .POST, "/api/echo", &out);
    try testing.expect(out == .Found);

    out = .NotFound;
    _ = mm.vtable.match_fn(mm.ctx, .POST, "/upload/echo", &out);
    try testing.expect(out == .Found);
    try testing.expect(out.Found.route.handler == null);
    try testing.expect(out.Found.route.on_headers != null);
}
