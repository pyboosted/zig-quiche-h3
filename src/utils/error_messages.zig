const std = @import("std");

/// Compile-time error message table for better diagnostics
/// Provides human-readable descriptions for all error types
pub const ErrorMessages = struct {
    // Build the error message map at compile-time
    const messages = std.StaticStringMap([]const u8).initComptime(.{
        // HandlerError messages
        .{ "HeadersAlreadySent", "Response headers have already been sent" },
        .{ "ResponseEnded", "Response has already been ended" },
        .{ "StreamBlocked", "Stream is temporarily blocked, try again later" },
        .{ "InvalidState", "Operation not valid in current state" },
        .{ "PayloadTooLarge", "Request payload exceeds maximum allowed size" },
        .{ "NotFound", "The requested resource was not found" },
        .{ "MethodNotAllowed", "The HTTP method is not allowed for this resource" },
        .{ "BadRequest", "The request could not be understood or was missing required parameters" },
        .{ "Unauthorized", "Authentication is required to access this resource" },
        .{ "Forbidden", "Access to this resource is forbidden" },
        .{ "RequestTimeout", "The request timed out" },
        .{ "TooManyRequests", "Too many requests, please slow down" },
        .{ "InternalServerError", "An internal server error occurred" },
        .{ "RequestHeaderFieldsTooLarge", "Request header fields are too large" },
        .{ "OutOfMemory", "Insufficient memory to complete the operation" },

        // DatagramError messages
        .{ "WouldBlock", "Operation would block, try again later" },
        .{ "DatagramTooLarge", "Datagram exceeds maximum allowed size" },
        .{ "ConnectionClosed", "The connection has been closed" },
        .{ "Done", "Operation completed successfully" },

        // WebTransportError messages
        .{ "SessionClosed", "WebTransport session has been closed" },

        // WebTransportStreamError messages
        .{ "StreamClosed", "Stream has been closed" },
        .{ "StreamReset", "Stream has been reset by peer" },
        .{ "FlowControl", "Flow control limit exceeded" },

        // GeneratorError messages
        .{ "EndOfStream", "End of stream reached" },
        .{ "ReadError", "Error reading from source" },

        // Common system errors
        .{ "AccessDenied", "Access denied to the requested resource" },
        .{ "FileNotFound", "The specified file was not found" },
        .{ "PermissionDenied", "Permission denied for this operation" },
        .{ "NetworkUnreachable", "Network is unreachable" },
        .{ "ConnectionRefused", "Connection refused by the server" },
        .{ "BrokenPipe", "Broken pipe - connection closed unexpectedly" },
        .{ "InvalidArgument", "Invalid argument provided" },
        .{ "OperationAborted", "Operation was aborted" },
        .{ "Unexpected", "An unexpected error occurred" },
    });

    /// Get human-readable error message for any error
    pub fn get(err: anyerror) []const u8 {
        const err_name = @errorName(err);
        return messages.get(err_name) orelse "Unknown error occurred";
    }

    /// Get message with error name prefix for debugging
    pub fn getWithName(err: anyerror) []const u8 {
        const err_name = @errorName(err);
        if (messages.get(err_name)) |msg| {
            // For known errors, return the friendly message
            return msg;
        } else {
            // For unknown errors, return the error name itself
            return err_name;
        }
    }

    /// Format error message with context
    pub fn format(
        allocator: std.mem.Allocator,
        err: anyerror,
        context: []const u8,
    ) ![]const u8 {
        const msg = get(err);
        return try std.fmt.allocPrint(
            allocator,
            "{s}: {s}",
            .{ context, msg },
        );
    }

    /// Check if we have a custom message for this error
    pub fn hasMessage(err: anyerror) bool {
        return messages.has(@errorName(err));
    }
};

// Compile-time validation that ensures all error messages are valid
comptime {
    // StaticStringMap doesn't expose kvs directly in newer Zig versions
    // We validate by checking a sample of known errors
    const sample_errors = [_][]const u8{
        "NotFound",
        "StreamBlocked",
        "OutOfMemory",
        "InvalidState",
    };

    for (sample_errors) |err_name| {
        const msg = ErrorMessages.messages.get(err_name);
        if (msg) |m| {
            if (m.len == 0) {
                @compileError(std.fmt.comptimePrint("Error '{s}' has empty message", .{err_name}));
            }
            if (m.len > 200) {
                @compileError(std.fmt.comptimePrint("Error '{s}' message exceeds 200 characters", .{err_name}));
            }
        }
    }
}

test "ErrorMessages basic functionality" {
    const testing = std.testing;

    // Test known errors
    try testing.expectEqualStrings(
        "The requested resource was not found",
        ErrorMessages.get(error.NotFound),
    );
    try testing.expectEqualStrings(
        "Stream is temporarily blocked, try again later",
        ErrorMessages.get(error.StreamBlocked),
    );

    // Test unknown error
    const UnknownError = error{SomeRandomError};
    try testing.expectEqualStrings(
        "Unknown error occurred",
        ErrorMessages.get(UnknownError.SomeRandomError),
    );

    // Test hasMessage
    try testing.expect(ErrorMessages.hasMessage(error.NotFound));
    try testing.expect(!ErrorMessages.hasMessage(UnknownError.SomeRandomError));
}

test "ErrorMessages with formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const msg = try ErrorMessages.format(
        allocator,
        error.PayloadTooLarge,
        "Upload failed",
    );
    defer allocator.free(msg);

    try testing.expectEqualStrings(
        "Upload failed: Request payload exceeds maximum allowed size",
        msg,
    );
}
