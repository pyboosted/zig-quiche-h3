const std = @import("std");
const http = @import("http");
const routing = @import("routing");
const core = @import("matcher_core.zig");

pub const RouteDef = struct {
    pattern: []const u8,
    method: http.Method,
    handler: ?http.Handler = null,
    on_h3_dgram: ?http.handler.OnH3Datagram = null,
    on_headers: ?http.handler.OnHeaders = null,
    on_body_chunk: ?http.handler.OnBodyChunk = null,
    on_body_complete: ?http.handler.OnBodyComplete = null,
    on_wt_session: ?http.handler.OnWebTransportSession = null,
    on_wt_datagram: ?http.handler.OnWebTransportDatagram = null,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    lits: std.ArrayListUnmanaged(core.LiteralEntry) = .{},
    pats: std.ArrayListUnmanaged(core.PatternEntry) = .{},
    segments: std.ArrayListUnmanaged(core.Segment) = .{},
    pattern_storage: std.ArrayListUnmanaged([]u8) = .{},

    pub const Error = error{MissingStreamingCallbacks};

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        // Free copied strings and the arrays
        for (self.lits.items) |e| self.allocator.free(@constCast(e.path));
        for (self.pattern_storage.items) |p| self.allocator.free(p);
        self.lits.deinit(self.allocator);
        self.pats.deinit(self.allocator);
        self.segments.deinit(self.allocator);
        self.pattern_storage.deinit(self.allocator);
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
            .on_wt_session = def.on_wt_session,
            .on_wt_datagram = def.on_wt_datagram,
        };
        if (core.isStaticPath(pat_copy)) {
            try self.lits.append(self.allocator, .{ .path = pat_copy, .method = def.method, .route = fr });
        } else {
            errdefer self.allocator.free(pat_copy);

            const seg_len = core.countSegments(pat_copy);
            const off = self.segments.items.len;
            const seg_slice = try self.segments.addManyAsSlice(self.allocator, seg_len);
            errdefer self.segments.items.len = off;
            _ = core.writeSegments(pat_copy, seg_slice, 0);

            const storage_prev_len = self.pattern_storage.items.len;
            try self.pattern_storage.append(self.allocator, pat_copy);
            errdefer self.pattern_storage.items.len = storage_prev_len;

            try self.pats.append(self.allocator, .{ .off = off, .len = seg_len, .method = def.method, .route = fr });
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
            .on_wt_session = opts.on_wt_session,
            .on_wt_datagram = opts.on_wt_datagram,
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
        on_wt_session: ?http.handler.OnWebTransportSession = null,
        on_wt_datagram: ?http.handler.OnWebTransportDatagram = null,
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
            .on_wt_session = opts.on_wt_session,
            .on_wt_datagram = opts.on_wt_datagram,
        });
        return self;
    }

    pub fn build(self: *Builder) !DynMatcher {
        // Move entries into owned slices; keep strings owned as-is
        const lits = try self.lits.toOwnedSlice(self.allocator);
        const pats = try self.pats.toOwnedSlice(self.allocator);
        const segs = try self.segments.toOwnedSlice(self.allocator);
        const pat_storage = try self.pattern_storage.toOwnedSlice(self.allocator);
        // Reset builder containers to avoid double-free
        self.lits = .{};
        self.pats = .{};
        self.segments = .{};
        self.pattern_storage = .{};
        return DynMatcher{
            .allocator = self.allocator,
            .literals = lits,
            .patterns = pats,
            .segments = segs,
            .pattern_storage = pat_storage,
        };
    }
};

pub const DynMatcher = struct {
    allocator: std.mem.Allocator,
    literals: []core.LiteralEntry,
    patterns: []core.PatternEntry,
    segments: []core.Segment,
    pattern_storage: [][]u8,
    scratch_params: [16]routing.ParamSpan = undefined,

    pub fn intoMatcher(self: *DynMatcher) routing.Matcher {
        return .{ .vtable = &VTABLE, .ctx = self };
    }

    pub fn deinit(self: *DynMatcher) void {
        for (self.literals) |e| self.allocator.free(@constCast(e.path));
        for (self.pattern_storage) |p| self.allocator.free(p);
        self.allocator.free(self.literals);
        self.allocator.free(self.patterns);
        self.allocator.free(self.segments);
        self.allocator.free(self.pattern_storage);
        self.* = undefined;
    }

    const VTABLE = routing.MatcherVTable{ .match_fn = matchFn };

    fn matchFn(ctx: *anyopaque, method: http.Method, path: []const u8, out: *routing.MatchResult) bool {
        const self: *DynMatcher = @ptrCast(@alignCast(ctx));
        return core.matchPath(
            self.literals,
            self.patterns,
            self.segments,
            method,
            path,
            self.scratch_params[0..],
            out,
        );
    }
};

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
