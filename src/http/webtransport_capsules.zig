const std = @import("std");
const h3 = @import("h3");
const datagram = h3.datagram;

pub const CapsuleError = error{
    BufferTooShort,
    InvalidCapsuleType,
    InvalidLength,
    ReasonTooLong,
    ValueTooLarge,
};

pub const CapsuleType = enum(u64) {
    close_session = 0x2843,
    drain_session = 0x78ae,
    wt_max_streams_bidi = 0x190B4D3F,
    wt_max_streams_uni = 0x190B4D40,
    wt_streams_blocked_bidi = 0x190B4D43,
    wt_streams_blocked_uni = 0x190B4D44,
    wt_max_data = 0x190B4D3D,
    wt_data_blocked = 0x190B4D41,
};

pub const StreamDir = enum { bidi, uni };

pub const MAX_CLOSE_REASON_BYTES: usize = 1024;
pub const MAX_STREAM_COUNT: u64 = 1 << 60; // Section 5.6 limits values to 2^60

pub const Capsule = union(enum) {
    close_session: CloseSession,
    drain_session: void,
    max_streams: MaxStreams,
    streams_blocked: StreamsBlocked,
    max_data: MaxData,
    data_blocked: DataBlocked,

    pub fn capsuleType(self: Capsule) CapsuleType {
        return switch (self) {
            .close_session => .close_session,
            .drain_session => .drain_session,
            .max_streams => |s| switch (s.dir) {
                .bidi => .wt_max_streams_bidi,
                .uni => .wt_max_streams_uni,
            },
            .streams_blocked => |s| switch (s.dir) {
                .bidi => .wt_streams_blocked_bidi,
                .uni => .wt_streams_blocked_uni,
            },
            .max_data => .wt_max_data,
            .data_blocked => .wt_data_blocked,
        };
    }

    fn payloadLen(self: Capsule) usize {
        return switch (self) {
            .close_session => |c| @as(usize, 4) + c.reason.len,
            .drain_session => 0,
            .max_streams => |s| datagram.varintLen(s.maximum),
            .streams_blocked => |s| datagram.varintLen(s.maximum),
            .max_data => |m| datagram.varintLen(m.maximum),
            .data_blocked => |m| datagram.varintLen(m.maximum),
        };
    }

    pub fn encode(self: Capsule, out: []u8) CapsuleError!usize {
        if (out.len < self.maxEncodedLen()) return error.BufferTooShort;

        const payload_len = self.payloadLen();
        var written: usize = 0;

        written += try datagram.encodeVarint(out[written..], @intFromEnum(self.capsuleType()));
        written += try datagram.encodeVarint(out[written..], payload_len);

        switch (self) {
            .close_session => |c| {
                if (c.reason.len > MAX_CLOSE_REASON_BYTES) return error.ReasonTooLong;
                var code_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &code_buf, c.application_error_code, .big);
                std.mem.copyForwards(u8, out[written .. written + 4], &code_buf);
                written += 4;
                std.mem.copyForwards(u8, out[written .. written + c.reason.len], c.reason);
                written += c.reason.len;
            },
            .drain_session => {},
            .max_streams => |s| {
                if (s.maximum > MAX_STREAM_COUNT) return error.ValueTooLarge;
                written += try datagram.encodeVarint(out[written..], s.maximum);
            },
            .streams_blocked => |s| {
                if (s.maximum > MAX_STREAM_COUNT) return error.ValueTooLarge;
                written += try datagram.encodeVarint(out[written..], s.maximum);
            },
            .max_data => |m| {
                written += try datagram.encodeVarint(out[written..], m.maximum);
            },
            .data_blocked => |m| {
                written += try datagram.encodeVarint(out[written..], m.maximum);
            },
        }

        return written;
    }

    pub fn maxEncodedLen(self: Capsule) usize {
        const payload_len = self.payloadLen();
        return payload_len +
            datagram.varintLen(@intFromEnum(self.capsuleType())) +
            datagram.varintLen(payload_len);
    }
};

pub const CloseSession = struct {
    application_error_code: u32,
    reason: []const u8,
};

pub const MaxStreams = struct {
    dir: StreamDir,
    maximum: u64,
};

pub const StreamsBlocked = struct {
    dir: StreamDir,
    maximum: u64,
};

pub const MaxData = struct {
    maximum: u64,
};

pub const DataBlocked = struct {
    maximum: u64,
};

pub fn decode(data: []const u8) CapsuleError!struct { capsule: Capsule, consumed: usize } {
    var offset: usize = 0;
    const type_res = try datagram.decodeVarint(data[offset..]);
    offset += type_res.consumed;
    const len_res = try datagram.decodeVarint(data[offset..]);
    offset += len_res.consumed;
    const payload_len = len_res.value;
    if (payload_len > data.len - offset) return error.InvalidLength;

    const capsule_type = try typeFromValue(type_res.value);
    const payload = data[offset .. offset + payload_len];

    const capsule = switch (capsule_type) {
        .close_session => blk: {
            if (payload_len < 4) return error.InvalidLength;
            const code = std.mem.readInt(u32, payload[0..4], .big);
            const reason = payload[4..];
            if (reason.len > MAX_CLOSE_REASON_BYTES) return error.ReasonTooLong;
            break :blk Capsule{ .close_session = .{ .application_error_code = code, .reason = reason } };
        },
        .drain_session => blk: {
            if (payload_len != 0) return error.InvalidLength;
            break :blk Capsule{ .drain_session = {} };
        },
        .wt_max_streams_bidi => try decodeMaxStreams(payload, .bidi),
        .wt_max_streams_uni => try decodeMaxStreams(payload, .uni),
        .wt_streams_blocked_bidi => try decodeStreamsBlocked(payload, .bidi),
        .wt_streams_blocked_uni => try decodeStreamsBlocked(payload, .uni),
        .wt_max_data => try decodeMaxData(payload),
        .wt_data_blocked => try decodeDataBlocked(payload),
    };

    return .{ .capsule = capsule, .consumed = offset + payload_len };
}

fn decodeMaxStreams(payload: []const u8, dir: StreamDir) CapsuleError!Capsule {
    const value = try decodeSingleVarint(payload);
    if (value > MAX_STREAM_COUNT) return error.ValueTooLarge;
    return Capsule{ .max_streams = .{ .dir = dir, .maximum = value } };
}

fn decodeStreamsBlocked(payload: []const u8, dir: StreamDir) CapsuleError!Capsule {
    const value = try decodeSingleVarint(payload);
    if (value > MAX_STREAM_COUNT) return error.ValueTooLarge;
    return Capsule{ .streams_blocked = .{ .dir = dir, .maximum = value } };
}

fn decodeMaxData(payload: []const u8) CapsuleError!Capsule {
    const value = try decodeSingleVarint(payload);
    return Capsule{ .max_data = .{ .maximum = value } };
}

fn decodeDataBlocked(payload: []const u8) CapsuleError!Capsule {
    const value = try decodeSingleVarint(payload);
    return Capsule{ .data_blocked = .{ .maximum = value } };
}

fn decodeSingleVarint(payload: []const u8) CapsuleError!u64 {
    const res = try datagram.decodeVarint(payload);
    if (res.consumed != payload.len) return error.InvalidLength;
    return res.value;
}

fn typeFromValue(value: u64) CapsuleError!CapsuleType {
    inline for (std.meta.fields(CapsuleType)) |field| {
        const enumerator = @field(CapsuleType, field.name);
        if (@intFromEnum(enumerator) == value) return enumerator;
    }
    return error.InvalidCapsuleType;
}

// Tests
const testing = std.testing;

test "encode/decode close capsule" {
    const reason = "session closed";
    const cap = Capsule{ .close_session = .{ .application_error_code = 0xdeadbeef, .reason = reason } };
    var buf: [128]u8 = undefined;
    const written = try cap.encode(buf[0..]);
    const decoded = try decode(buf[0..written]);
    try testing.expectEqual(@as(u32, 0xdeadbeef), decoded.capsule.close_session.application_error_code);
    try testing.expectEqualSlices(u8, reason, decoded.capsule.close_session.reason);
}

test "encode/decode max streams capsule" {
    const cap = Capsule{ .max_streams = .{ .dir = .uni, .maximum = 7 } };
    var buf: [32]u8 = undefined;
    const written = try cap.encode(buf[0..]);
    const decoded = try decode(buf[0..written]);
    try testing.expectEqual(cap.capsuleType(), decoded.capsule.capsuleType());
    switch (decoded.capsule) {
        .max_streams => |ms| {
            try testing.expectEqual(StreamDir.uni, ms.dir);
            try testing.expectEqual(@as(u64, 7), ms.maximum);
        },
        else => try testing.expect(false),
    }
}

test "decode invalid capsule type" {
    var buf: [8]u8 = undefined;
    var off: usize = 0;
    off += try datagram.encodeVarint(buf[off..], 0x9999);
    off += try datagram.encodeVarint(buf[off..], 0);
    try testing.expectError(error.InvalidCapsuleType, decode(buf[0..off]));
}

test "reason length validation" {
    var big: [MAX_CLOSE_REASON_BYTES + 2]u8 = undefined;
    const cap = Capsule{ .close_session = .{ .application_error_code = 1, .reason = big[0 .. MAX_CLOSE_REASON_BYTES + 1] } };
    var buf: [1500]u8 = undefined;
    try testing.expectError(error.ReasonTooLong, cap.encode(buf[0..]));
}

test "max streams value validation" {
    var buf: [64]u8 = undefined;
    const cap = Capsule{ .max_streams = .{ .dir = .bidi, .maximum = MAX_STREAM_COUNT + 1 } };
    try testing.expectError(error.ValueTooLarge, cap.encode(buf[0..]));
}

test "decode max streams value validation" {
    var buf: [64]u8 = undefined;
    var off: usize = 0;
    off += try datagram.encodeVarint(buf[off..], @intFromEnum(CapsuleType.wt_max_streams_bidi));
    const value_len = datagram.varintLen(MAX_STREAM_COUNT + 1);
    off += try datagram.encodeVarint(buf[off..], value_len);
    off += try datagram.encodeVarint(buf[off..], MAX_STREAM_COUNT + 1);
    try testing.expectError(error.ValueTooLarge, decode(buf[0..off]));
}
