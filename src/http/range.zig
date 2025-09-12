const std = @import("std");

/// Parsed byte range specification (inclusive bounds)
pub const RangeSpec = struct {
    start: u64, // Inclusive start offset
    end: u64, // Inclusive end offset
};

/// Range parsing errors with distinct types for policy decisions
pub const RangeError = error{
    MultiRange, // Contains comma (multi-range not supported in v1)
    NonBytesUnit, // Unit is not "bytes"
    Malformed, // Syntax error in range specification
    Unsatisfiable, // Range is outside file bounds
};

/// Parse HTTP Range header for single byte ranges
///
/// Supports RFC 7233 formats:
/// - `bytes=start-end` → [start, end] inclusive
/// - `bytes=start-`    → [start, size-1]
/// - `bytes=-suffix`   → last suffix bytes
///
/// Returns normalized inclusive range [start, end] within [0, size-1].
/// Multi-range requests (containing comma) return error.MultiRange.
/// Invalid ranges return typed errors for handler policy decisions.
pub fn parseRange(header: []const u8, size: u64) RangeError!RangeSpec {
    // Empty files cannot have satisfiable ranges
    if (size == 0) {
        return error.Unsatisfiable;
    }

    // Trim whitespace
    const trimmed = std.mem.trim(u8, header, " \t");
    if (trimmed.len == 0) {
        return error.Malformed;
    }

    // Check for multi-range (v1 policy: not supported)
    if (std.mem.indexOf(u8, trimmed, ",") != null) {
        return error.MultiRange;
    }

    // Parse unit (must be "bytes", case-insensitive)
    const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse return error.Malformed;
    const unit = std.mem.trim(u8, trimmed[0..eq_pos], " \t");

    if (!std.ascii.eqlIgnoreCase(unit, "bytes")) {
        return error.NonBytesUnit;
    }

    // Parse range specification
    const range_str = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
    if (range_str.len == 0) {
        return error.Malformed;
    }

    // Find the dash separator
    const dash_pos = std.mem.indexOf(u8, range_str, "-") orelse return error.Malformed;

    const start_str = std.mem.trim(u8, range_str[0..dash_pos], " \t");
    const end_str = std.mem.trim(u8, range_str[dash_pos + 1 ..], " \t");

    // Handle suffix-byte-range-spec: bytes=-suffix
    if (start_str.len == 0) {
        if (end_str.len == 0) {
            return error.Malformed; // bytes=-
        }
        const suffix = std.fmt.parseInt(u64, end_str, 10) catch return error.Malformed;
        if (suffix == 0) {
            return error.Malformed; // bytes=-0 is invalid
        }

        // Return last 'suffix' bytes
        const start = if (suffix >= size) 0 else size - suffix;
        return RangeSpec{
            .start = start,
            .end = size - 1,
        };
    }

    // Parse start position
    const start = std.fmt.parseInt(u64, start_str, 10) catch return error.Malformed;

    // Check if start is beyond file size
    if (start >= size) {
        return error.Unsatisfiable;
    }

    // Handle open-ended range: bytes=start-
    if (end_str.len == 0) {
        return RangeSpec{
            .start = start,
            .end = size - 1,
        };
    }

    // Parse end position
    const end = std.fmt.parseInt(u64, end_str, 10) catch return error.Malformed;

    // Check for invalid range (start > end)
    if (start > end) {
        return error.Unsatisfiable;
    }

    // Clamp end to file size
    return RangeSpec{
        .start = start,
        .end = @min(end, size - 1),
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "parseRange: normal ranges" {
    // bytes=0-0 (first byte)
    {
        const range = try parseRange("bytes=0-0", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 0), range.end);
    }

    // bytes=0-1023 (first 1024 bytes)
    {
        const range = try parseRange("bytes=0-1023", 2048);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 1023), range.end);
    }

    // bytes=500-999 (middle range)
    {
        const range = try parseRange("bytes=500-999", 2000);
        try std.testing.expectEqual(@as(u64, 500), range.start);
        try std.testing.expectEqual(@as(u64, 999), range.end);
    }

    // End beyond file size gets clamped
    {
        const range = try parseRange("bytes=0-999", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 99), range.end);
    }
}

test "parseRange: open-ended ranges" {
    // bytes=1024- (from offset to end)
    {
        const range = try parseRange("bytes=1024-", 2048);
        try std.testing.expectEqual(@as(u64, 1024), range.start);
        try std.testing.expectEqual(@as(u64, 2047), range.end);
    }

    // bytes=0- (entire file)
    {
        const range = try parseRange("bytes=0-", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 99), range.end);
    }

    // Last byte only
    {
        const range = try parseRange("bytes=99-", 100);
        try std.testing.expectEqual(@as(u64, 99), range.start);
        try std.testing.expectEqual(@as(u64, 99), range.end);
    }
}

test "parseRange: suffix ranges" {
    // bytes=-500 (last 500 bytes)
    {
        const range = try parseRange("bytes=-500", 1000);
        try std.testing.expectEqual(@as(u64, 500), range.start);
        try std.testing.expectEqual(@as(u64, 999), range.end);
    }

    // bytes=-1 (last byte only)
    {
        const range = try parseRange("bytes=-1", 100);
        try std.testing.expectEqual(@as(u64, 99), range.start);
        try std.testing.expectEqual(@as(u64, 99), range.end);
    }

    // Suffix larger than file (whole file)
    {
        const range = try parseRange("bytes=-1000", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 99), range.end);
    }
}

test "parseRange: boundary conditions" {
    // Start at last byte
    {
        const range = try parseRange("bytes=99-99", 100);
        try std.testing.expectEqual(@as(u64, 99), range.start);
        try std.testing.expectEqual(@as(u64, 99), range.end);
    }

    // Start at size → unsatisfiable
    {
        const err = parseRange("bytes=100-", 100);
        try std.testing.expectError(error.Unsatisfiable, err);
    }

    // Start beyond size → unsatisfiable
    {
        const err = parseRange("bytes=200-300", 100);
        try std.testing.expectError(error.Unsatisfiable, err);
    }

    // Empty file → always unsatisfiable
    {
        const err = parseRange("bytes=0-0", 0);
        try std.testing.expectError(error.Unsatisfiable, err);
    }
}

test "parseRange: invalid ranges" {
    // Start > end → unsatisfiable
    {
        const err = parseRange("bytes=50-10", 100);
        try std.testing.expectError(error.Unsatisfiable, err);
    }

    // bytes=-0 is invalid
    {
        const err = parseRange("bytes=-0", 100);
        try std.testing.expectError(error.Malformed, err);
    }

    // bytes=- is malformed
    {
        const err = parseRange("bytes=-", 100);
        try std.testing.expectError(error.Malformed, err);
    }
}

test "parseRange: multi-range detection" {
    // Comma indicates multi-range
    {
        const err = parseRange("bytes=0-10,20-30", 100);
        try std.testing.expectError(error.MultiRange, err);
    }

    // Even with spaces
    {
        const err = parseRange("bytes=0-10, 20-30", 100);
        try std.testing.expectError(error.MultiRange, err);
    }
}

test "parseRange: non-bytes units" {
    // items unit not supported
    {
        const err = parseRange("items=0-10", 100);
        try std.testing.expectError(error.NonBytesUnit, err);
    }

    // chunks unit not supported
    {
        const err = parseRange("chunks=0-10", 100);
        try std.testing.expectError(error.NonBytesUnit, err);
    }
}

test "parseRange: malformed syntax" {
    // Missing equals
    {
        const err = parseRange("bytes0-10", 100);
        try std.testing.expectError(error.Malformed, err);
    }

    // Missing dash
    {
        const err = parseRange("bytes=10", 100);
        try std.testing.expectError(error.Malformed, err);
    }

    // Non-numeric start
    {
        const err = parseRange("bytes=abc-10", 100);
        try std.testing.expectError(error.Malformed, err);
    }

    // Non-numeric end
    {
        const err = parseRange("bytes=0-xyz", 100);
        try std.testing.expectError(error.Malformed, err);
    }

    // Empty header
    {
        const err = parseRange("", 100);
        try std.testing.expectError(error.Malformed, err);
    }

    // Just whitespace
    {
        const err = parseRange("  \t  ", 100);
        try std.testing.expectError(error.Malformed, err);
    }
}

test "parseRange: whitespace tolerance" {
    // Leading/trailing whitespace
    {
        const range = try parseRange("  bytes=0-10  ", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 10), range.end);
    }

    // Whitespace around equals
    {
        const range = try parseRange("bytes = 0-10", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 10), range.end);
    }

    // Whitespace in range spec
    {
        const range = try parseRange("bytes= 0 - 10 ", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 10), range.end);
    }
}

test "parseRange: case insensitive unit" {
    // BYTES
    {
        const range = try parseRange("BYTES=0-10", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 10), range.end);
    }

    // Bytes
    {
        const range = try parseRange("Bytes=0-10", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 10), range.end);
    }

    // bYtEs
    {
        const range = try parseRange("bYtEs=0-10", 100);
        try std.testing.expectEqual(@as(u64, 0), range.start);
        try std.testing.expectEqual(@as(u64, 10), range.end);
    }
}
