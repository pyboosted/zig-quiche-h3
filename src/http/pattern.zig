const std = @import("std");

pub const SegmentType = enum {
    literal,
    param,
    wildcard,
};

pub const Segment = union(SegmentType) {
    literal: []const u8,
    param: []const u8, // parameter name
    wildcard: void,
};

pub const CompiledPattern = struct {
    segments: []Segment,
    specificity_score: i32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledPattern) void {
        for (self.segments) |*segment| {
            switch (segment.*) {
                .literal => |s| self.allocator.free(s),
                .param => |s| self.allocator.free(s),
                .wildcard => {},
            }
        }
        self.allocator.free(self.segments);
    }
};

/// Compile a route pattern into segments for matching
/// Examples:
///   "/" -> [literal("/")]
///   "/api/users/:id" -> [literal("api"), literal("users"), param("id")]
///   "/files/*" -> [literal("files"), wildcard]
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !CompiledPattern {
    if (pattern.len == 0) return error.EmptyPattern;

    var segments = std.ArrayList(Segment){};
    defer segments.deinit(allocator);

    // Handle root path specially
    if (std.mem.eql(u8, pattern, "/")) {
        const literal = try allocator.dupe(u8, "/");
        try segments.append(allocator, .{ .literal = literal });
    } else {
        // Split by '/' and process each segment
        var iter = std.mem.tokenizeScalar(u8, pattern, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;

            if (segment[0] == ':') {
                // Parameter segment
                if (segment.len == 1) return error.EmptyParameterName;
                const param_name = try allocator.dupe(u8, segment[1..]);
                try segments.append(allocator, .{ .param = param_name });
            } else if (std.mem.eql(u8, segment, "*")) {
                // Wildcard segment (must be last)
                try segments.append(allocator, .wildcard);
                if (iter.next() != null) {
                    return error.WildcardNotAtEnd;
                }
            } else {
                // Literal segment
                const literal = try allocator.dupe(u8, segment);
                try segments.append(allocator, .{ .literal = literal });
            }
        }
    }

    if (segments.items.len == 0) {
        return error.NoSegments;
    }

    // Calculate specificity score for routing priority
    const score = calculateSpecificity(segments.items);

    const owned_segments = try allocator.alloc(Segment, segments.items.len);
    @memcpy(owned_segments, segments.items);

    return CompiledPattern{
        .segments = owned_segments,
        .specificity_score = score,
        .allocator = allocator,
    };
}

/// Calculate specificity score for route priority
/// Higher score = more specific = higher priority
/// Scoring: literal segments count most, then total segments, params reduce score, wildcards reduce most
fn calculateSpecificity(segments: []const Segment) i32 {
    var literal_count: i32 = 0;
    var param_count: i32 = 0;
    var wildcard_count: i32 = 0;

    for (segments) |segment| {
        switch (segment) {
            .literal => literal_count += 1,
            .param => param_count += 1,
            .wildcard => wildcard_count += 1,
        }
    }

    // Score formula: prioritize literals, penalize params and wildcards
    // Each literal: +1000, each param: -10, each wildcard: -100
    // Plus total segments * 10 for length priority
    return literal_count * 1000 - param_count * 10 - wildcard_count * 100 + @as(i32, @intCast(segments.len)) * 10;
}

/// Match a request path against a compiled pattern
/// Returns extracted parameters if successful
pub fn match(
    allocator: std.mem.Allocator,
    pattern: *const CompiledPattern,
    path: []const u8,
    params: *std.StringHashMapUnmanaged([]const u8),
) !bool {
    // Handle root path specially
    if (pattern.segments.len == 1 and pattern.segments[0] == .literal) {
        const literal = pattern.segments[0].literal;
        if (std.mem.eql(u8, literal, "/")) {
            return std.mem.eql(u8, path, "/");
        }
    }

    // Tokenize the path
    var path_segments = std.ArrayList([]const u8){};
    defer path_segments.deinit(allocator);

    if (!std.mem.eql(u8, path, "/")) {
        var iter = std.mem.tokenizeScalar(u8, path, '/');
        while (iter.next()) |segment| {
            try path_segments.append(allocator, segment);
        }
    }

    // Check non-wildcard segments
    var pattern_idx: usize = 0;
    var path_idx: usize = 0;

    while (pattern_idx < pattern.segments.len) : (pattern_idx += 1) {
        const pattern_segment = pattern.segments[pattern_idx];

        switch (pattern_segment) {
            .literal => |expected| {
                if (path_idx >= path_segments.items.len) return false;

                const actual = path_segments.items[path_idx];
                if (!std.mem.eql(u8, expected, actual)) {
                    return false;
                }
                path_idx += 1;
            },
            .param => |name| {
                if (path_idx >= path_segments.items.len) return false;

                const value = path_segments.items[path_idx];
                // Store the parameter value (caller owns the map and its allocator)
                try params.put(allocator, name, value);
                path_idx += 1;
            },
            .wildcard => {
                // Wildcard matches remaining path
                // Join remaining segments with '/'
                if (path_idx < path_segments.items.len) {
                    var wildcard_parts = std.ArrayList(u8){};
                    defer wildcard_parts.deinit(allocator);

                    var first = true;
                    while (path_idx < path_segments.items.len) : (path_idx += 1) {
                        if (!first) try wildcard_parts.append(allocator, '/');
                        try wildcard_parts.appendSlice(allocator, path_segments.items[path_idx]);
                        first = false;
                    }

                    // Store wildcard match as "*" parameter
                    const wildcard_value = try allocator.dupe(u8, wildcard_parts.items);
                    try params.put(allocator, "*", wildcard_value);
                }
                return true; // Wildcard always matches remaining path
            },
        }
    }

    // All pattern segments matched, check if all path segments were consumed
    return path_idx == path_segments.items.len;
}

// Tests
test "pattern compilation" {
    const allocator = std.testing.allocator;

    // Test root path
    {
        var pattern = try compile(allocator, "/");
        defer pattern.deinit();
        try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
        try std.testing.expect(pattern.segments[0] == .literal);
    }

    // Test literal segments
    {
        var pattern = try compile(allocator, "/api/users");
        defer pattern.deinit();
        try std.testing.expectEqual(@as(usize, 2), pattern.segments.len);
        try std.testing.expect(pattern.segments[0] == .literal);
        try std.testing.expectEqualStrings("api", pattern.segments[0].literal);
        try std.testing.expectEqualStrings("users", pattern.segments[1].literal);
    }

    // Test parameter segments
    {
        var pattern = try compile(allocator, "/api/users/:id");
        defer pattern.deinit();
        try std.testing.expectEqual(@as(usize, 3), pattern.segments.len);
        try std.testing.expect(pattern.segments[2] == .param);
        try std.testing.expectEqualStrings("id", pattern.segments[2].param);
    }

    // Test wildcard
    {
        var pattern = try compile(allocator, "/files/*");
        defer pattern.deinit();
        try std.testing.expectEqual(@as(usize, 2), pattern.segments.len);
        try std.testing.expect(pattern.segments[1] == .wildcard);
    }

    // Test wildcard not at end error
    {
        const result = compile(allocator, "/files/*/extra");
        try std.testing.expectError(error.WildcardNotAtEnd, result);
    }
}

test "pattern matching" {
    const allocator = std.testing.allocator;

    // Test exact match
    {
        var pattern = try compile(allocator, "/api/users");
        defer pattern.deinit();

        var params = std.StringHashMapUnmanaged([]const u8){};
        defer params.deinit(allocator);

        const matched = try match(allocator, &pattern, "/api/users", &params);
        try std.testing.expect(matched);
        try std.testing.expectEqual(@as(usize, 0), params.count());
    }

    // Test parameter extraction
    {
        var pattern = try compile(allocator, "/api/users/:id");
        defer pattern.deinit();

        var params = std.StringHashMapUnmanaged([]const u8){};
        defer params.deinit(allocator);
        defer {
            var iter = params.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.value_ptr.*);
            }
        }

        const matched = try match(allocator, &pattern, "/api/users/123", &params);
        try std.testing.expect(matched);
        try std.testing.expectEqual(@as(usize, 1), params.count());
        try std.testing.expectEqualStrings("123", params.get("id").?);
    }

    // Test wildcard matching
    {
        var pattern = try compile(allocator, "/files/*");
        defer pattern.deinit();

        var params = std.StringHashMapUnmanaged([]const u8){};
        defer params.deinit(allocator);
        defer {
            var iter = params.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.value_ptr.*);
            }
        }

        const matched = try match(allocator, &pattern, "/files/path/to/file.txt", &params);
        try std.testing.expect(matched);
        try std.testing.expectEqualStrings("path/to/file.txt", params.get("*").?);
    }
}

test "specificity scoring" {
    const allocator = std.testing.allocator;

    // More specific patterns should have higher scores
    var exact = try compile(allocator, "/api/users/profile");
    defer exact.deinit();

    var with_param = try compile(allocator, "/api/users/:id");
    defer with_param.deinit();

    var with_wildcard = try compile(allocator, "/api/*");
    defer with_wildcard.deinit();

    try std.testing.expect(exact.specificity_score > with_param.specificity_score);
    try std.testing.expect(with_param.specificity_score > with_wildcard.specificity_score);
}
