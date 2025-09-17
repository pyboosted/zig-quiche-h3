const std = @import("std");
const http = @import("http");
const routing = @import("routing");
const enums = std.enums;

pub const Segment = union(enum) {
    Literal: []const u8,
    Param: []const u8,
    Wildcard,
};

pub const LiteralEntry = struct {
    path: []const u8,
    method: http.Method,
    route: routing.FoundRoute,
};

pub const PatternEntry = struct {
    off: usize,
    len: usize,
    method: http.Method,
    route: routing.FoundRoute,
};

pub fn isStaticPath(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, ':') == null and std.mem.indexOfScalar(u8, path, '*') == null;
}

fn nextSeg(path: []const u8, idx: *usize) ?[]const u8 {
    var i = idx.*;
    while (i < path.len and path[i] == '/') : (i += 1) {}
    if (i >= path.len) {
        idx.* = i;
        return null;
    }
    const start = i;
    while (i < path.len and path[i] != '/') : (i += 1) {}
    const seg = path[start..i];
    idx.* = i;
    return seg;
}

pub fn countSegments(path: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (nextSeg(path, &idx)) |_| count += 1;
    return count;
}

pub fn writeSegments(path: []const u8, out: []Segment, offset: usize) usize {
    var off = offset;
    var idx: usize = 0;
    while (nextSeg(path, &idx)) |seg| {
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

pub fn matchSegments(
    segments: []const Segment,
    path: []const u8,
    scratch: []routing.ParamSpan,
    span_count: *usize,
) bool {
    var idx: usize = 0;
    var si: usize = 0;
    span_count.* = 0;

    while (si < segments.len) {
        switch (segments[si]) {
            .Literal => |lit| {
                const seg_path = nextSeg(path, &idx) orelse return false;
                if (!std.mem.eql(u8, lit, seg_path)) return false;
            },
            .Param => |name| {
                const seg_path = nextSeg(path, &idx) orelse return false;
                if (span_count.* >= scratch.len) return false;
                scratch[span_count.*] = routing.ParamSpan{ .name = name, .value = seg_path };
                span_count.* += 1;
            },
            .Wildcard => {
                var start = idx;
                if (start < path.len and path[start] == '/') start += 1;
                if (span_count.* < scratch.len) {
                    scratch[span_count.*] = routing.ParamSpan{ .name = "*", .value = path[start..] };
                    span_count.* += 1;
                }
                return true;
            },
        }
        si += 1;
    }

    var tmp = idx;
    return nextSeg(path, &tmp) == null;
}

pub fn matchPath(
    literals: []const LiteralEntry,
    patterns: []const PatternEntry,
    segments: []const Segment,
    method: http.Method,
    path: []const u8,
    scratch: []routing.ParamSpan,
    out: *routing.MatchResult,
) bool {
    var lit_allowed = enums.EnumSet(http.Method){};
    for (literals, 0..) |e, i| {
        if (std.mem.eql(u8, e.path, path)) {
            if (e.method == method) {
                out.* = .{ .Found = .{ .route = &literals[i].route, .params = &.{} } };
                return true;
            }
            if (method == .HEAD and e.method == .GET) {
                out.* = .{ .Found = .{ .route = &literals[i].route, .params = &.{} } };
                return true;
            }
            lit_allowed.insert(e.method);
        }
    }
    if (lit_allowed.count() > 0) {
        out.* = .{ .PathMatched = .{ .allowed = lit_allowed } };
        return true;
    }

    var allowed = enums.EnumSet(http.Method){};
    for (patterns, 0..) |e, i| {
        if (e.off + e.len > segments.len) continue;
        var span_count: usize = 0;
        if (matchSegments(segments[e.off .. e.off + e.len], path, scratch, &span_count)) {
            allowed.insert(e.method);
            if (e.method == method or (method == .HEAD and e.method == .GET)) {
                out.* = .{ .Found = .{ .route = &patterns[i].route, .params = scratch[0..span_count] } };
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
