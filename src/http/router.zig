const std = @import("std");
const pattern = @import("pattern.zig");
const Method = @import("handler.zig").Method;
const Handler = @import("handler.zig").Handler;

/// A single route with its compiled pattern and handler
pub const Route = struct {
    pattern: pattern.CompiledPattern,
    handler: Handler,
    method: Method,
    raw_pattern: []const u8, // Keep for debugging
};

/// Result of route matching
pub const MatchResult = union(enum) {
    Found: struct {
        route: *const Route,
        params: std.StringHashMapUnmanaged([]const u8),
    },
    NotFound,
    MethodNotAllowed: struct {
        allowed_methods: []Method,
    },
};

/// HTTP router with pattern matching and method routing
pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route),
    
    pub fn init(allocator: std.mem.Allocator) Router {
        return Router{
            .allocator = allocator,
            .routes = std.ArrayList(Route){},
        };
    }
    
    pub fn deinit(self: *Router) void {
        for (self.routes.items) |*r| {
            r.pattern.deinit();
            self.allocator.free(r.raw_pattern);
        }
        self.routes.deinit(self.allocator);
    }
    
    /// Register a route with the router
    pub fn route(self: *Router, method: Method, route_pattern: []const u8, handler: Handler) !void {
        // Compile the pattern
        var compiled = try pattern.compile(self.allocator, route_pattern);
        errdefer compiled.deinit();
        
        // Store the raw pattern for debugging
        const raw = try self.allocator.dupe(u8, route_pattern);
        errdefer self.allocator.free(raw);
        
        try self.routes.append(self.allocator, Route{
            .pattern = compiled,
            .handler = handler,
            .method = method,
            .raw_pattern = raw,
        });
        
        // Sort routes by specificity (higher score first)
        std.mem.sort(Route, self.routes.items, {}, compareRoutes);
    }
    
    /// Match a request against registered routes
    pub fn match(
        self: *Router,
        temp_allocator: std.mem.Allocator,
        method: Method,
        path: []const u8,
    ) !MatchResult {
        var best_match: ?*const Route = null;
        var best_params: ?std.StringHashMapUnmanaged([]const u8) = null;
        var path_matches = std.ArrayList(*const Route){};
        defer path_matches.deinit(temp_allocator);
        
        // Find all routes that match the path
        for (self.routes.items) |*r| {
            var params = std.StringHashMapUnmanaged([]const u8){};
            defer {
                // Clean up params if we're not using them
                if (best_params == null or &params != &best_params.?) {
                    var iter = params.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.*.len > 0 and entry.value_ptr.*[0] != 0) {
                            temp_allocator.free(entry.value_ptr.*);
                        }
                    }
                    params.deinit(temp_allocator);
                }
            }
            
            const matched = pattern.match(temp_allocator, &r.pattern, path, &params) catch continue;
            if (matched) {
                try path_matches.append(temp_allocator, r);
                
                // Check if this route matches the method
                if (r.method == method) {
                    // Found a match with correct method
                    if (best_match == null or r.pattern.specificity_score > best_match.?.pattern.specificity_score) {
                        // Clean up previous best params
                        if (best_params) |*bp| {
                            var iter = bp.iterator();
                            while (iter.next()) |entry| {
                                temp_allocator.free(entry.value_ptr.*);
                            }
                            bp.deinit(temp_allocator);
                        }
                        
                        best_match = r;
                        best_params = params;
                        params = std.StringHashMapUnmanaged([]const u8){}; // Create new empty to avoid double-free
                    }
                }
            }
        }
        
        // Check if we found a matching route
        if (best_match) |matched_route| {
            return MatchResult{ 
                .Found = .{
                    .route = matched_route,
                    .params = best_params.?,
                },
            };
        }
        
        // No method match, but path matched - return 405
        if (path_matches.items.len > 0) {
            var allowed = std.ArrayList(Method){};
            defer allowed.deinit(temp_allocator);
            
            var seen = std.EnumSet(Method){};
            for (path_matches.items) |path_route| {
                if (!seen.contains(path_route.method)) {
                    try allowed.append(temp_allocator, path_route.method);
                    seen.insert(path_route.method);
                }
            }
            
            const allowed_methods = try temp_allocator.alloc(Method, allowed.items.len);
            @memcpy(allowed_methods, allowed.items);
            
            return MatchResult{ 
                .MethodNotAllowed = .{ .allowed_methods = allowed_methods },
            };
        }
        
        // No routes matched the path
        return MatchResult.NotFound;
    }
    
    /// Generate an Allow header value from methods
    pub fn formatAllowHeader(
        allocator: std.mem.Allocator,
        methods: []const Method,
    ) ![]u8 {
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);
        
        for (methods, 0..) |method, i| {
            if (i > 0) {
                try result.appendSlice(allocator, ", ");
            }
            try result.appendSlice(allocator, method.toString());
        }
        
        return allocator.dupe(u8, result.items);
    }
    
    /// Compare routes for sorting by specificity
    fn compareRoutes(_: void, a: Route, b: Route) bool {
        // Higher score = higher priority (comes first)
        return a.pattern.specificity_score > b.pattern.specificity_score;
    }
};

// Tests
test "router basic matching" {
    const allocator = std.testing.allocator;
    
    var router = Router.init(allocator);
    defer router.deinit();
    
    const testHandler: Handler = struct {
        fn handler(_: *@import("request.zig").Request, _: *@import("response.zig").Response) !void {}
    }.handler;
    
    // Add routes
    try router.route(.GET, "/", testHandler);
    try router.route(.GET, "/api/users", testHandler);
    try router.route(.GET, "/api/users/:id", testHandler);
    try router.route(.POST, "/api/users", testHandler);
    try router.route(.GET, "/files/*", testHandler);
    
    // Test exact match
    {
        const result = try router.match(allocator, .GET, "/api/users");
        defer {
            if (result == .Found) {
                result.Found.params.deinit(allocator);
            } else if (result == .MethodNotAllowed) {
                allocator.free(result.MethodNotAllowed.allowed_methods);
            }
        }
        
        try std.testing.expect(result == .Found);
    }
    
    // Test parameter extraction
    {
        const result = try router.match(allocator, .GET, "/api/users/123");
        defer {
            if (result == .Found) {
                var iter = result.Found.params.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.value_ptr.*);
                }
                result.Found.params.deinit(allocator);
            }
        }
        
        try std.testing.expect(result == .Found);
        try std.testing.expectEqualStrings("123", result.Found.params.get("id").?);
    }
    
    // Test method not allowed
    {
        const result = try router.match(allocator, .DELETE, "/api/users");
        defer {
            if (result == .MethodNotAllowed) {
                allocator.free(result.MethodNotAllowed.allowed_methods);
            }
        }
        
        try std.testing.expect(result == .MethodNotAllowed);
        try std.testing.expect(result.MethodNotAllowed.allowed_methods.len == 2); // GET and POST
    }
    
    // Test not found
    {
        const result = try router.match(allocator, .GET, "/nonexistent");
        try std.testing.expect(result == .NotFound);
    }
    
    // Test wildcard matching
    {
        const result = try router.match(allocator, .GET, "/files/path/to/file.txt");
        defer {
            if (result == .Found) {
                var iter = result.Found.params.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.value_ptr.*);
                }
                result.Found.params.deinit(allocator);
            }
        }
        
        try std.testing.expect(result == .Found);
        try std.testing.expectEqualStrings("path/to/file.txt", result.Found.params.get("*").?);
    }
}

test "router specificity ordering" {
    const allocator = std.testing.allocator;
    
    var router = Router.init(allocator);
    defer router.deinit();
    
    const testHandler: Handler = struct {
        fn handler(_: *@import("request.zig").Request, _: *@import("response.zig").Response) !void {}
    }.handler;
    
    // Add routes in reverse specificity order
    try router.route(.GET, "/api/*", testHandler);
    try router.route(.GET, "/api/users/:id", testHandler);
    try router.route(.GET, "/api/users/profile", testHandler);
    
    // The most specific route should match
    {
        const result = try router.match(allocator, .GET, "/api/users/profile");
        defer {
            if (result == .Found) {
                result.Found.params.deinit(allocator);
            }
        }
        
        try std.testing.expect(result == .Found);
        // Should match the literal route, not the param route
        try std.testing.expect(result.Found.params.count() == 0);
    }
}

test "allow header formatting" {
    const allocator = std.testing.allocator;
    
    const methods = [_]Method{ .GET, .POST, .PUT };
    const allow = try Router.formatAllowHeader(allocator, &methods);
    defer allocator.free(allow);
    
    try std.testing.expectEqualStrings("GET, POST, PUT", allow);
}