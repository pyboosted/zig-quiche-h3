const std = @import("std");
const testing = std.testing;
const errors = @import("errors");

test "errorToStatus maps client errors correctly" {
    // 400 Bad Request
    try testing.expectEqual(@as(u16, 400), errors.errorToStatus(error.BadRequest));
    try testing.expectEqual(@as(u16, 400), errors.errorToStatus(error.Malformed));
    try testing.expectEqual(@as(u16, 400), errors.errorToStatus(error.MultiRange));
    try testing.expectEqual(@as(u16, 400), errors.errorToStatus(error.NonBytesUnit));

    // 401 Unauthorized
    try testing.expectEqual(@as(u16, 401), errors.errorToStatus(error.Unauthorized));

    // 403 Forbidden
    try testing.expectEqual(@as(u16, 403), errors.errorToStatus(error.Forbidden));

    // 404 Not Found
    try testing.expectEqual(@as(u16, 404), errors.errorToStatus(error.NotFound));

    // 405 Method Not Allowed
    try testing.expectEqual(@as(u16, 405), errors.errorToStatus(error.MethodNotAllowed));

    // 408 Request Timeout
    try testing.expectEqual(@as(u16, 408), errors.errorToStatus(error.RequestTimeout));

    // 413 Payload Too Large
    try testing.expectEqual(@as(u16, 413), errors.errorToStatus(error.PayloadTooLarge));

    // 416 Range Not Satisfiable
    try testing.expectEqual(@as(u16, 416), errors.errorToStatus(error.RangeNotSatisfiable));
    try testing.expectEqual(@as(u16, 416), errors.errorToStatus(error.InvalidRange));
    try testing.expectEqual(@as(u16, 416), errors.errorToStatus(error.Unsatisfiable));

    // 429 Too Many Requests
    try testing.expectEqual(@as(u16, 429), errors.errorToStatus(error.TooManyRequests));

    // 431 Request Header Fields Too Large
    try testing.expectEqual(@as(u16, 431), errors.errorToStatus(error.RequestHeaderFieldsTooLarge));
}

test "errorToStatus maps service availability errors to 503" {
    try testing.expectEqual(@as(u16, 503), errors.errorToStatus(error.StreamBlocked));
    try testing.expectEqual(@as(u16, 503), errors.errorToStatus(error.WouldBlock));
    try testing.expectEqual(@as(u16, 503), errors.errorToStatus(error.Done));
}

test "errorToStatus maps server errors to 500" {
    try testing.expectEqual(@as(u16, 500), errors.errorToStatus(error.InvalidRedirectStatus));
    try testing.expectEqual(@as(u16, 500), errors.errorToStatus(error.InternalServerError));
    try testing.expectEqual(@as(u16, 500), errors.errorToStatus(error.OutOfMemory));

    // Response state errors should also map to 500
    try testing.expectEqual(@as(u16, 500), errors.errorToStatus(error.HeadersAlreadySent));
    try testing.expectEqual(@as(u16, 500), errors.errorToStatus(error.ResponseEnded));
    try testing.expectEqual(@as(u16, 500), errors.errorToStatus(error.InvalidState));
}

test "errorToStatus handles all HandlerError variants" {
    // This test ensures we handle all errors in the HandlerError set
    const handler_errors = [_]errors.HandlerError{
        error.HeadersAlreadySent,
        error.ResponseEnded,
        error.StreamBlocked,
        error.InvalidState,
        error.PayloadTooLarge,
        error.NotFound,
        error.MethodNotAllowed,
        error.BadRequest,
        error.Unauthorized,
        error.Forbidden,
        error.RequestTimeout,
        error.TooManyRequests,
        error.InternalServerError,
        error.RequestHeaderFieldsTooLarge,
        error.RangeNotSatisfiable,
        error.InvalidRange,
        error.Unsatisfiable,
        error.Malformed,
        error.MultiRange,
        error.NonBytesUnit,
        error.InvalidRedirectStatus,
        error.OutOfMemory,
    };

    for (handler_errors) |err| {
        const status = errors.errorToStatus(err);
        // All errors should map to valid HTTP status codes
        try testing.expect(status >= 400 and status < 600);
    }
}

test "errorToStatus handles all StreamingError variants" {
    const streaming_errors = [_]errors.StreamingError{
        error.StreamBlocked,
        error.ResponseEnded,
        error.HeadersAlreadySent,
        error.InvalidState,
        error.PayloadTooLarge,
        error.OutOfMemory,
    };

    for (streaming_errors) |err| {
        const status = errors.errorToStatus(err);
        try testing.expect(status >= 400 and status < 600);
    }
}

test "errorToStatus handles all DatagramError variants" {
    const datagram_errors = [_]errors.DatagramError{
        error.WouldBlock,
        error.DatagramTooLarge,
        error.ConnectionClosed,
        error.Done,
        error.OutOfMemory,
    };

    for (datagram_errors) |err| {
        const status = errors.errorToStatus(err);
        try testing.expect(status >= 400 and status < 600);
    }
}

test "error mapping consistency across error types" {
    // Ensure common errors map to the same status code regardless of which error set they come from

    // StreamBlocked should always be 503
    const stream_blocked_handler: errors.HandlerError = error.StreamBlocked;
    const stream_blocked_streaming: errors.StreamingError = error.StreamBlocked;
    try testing.expectEqual(errors.errorToStatus(stream_blocked_handler), errors.errorToStatus(stream_blocked_streaming));

    // OutOfMemory should always be 500
    const oom_handler: errors.HandlerError = error.OutOfMemory;
    const oom_streaming: errors.StreamingError = error.OutOfMemory;
    const oom_datagram: errors.DatagramError = error.OutOfMemory;
    try testing.expectEqual(errors.errorToStatus(oom_handler), errors.errorToStatus(oom_streaming));
    try testing.expectEqual(errors.errorToStatus(oom_handler), errors.errorToStatus(oom_datagram));

    // PayloadTooLarge should always be 413
    const payload_handler: errors.HandlerError = error.PayloadTooLarge;
    const payload_streaming: errors.StreamingError = error.PayloadTooLarge;
    try testing.expectEqual(errors.errorToStatus(payload_handler), errors.errorToStatus(payload_streaming));
}