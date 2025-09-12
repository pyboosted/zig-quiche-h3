const std = @import("std");

/// QUIC variable-length integer encoding/decoding for H3 DATAGRAM flow_id
/// Per RFC 9000 Section 16: Variable-Length Integer Encoding
/// Calculate the number of bytes needed to encode a varint
pub fn varintLen(value: u64) usize {
    if (value <= 63) return 1;
    if (value <= 16383) return 2;
    if (value <= 1073741823) return 4;
    return 8;
}

/// Encode a varint into the provided buffer
/// Returns the number of bytes written
pub fn encodeVarint(out: []u8, value: u64) !usize {
    if (value <= 63) {
        if (out.len < 1) return error.BufferTooShort;
        out[0] = @intCast(value);
        return 1;
    } else if (value <= 16383) {
        if (out.len < 2) return error.BufferTooShort;
        const v = value | (0b01 << 14);
        out[0] = @intCast((v >> 8) & 0xff);
        out[1] = @intCast(v & 0xff);
        return 2;
    } else if (value <= 1073741823) {
        if (out.len < 4) return error.BufferTooShort;
        const v = value | (0b10 << 30);
        out[0] = @intCast((v >> 24) & 0xff);
        out[1] = @intCast((v >> 16) & 0xff);
        out[2] = @intCast((v >> 8) & 0xff);
        out[3] = @intCast(v & 0xff);
        return 4;
    } else {
        if (out.len < 8) return error.BufferTooShort;
        const v = value | (0b11 << 62);
        out[0] = @intCast((v >> 56) & 0xff);
        out[1] = @intCast((v >> 48) & 0xff);
        out[2] = @intCast((v >> 40) & 0xff);
        out[3] = @intCast((v >> 32) & 0xff);
        out[4] = @intCast((v >> 24) & 0xff);
        out[5] = @intCast((v >> 16) & 0xff);
        out[6] = @intCast((v >> 8) & 0xff);
        out[7] = @intCast(v & 0xff);
        return 8;
    }
}

/// Decode a varint from the provided buffer
/// Returns the decoded value and the number of bytes consumed
pub fn decodeVarint(data: []const u8) !struct { value: u64, consumed: usize } {
    if (data.len == 0) return error.BufferTooShort;

    const first_byte = data[0];
    const prefix = first_byte >> 6;

    switch (prefix) {
        0b00 => {
            // 1-byte encoding
            return .{ .value = first_byte & 0x3f, .consumed = 1 };
        },
        0b01 => {
            // 2-byte encoding
            if (data.len < 2) return error.BufferTooShort;
            const value = (@as(u64, first_byte & 0x3f) << 8) | data[1];
            return .{ .value = value, .consumed = 2 };
        },
        0b10 => {
            // 4-byte encoding
            if (data.len < 4) return error.BufferTooShort;
            const value = (@as(u64, first_byte & 0x3f) << 24) |
                (@as(u64, data[1]) << 16) |
                (@as(u64, data[2]) << 8) |
                @as(u64, data[3]);
            return .{ .value = value, .consumed = 4 };
        },
        0b11 => {
            // 8-byte encoding
            if (data.len < 8) return error.BufferTooShort;
            const value = (@as(u64, first_byte & 0x3f) << 56) |
                (@as(u64, data[1]) << 48) |
                (@as(u64, data[2]) << 40) |
                (@as(u64, data[3]) << 32) |
                (@as(u64, data[4]) << 24) |
                (@as(u64, data[5]) << 16) |
                (@as(u64, data[6]) << 8) |
                @as(u64, data[7]);
            return .{ .value = value, .consumed = 8 };
        },
        else => unreachable, // prefix can only be 0b00, 0b01, 0b10, or 0b11
    }
}

/// Flow ID mapping functions for H3 DATAGRAM
/// Simple 1:1 mapping: flow_id = stream_id for interop with quiche apps
pub fn flowIdForStream(stream_id: u64) u64 {
    return stream_id;
}

pub fn streamIdForFlow(flow_id: u64) u64 {
    return flow_id;
}

/// Calculate maximum H3 DATAGRAM payload size accounting for varint overhead
pub fn maxH3DgramPayload(max_dgram_size: ?usize, flow_id: u64) ?usize {
    const max_size = max_dgram_size orelse return null;
    const overhead = varintLen(flow_id);
    if (max_size <= overhead) return 0;
    return max_size - overhead;
}

// Tests for the varint implementation
test "varint encoding/decoding" {
    var buf: [8]u8 = undefined;

    // Test small values (1-byte encoding)
    {
        const len = try encodeVarint(&buf, 0);
        try std.testing.expectEqual(@as(usize, 1), len);
        try std.testing.expectEqual(@as(u8, 0), buf[0]);

        const result = try decodeVarint(buf[0..len]);
        try std.testing.expectEqual(@as(u64, 0), result.value);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
    }

    {
        const len = try encodeVarint(&buf, 62);
        try std.testing.expectEqual(@as(usize, 1), len);

        const result = try decodeVarint(buf[0..len]);
        try std.testing.expectEqual(@as(u64, 62), result.value);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
    }

    // Test boundary: 63 is still 1-byte encoding
    {
        const len = try encodeVarint(&buf, 63);
        try std.testing.expectEqual(@as(usize, 1), len);

        const result = try decodeVarint(buf[0..len]);
        try std.testing.expectEqual(@as(u64, 63), result.value);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
    }

    // Test 2-byte encoding starting at 64
    {
        const len = try encodeVarint(&buf, 64);
        try std.testing.expectEqual(@as(usize, 2), len);

        const result = try decodeVarint(buf[0..len]);
        try std.testing.expectEqual(@as(u64, 64), result.value);
        try std.testing.expectEqual(@as(usize, 2), result.consumed);
    }

    // Test boundary: 16383 is still 2-byte encoding
    {
        const len = try encodeVarint(&buf, 16383);
        try std.testing.expectEqual(@as(usize, 2), len);

        const result = try decodeVarint(buf[0..len]);
        try std.testing.expectEqual(@as(u64, 16383), result.value);
        try std.testing.expectEqual(@as(usize, 2), result.consumed);
    }

    // Test 4-byte encoding starting at 16384
    {
        const len = try encodeVarint(&buf, 16384);
        try std.testing.expectEqual(@as(usize, 4), len);

        const result = try decodeVarint(buf[0..len]);
        try std.testing.expectEqual(@as(u64, 16384), result.value);
        try std.testing.expectEqual(@as(usize, 4), result.consumed);
    }

    // Test boundary: 1073741823 is still 4-byte encoding
    {
        const len = try encodeVarint(&buf, 1073741823);
        try std.testing.expectEqual(@as(usize, 4), len);

        const result = try decodeVarint(buf[0..len]);
        try std.testing.expectEqual(@as(u64, 1073741823), result.value);
        try std.testing.expectEqual(@as(usize, 4), result.consumed);
    }

    // Test 8-byte encoding starting at 1073741824
    {
        const len = try encodeVarint(&buf, 1073741824);
        try std.testing.expectEqual(@as(usize, 8), len);

        const result = try decodeVarint(buf[0..len]);
        try std.testing.expectEqual(@as(u64, 1073741824), result.value);
        try std.testing.expectEqual(@as(usize, 8), result.consumed);
    }
}

test "varint length calculation" {
    try std.testing.expectEqual(@as(usize, 1), varintLen(0));
    try std.testing.expectEqual(@as(usize, 1), varintLen(62));
    try std.testing.expectEqual(@as(usize, 1), varintLen(63));
    try std.testing.expectEqual(@as(usize, 2), varintLen(64));
    try std.testing.expectEqual(@as(usize, 2), varintLen(16382));
    try std.testing.expectEqual(@as(usize, 2), varintLen(16383));
    try std.testing.expectEqual(@as(usize, 4), varintLen(16384));
    try std.testing.expectEqual(@as(usize, 4), varintLen(1073741822));
    try std.testing.expectEqual(@as(usize, 4), varintLen(1073741823));
    try std.testing.expectEqual(@as(usize, 8), varintLen(1073741824));
}

test "max payload calculation" {
    // No max size
    try std.testing.expectEqual(@as(?usize, null), maxH3DgramPayload(null, 0));

    // Various flow_id sizes
    try std.testing.expectEqual(@as(?usize, 99), maxH3DgramPayload(100, 0)); // 1-byte flow_id
    try std.testing.expectEqual(@as(?usize, 99), maxH3DgramPayload(100, 63)); // 1-byte flow_id
    try std.testing.expectEqual(@as(?usize, 98), maxH3DgramPayload(100, 64)); // 2-byte flow_id
    try std.testing.expectEqual(@as(?usize, 98), maxH3DgramPayload(100, 16383)); // 2-byte flow_id
    try std.testing.expectEqual(@as(?usize, 96), maxH3DgramPayload(100, 16384)); // 4-byte flow_id
    try std.testing.expectEqual(@as(?usize, 96), maxH3DgramPayload(100, 1073741823)); // 4-byte flow_id
    try std.testing.expectEqual(@as(?usize, 92), maxH3DgramPayload(100, 1073741824)); // 8-byte flow_id

    // Edge case: max size too small
    try std.testing.expectEqual(@as(?usize, 0), maxH3DgramPayload(1, 64)); // 2-byte overhead > 1-byte max
}
