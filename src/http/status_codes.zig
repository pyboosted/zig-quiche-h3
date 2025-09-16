const std = @import("std");

/// Compile-time generated status code strings for fast lookup
/// Covers all common HTTP status codes (100-599)
pub const StatusStrings = struct {
    // Pre-compute common status strings at compile-time
    // Using smaller ranges to avoid compile-time evaluation limits
    const strings = blk: {
        var result: [600][]const u8 = undefined;

        // Initialize with empty strings
        for (0..600) |i| {
            result[i] = "";
        }

        // Most common status codes (pre-computed manually to avoid loops)
        result[100] = "100";
        result[101] = "101";
        result[200] = "200";
        result[201] = "201";
        result[202] = "202";
        result[204] = "204";
        result[206] = "206";
        result[301] = "301";
        result[302] = "302";
        result[303] = "303";
        result[304] = "304";
        result[307] = "307";
        result[308] = "308";
        result[400] = "400";
        result[401] = "401";
        result[403] = "403";
        result[404] = "404";
        result[405] = "405";
        result[406] = "406";
        result[409] = "409";
        result[410] = "410";
        result[413] = "413";
        result[414] = "414";
        result[415] = "415";
        result[416] = "416";
        result[422] = "422";
        result[429] = "429";
        result[500] = "500";
        result[501] = "501";
        result[502] = "502";
        result[503] = "503";
        result[504] = "504";
        result[505] = "505";

        break :blk result;
    };

    /// Get pre-formatted status code string
    /// Returns empty string for codes outside 100-599 range
    pub fn get(code: u16) []const u8 {
        if (code < strings.len and strings[code].len > 0) {
            return strings[code];
        }
        // For unusual codes, caller needs to handle formatting
        return "";
    }

    /// Get status string with fallback formatting
    pub fn getWithFallback(code: u16, buf: []u8) ![]const u8 {
        if (code < strings.len and strings[code].len > 0) {
            return strings[code];
        }
        // Fallback to runtime formatting for unusual codes
        return try std.fmt.bufPrint(buf, "{d}", .{code});
    }
};

test "StatusStrings lookup" {
    try std.testing.expectEqualStrings("200", StatusStrings.get(200));
    try std.testing.expectEqualStrings("404", StatusStrings.get(404));
    try std.testing.expectEqualStrings("500", StatusStrings.get(500));
    try std.testing.expectEqualStrings("", StatusStrings.get(999)); // Out of range
}