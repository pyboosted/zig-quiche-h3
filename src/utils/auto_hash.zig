const std = @import("std");

/// Automatically generate a HashMap context for any struct type
/// This eliminates boilerplate for hash and eql functions
pub fn AutoContext(comptime T: type) type {
    return struct {
        pub fn hash(_: @This(), key: T) u64 {
            var h = std.hash.Wyhash.init(0);

            // Hash each field of the struct
            inline for (std.meta.fields(T)) |field| {
                const value = @field(key, field.name);
                const ValueType = @TypeOf(value);

                // Handle different field types appropriately
                switch (@typeInfo(ValueType)) {
                    .pointer => {
                        // For pointers, hash the address
                        h.update(std.mem.asBytes(&value));
                    },
                    .int, .float => {
                        // For numeric types, hash the bytes
                        h.update(std.mem.asBytes(&value));
                    },
                    .array => |array_info| {
                        // For arrays, hash all elements
                        if (array_info.child == u8) {
                            // Byte arrays can be hashed directly
                            h.update(&value);
                        } else {
                            // Other arrays need element-wise hashing
                            h.update(std.mem.asBytes(&value));
                        }
                    },
                    .@"enum" => {
                        // For enums, hash the integer value
                        const int_value = @intFromEnum(value);
                        h.update(std.mem.asBytes(&int_value));
                    },
                    .bool => {
                        // For booleans, hash as u8
                        const byte: u8 = if (value) 1 else 0;
                        h.update(std.mem.asBytes(&byte));
                    },
                    else => {
                        // For other types, try to hash as bytes
                        h.update(std.mem.asBytes(&value));
                    },
                }
            }

            return h.final();
        }

        pub fn eql(_: @This(), a: T, b: T) bool {
            // Compare each field
            inline for (std.meta.fields(T)) |field| {
                const a_value = @field(a, field.name);
                const b_value = @field(b, field.name);

                // Use appropriate comparison based on type
                const ValueType = @TypeOf(a_value);
                switch (@typeInfo(ValueType)) {
                    .pointer => {
                        // For pointers, compare addresses
                        if (a_value != b_value) return false;
                    },
                    .array => {
                        // For arrays, use mem.eql if applicable
                        const array_info = @typeInfo(ValueType).array;
                        if (array_info.child == u8) {
                            if (!std.mem.eql(u8, &a_value, &b_value)) return false;
                        } else {
                            if (!std.mem.eql(array_info.child, &a_value, &b_value)) return false;
                        }
                    },
                    else => {
                        // For other types, use direct comparison
                        if (a_value != b_value) return false;
                    },
                }
            }

            return true;
        }
    };
}

// Test the auto-generated context
test "AutoContext basic functionality" {
    const TestKey = struct {
        id: u64,
        ptr: *const u8,
    };

    const Context = AutoContext(TestKey);
    const ctx = Context{};

    const ptr: u8 = 42;
    const key1 = TestKey{ .id = 123, .ptr = &ptr };
    const key2 = TestKey{ .id = 123, .ptr = &ptr };
    const key3 = TestKey{ .id = 456, .ptr = &ptr };

    // Test equality
    try std.testing.expect(ctx.eql(key1, key2));
    try std.testing.expect(!ctx.eql(key1, key3));

    // Test hashing (same keys should have same hash)
    try std.testing.expectEqual(ctx.hash(key1), ctx.hash(key2));
}

test "AutoContext with complex types" {
    const ComplexKey = struct {
        conn: *const u32,
        stream_id: u64,
        active: bool,
        tag: [4]u8,
    };

    const Context = AutoContext(ComplexKey);
    const ctx = Context{};

    const conn: u32 = 999;
    const key1 = ComplexKey{
        .conn = &conn,
        .stream_id = 42,
        .active = true,
        .tag = .{ 'T', 'E', 'S', 'T' },
    };

    const key2 = ComplexKey{
        .conn = &conn,
        .stream_id = 42,
        .active = true,
        .tag = .{ 'T', 'E', 'S', 'T' },
    };

    try std.testing.expect(ctx.eql(key1, key2));
    try std.testing.expectEqual(ctx.hash(key1), ctx.hash(key2));
}
