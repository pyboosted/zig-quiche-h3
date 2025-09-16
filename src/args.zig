const std = @import("std");

/// Generic command-line argument parser using struct-based definitions
/// Provides type-safe parsing with automatic help generation
pub fn Parser(comptime Args: type) type {
    return struct {
        const Self = @This();

        /// Parse command-line arguments into the Args struct
        pub fn parse(_: std.mem.Allocator, argv: []const [:0]const u8) !Args {
            var result = Args{}; // Start with default values
            var i: usize = 1; // Skip program name

            while (i < argv.len) : (i += 1) {
                const arg = argv[i];

                // Check for help flag first
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    printHelp(argv[0]);
                    std.process.exit(0);
                }

                // Check if this is a known flag
                var matched = false;
                inline for (std.meta.fields(Args)) |field| {
                    // Convert underscore to hyphen for CLI conventions
                    var long_name_buf: [256]u8 = undefined;
                    const long_name_formatted = formatFlagName(&long_name_buf, field.name);

                    if (std.mem.eql(u8, arg, long_name_formatted)) {
                        matched = true;

                        if (field.type == bool) {
                            // Boolean flags don't take values
                            @field(result, field.name) = true;
                        } else {
                            // Other types require a value
                            if (i + 1 >= argv.len) {
                                std.debug.print("Error: {s} requires a value\n\n", .{long_name_formatted});
                                printHelp(argv[0]);
                                return error.MissingValue;
                            }
                            i += 1;
                            try parseValue(&@field(result, field.name), argv[i]);
                        }
                        break;
                    }

                    // Check short form if available
                    if (comptime hasShortFlag(field.name)) {
                        const short_flag = comptime getShortFlag(field.name);
                        var short_buf = [_]u8{ '-', short_flag };
                        if (std.mem.eql(u8, arg, &short_buf)) {
                            matched = true;

                            if (field.type == bool) {
                                @field(result, field.name) = true;
                            } else {
                                if (i + 1 >= argv.len) {
                                    std.debug.print("Error: -{c} requires a value\n\n", .{short_flag});
                                    printHelp(argv[0]);
                                    return error.MissingValue;
                                }
                                i += 1;
                                try parseValue(&@field(result, field.name), argv[i]);
                            }
                            break;
                        }
                    }
                }

                if (!matched) {
                    std.debug.print("Error: Unknown argument '{s}'\n\n", .{arg});
                    printHelp(argv[0]);
                    return error.UnknownArgument;
                }
            }

            // Validate required fields if needed
            if (comptime @hasDecl(Args, "validate")) {
                try result.validate();
            }

            return result;
        }

        /// Parse a string value into the appropriate type
        fn parseValue(ptr: anytype, value: []const u8) !void {
            const T = @TypeOf(ptr.*);

            if (T == []const u8) {
                ptr.* = value;
            } else if (T == u16) {
                ptr.* = try std.fmt.parseInt(u16, value, 10);
            } else if (T == u32) {
                ptr.* = try std.fmt.parseInt(u32, value, 10);
            } else if (T == u64) {
                ptr.* = try std.fmt.parseInt(u64, value, 10);
            } else if (T == i32) {
                ptr.* = try std.fmt.parseInt(i32, value, 10);
            } else if (T == i64) {
                ptr.* = try std.fmt.parseInt(i64, value, 10);
            } else if (T == usize) {
                ptr.* = try std.fmt.parseInt(usize, value, 10);
            } else if (T == f32) {
                ptr.* = try std.fmt.parseFloat(f32, value);
            } else if (T == f64) {
                ptr.* = try std.fmt.parseFloat(f64, value);
            } else {
                @compileError("Unsupported argument type: " ++ @typeName(T));
            }
        }

        /// Convert field name to CLI flag format (underscore to hyphen)
        fn formatFlagName(buf: []u8, comptime name: []const u8) []const u8 {
            const prefix = "--";
            const total_len = prefix.len + name.len;
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..total_len], name);

            // Replace underscores with hyphens
            for (buf[prefix.len..total_len]) |*c| {
                if (c.* == '_') c.* = '-';
            }

            return buf[0..total_len];
        }

        /// Check if a field has a short flag defined
        fn hasShortFlag(comptime name: []const u8) bool {
            // Define short flags for common options
            if (std.mem.eql(u8, name, "port")) return true;
            if (std.mem.eql(u8, name, "cert")) return true;
            if (std.mem.eql(u8, name, "key")) return true;
            if (std.mem.eql(u8, name, "help")) return true;
            if (std.mem.eql(u8, name, "verbose")) return true;
            if (std.mem.eql(u8, name, "quiet")) return true;
            return false;
        }

        /// Get the short flag character for a field
        fn getShortFlag(comptime name: []const u8) u8 {
            if (std.mem.eql(u8, name, "port")) return 'p';
            if (std.mem.eql(u8, name, "cert")) return 'c';
            if (std.mem.eql(u8, name, "key")) return 'k';
            if (std.mem.eql(u8, name, "help")) return 'h';
            if (std.mem.eql(u8, name, "verbose")) return 'v';
            if (std.mem.eql(u8, name, "quiet")) return 'q';
            return 0;
        }

        /// Print help message
        pub fn printHelp(program_name: []const u8) void {
            // Extract just the binary name from the path
            const basename = std.fs.path.basename(program_name);

            std.debug.print("Usage: {s} [options]\n\n", .{basename});
            std.debug.print("Options:\n", .{});

            inline for (std.meta.fields(Args)) |field| {
                // Format the flag name
                var flag_buf: [256]u8 = undefined;
                const flag_name = formatFlagName(&flag_buf, field.name);

                // Add short flag if available
                if (comptime hasShortFlag(field.name)) {
                    const short = comptime getShortFlag(field.name);
                    std.debug.print("  -{c}, {s}", .{ short, flag_name });
                } else {
                    std.debug.print("      {s}", .{flag_name});
                }

                // Add padding for alignment
                const has_short = comptime hasShortFlag(field.name);
                const flag_len = flag_name.len + if (has_short) 5 else 0;
                const padding = if (flag_len < 25) 25 - flag_len else 2;
                for (0..padding) |_| std.debug.print(" ", .{});

                // Print description if available
                if (comptime @hasDecl(Args, "descriptions")) {
                    if (@hasField(@TypeOf(Args.descriptions), field.name)) {
                        const desc = @field(Args.descriptions, field.name);
                        std.debug.print("{s}", .{desc});
                    }
                }

                // Show default value for non-boolean fields using default struct values
                if (field.type != bool) {
                    const default_instance = Args{};
                    std.debug.print(" (default: ", .{});
                    if (field.type == []const u8) {
                        std.debug.print("{s}", .{@field(default_instance, field.name)});
                    } else if (field.type == u16 or field.type == u32 or field.type == u64 or field.type == usize) {
                        std.debug.print("{d}", .{@field(default_instance, field.name)});
                    }
                    std.debug.print(")", .{});
                }

                std.debug.print("\n", .{});
            }

            std.debug.print("\n", .{});
        }
    };
}

// Test the argument parser
test "argument parser basic functionality" {
    const testing = std.testing;

    const TestArgs = struct {
        port: u16 = 4433,
        cert: []const u8 = "cert.pem",
        key: []const u8 = "key.pem",
        verbose: bool = false,
        quiet: bool = false,

        pub const descriptions = .{
            .port = "Server port to bind to",
            .cert = "TLS certificate file path",
            .key = "TLS private key file path",
            .verbose = "Enable verbose logging",
            .quiet = "Suppress output",
        };
    };

    // Test with default values
    const argv = [_][:0]const u8{"test"};
    const parser = Parser(TestArgs);
    const args = try parser.parse(testing.allocator, &argv);

    try testing.expectEqual(@as(u16, 4433), args.port);
    try testing.expectEqualStrings("cert.pem", args.cert);
    try testing.expectEqualStrings("key.pem", args.key);
    try testing.expect(!args.verbose);
    try testing.expect(!args.quiet);
}

test "argument parser with values" {
    const testing = std.testing;

    const TestArgs = struct {
        port: u16 = 4433,
        cert: []const u8 = "cert.pem",
        verbose: bool = false,
    };

    // Test with custom values
    const argv = [_][:0]const u8{ "test", "--port", "8080", "--cert", "/path/to/cert", "--verbose" };
    const parser = Parser(TestArgs);
    const args = try parser.parse(testing.allocator, &argv);

    try testing.expectEqual(@as(u16, 8080), args.port);
    try testing.expectEqualStrings("/path/to/cert", args.cert);
    try testing.expect(args.verbose);
}

test "argument parser with short flags" {
    const testing = std.testing;

    const TestArgs = struct {
        port: u16 = 4433,
        verbose: bool = false,
    };

    // Test with short flags
    const argv = [_][:0]const u8{ "test", "-p", "9000", "-v" };
    const parser = Parser(TestArgs);
    const args = try parser.parse(testing.allocator, &argv);

    try testing.expectEqual(@as(u16, 9000), args.port);
    try testing.expect(args.verbose);
}

test "argument parser error handling" {
    const testing = std.testing;

    const TestArgs = struct {
        port: u16 = 4433,
    };

    // Test missing value
    const argv = [_][:0]const u8{ "test", "--port" };
    const parser = Parser(TestArgs);
    const result = parser.parse(testing.allocator, &argv);

    try testing.expectError(error.MissingValue, result);
}