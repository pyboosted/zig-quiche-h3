const std = @import("std");
const config_mod = @import("config");
const ServerConfig = config_mod.ServerConfig;

/// Header validation errors
pub const ValidationError = error{
    HeaderCountExceeded,
    HeaderNameTooLong,
    HeaderValueTooLong,
    HeaderNameInvalid,
    HeaderValueInvalid,
    ControlCharacterDetected,
    CRLFInjectionDetected,
};

/// Validates a single header name
/// RFC 7230 Section 3.2: field-name = token
/// token = 1*tchar
/// tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "0-9" / "A-Z" / "^" / "_" / "`" / "a-z" / "|" / "~"
/// HTTP/3 pseudo-headers start with ':' and are allowed
pub fn validateHeaderName(name: []const u8, config: *const ServerConfig) ValidationError!void {
    // Check length
    if (name.len == 0) {
        return ValidationError.HeaderNameInvalid;
    }
    if (name.len > config.max_header_name_length) {
        return ValidationError.HeaderNameTooLong;
    }

    // HTTP/3 pseudo-headers (like :method, :path, :scheme, :authority) are allowed
    const is_pseudo_header = name.len > 0 and name[0] == ':';

    if (is_pseudo_header) {
        // For pseudo-headers, validate the rest of the name (after the ':')
        if (name.len == 1) {
            return ValidationError.HeaderNameInvalid; // Just ':' is invalid
        }
        for (name[1..]) |c| {
            // Pseudo-header names should be lowercase alphanumeric or hyphen
            const is_valid = switch (c) {
                'a'...'z', '0'...'9', '-' => true,
                else => false,
            };
            if (!is_valid) {
                return ValidationError.HeaderNameInvalid;
            }
        }
    } else {
        // Regular header validation
        for (name) |c| {
            // RFC 7230 token characters
            const is_valid = switch (c) {
                '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
                '0'...'9', 'A'...'Z', 'a'...'z' => true,
                else => false,
            };

            if (!is_valid) {
                return ValidationError.HeaderNameInvalid;
            }
        }
    }
}

/// Validates a single header value
/// RFC 7230 Section 3.2: field-value may contain any VCHAR, SP, and HTAB
/// Must not contain CR or LF except in obsolete line folding (which we don't support)
pub fn validateHeaderValue(value: []const u8, config: *const ServerConfig) ValidationError!void {
    // Check length
    if (value.len > config.max_header_value_length) {
        return ValidationError.HeaderValueTooLong;
    }

    // Check for forbidden characters
    for (value) |c| {
        switch (c) {
            // CR and LF are forbidden (prevent HTTP response splitting)
            '\r', '\n' => return ValidationError.CRLFInjectionDetected,
            // NUL is forbidden
            0 => return ValidationError.ControlCharacterDetected,
            // Other control characters (except HTAB, CR, LF which are handled above) are forbidden
            1...8, 11...12, 14...31, 127 => return ValidationError.ControlCharacterDetected,
            // HTAB (9), SP (32), and visible chars (33-126) are allowed
            else => {},
        }
    }
}

/// Validates a set of headers
pub fn validateHeaders(
    headers: []const struct { name: []const u8, value: []const u8 },
    config: *const ServerConfig,
) ValidationError!void {
    // Check header count
    if (headers.len > config.max_header_count) {
        return ValidationError.HeaderCountExceeded;
    }

    // Validate each header
    for (headers) |header| {
        try validateHeaderName(header.name, config);
        try validateHeaderValue(header.value, config);
    }
}

// Tests
test "validateHeaderName accepts valid names" {
    const config = ServerConfig{};

    // Valid header names
    try validateHeaderName("Content-Type", &config);
    try validateHeaderName("X-Custom-Header", &config);
    try validateHeaderName("Accept", &config);
    try validateHeaderName("authorization", &config);
    try validateHeaderName("Cache-Control", &config);

    // HTTP/3 pseudo-headers
    try validateHeaderName(":method", &config);
    try validateHeaderName(":path", &config);
    try validateHeaderName(":scheme", &config);
    try validateHeaderName(":authority", &config);
    try validateHeaderName(":status", &config);
}

test "validateHeaderName rejects invalid names" {
    const config = ServerConfig{};

    // Empty name
    try std.testing.expectError(ValidationError.HeaderNameInvalid, validateHeaderName("", &config));

    // Names with spaces
    try std.testing.expectError(ValidationError.HeaderNameInvalid, validateHeaderName("Content Type", &config));

    // Names with colons in the middle (not pseudo-headers)
    try std.testing.expectError(ValidationError.HeaderNameInvalid, validateHeaderName("Content:Type", &config));

    // Names with control characters
    try std.testing.expectError(ValidationError.HeaderNameInvalid, validateHeaderName("Content\nType", &config));

    // Invalid pseudo-headers
    try std.testing.expectError(ValidationError.HeaderNameInvalid, validateHeaderName(":", &config)); // Just colon
    try std.testing.expectError(ValidationError.HeaderNameInvalid, validateHeaderName(":Method", &config)); // Uppercase in pseudo
    try std.testing.expectError(ValidationError.HeaderNameInvalid, validateHeaderName(":invalid_name", &config)); // Underscore
}

test "validateHeaderName enforces length limits" {
    var config = ServerConfig{};
    config.max_header_name_length = 10;

    // Within limit
    try validateHeaderName("Short", &config);

    // At limit
    try validateHeaderName("ExactlyTen", &config);

    // Exceeds limit
    try std.testing.expectError(ValidationError.HeaderNameTooLong, validateHeaderName("ThisNameIsTooLong", &config));
}

test "validateHeaderValue accepts valid values" {
    const config = ServerConfig{};

    // Valid values
    try validateHeaderValue("text/html; charset=utf-8", &config);
    try validateHeaderValue("gzip, deflate, br", &config);
    try validateHeaderValue("max-age=3600", &config);
    try validateHeaderValue("Bearer abc123xyz", &config);

    // Values with spaces and tabs
    try validateHeaderValue("value with spaces", &config);
    try validateHeaderValue("value\twith\ttabs", &config);
}

test "validateHeaderValue rejects invalid values" {
    const config = ServerConfig{};

    // CR/LF injection attempts
    try std.testing.expectError(ValidationError.CRLFInjectionDetected, validateHeaderValue("value\r\nSet-Cookie: evil=true", &config));
    try std.testing.expectError(ValidationError.CRLFInjectionDetected, validateHeaderValue("value\nSet-Cookie: evil=true", &config));
    try std.testing.expectError(ValidationError.CRLFInjectionDetected, validateHeaderValue("value\rSet-Cookie: evil=true", &config));

    // NUL byte
    try std.testing.expectError(ValidationError.ControlCharacterDetected, validateHeaderValue("value\x00null", &config));

    // Other control characters
    try std.testing.expectError(ValidationError.ControlCharacterDetected, validateHeaderValue("value\x01control", &config));
}

test "validateHeaderValue enforces length limits" {
    var config = ServerConfig{};
    config.max_header_value_length = 20;

    // Within limit
    try validateHeaderValue("Short value", &config);

    // At limit (20 chars)
    try validateHeaderValue("12345678901234567890", &config);

    // Exceeds limit
    try std.testing.expectError(ValidationError.HeaderValueTooLong, validateHeaderValue("This value is definitely too long", &config));
}

test "validateHeaders validates complete header sets" {
    var config = ServerConfig{};
    config.max_header_count = 3;

    // Valid set within count limit
    const valid_headers = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "Content-Type", .value = "text/html" },
        .{ .name = "Content-Length", .value = "1234" },
        .{ .name = "Accept", .value = "*/*" },
    };
    try validateHeaders(&valid_headers, &config);

    // Too many headers
    const too_many = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "Header1", .value = "value1" },
        .{ .name = "Header2", .value = "value2" },
        .{ .name = "Header3", .value = "value3" },
        .{ .name = "Header4", .value = "value4" },
    };
    try std.testing.expectError(ValidationError.HeaderCountExceeded, validateHeaders(&too_many, &config));

    // Invalid header in set
    const invalid_set = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "Valid-Header", .value = "valid" },
        .{ .name = "Bad Header", .value = "spaces in name" }, // Invalid name
    };
    try std.testing.expectError(ValidationError.HeaderNameInvalid, validateHeaders(&invalid_set, &config));
}

test "CR/LF injection prevention" {
    const config = ServerConfig{};

    // Various CR/LF injection attempts that should all be caught
    const injection_attempts = [_][]const u8{
        "innocent\r\nSet-Cookie: session=hijacked",
        "innocent\rSet-Cookie: session=hijacked",
        "innocent\nSet-Cookie: session=hijacked",
        "innocent\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<script>alert('XSS')</script>",
        "value\r\n\r\n", // Double CRLF
        "\r\nmalicious",
        "normal\x0d\x0ainjection", // CR LF as hex
    };

    for (injection_attempts) |attempt| {
        validateHeaderValue(attempt, &config) catch |err| {
            try std.testing.expectEqual(ValidationError.CRLFInjectionDetected, err);
            continue;
        };
        // Should not reach here
        try std.testing.expect(false);
    }
}
