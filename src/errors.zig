const std = @import("std");
const error_messages = @import("utils").error_messages;

/// Centralized, typed error unions for the public API.
/// These replace anyerror to improve API clarity and compile-time safety.
/// Errors that HTTP request handlers are allowed to return.
pub const HandlerError = error{
    // Response writing/state errors
    HeadersAlreadySent,
    ResponseEnded,
    StreamBlocked,
    InvalidState,

    // HTTP-specific errors
    PayloadTooLarge,
    NotFound,
    MethodNotAllowed,
    BadRequest,
    Unauthorized,
    Forbidden,
    RequestTimeout,
    TooManyRequests,
    InternalServerError,
    RequestHeaderFieldsTooLarge,

    // Range-specific errors
    RangeNotSatisfiable,
    InvalidRange,
    Unsatisfiable,
    Malformed,
    MultiRange,
    NonBytesUnit,

    // Redirect errors
    InvalidRedirectStatus,

    // Resource errors
    OutOfMemory,
};

/// Errors for streaming callbacks.
pub const StreamingError = error{
    StreamBlocked,
    ResponseEnded,
    HeadersAlreadySent,
    InvalidState,
    PayloadTooLarge,
    OutOfMemory,
};

/// Errors for QUIC/H3 DATAGRAM handlers.
pub const DatagramError = error{
    WouldBlock,
    DatagramTooLarge,
    ConnectionClosed,
    Done,
    OutOfMemory,
};

/// Errors for WebTransport session-level callbacks.
pub const WebTransportError = error{
    SessionClosed,
    StreamBlocked,
    InvalidState,
    WouldBlock,
    OutOfMemory,
};

/// Errors for WebTransport stream callbacks (uni/bidi, data).
pub const WebTransportStreamError = error{
    StreamClosed,
    StreamReset,
    FlowControl,
    WouldBlock,
    InvalidState,
    OutOfMemory,
};

/// Errors for generator-based streaming sources.
pub const GeneratorError = error{
    EndOfStream,
    ReadError,
    OutOfMemory,
};

/// Union of API error sets accepted by error-to-status mapping.
pub const HttpAnyError = HandlerError || StreamingError || DatagramError || WebTransportError || WebTransportStreamError || GeneratorError;

/// Map common errors to HTTP status codes.
/// Unknown errors map to 500 Internal Server Error.
pub fn errorToStatus(err: HttpAnyError) u16 {
    return switch (err) {
        // Service availability
        error.StreamBlocked, error.WouldBlock, error.Done => 503,

        // Client errors (4xx)
        error.BadRequest, error.Malformed => 400,
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.NotFound => 404,
        error.MethodNotAllowed => 405,
        error.RequestTimeout => 408,
        error.PayloadTooLarge => 413,
        error.RangeNotSatisfiable, error.InvalidRange, error.Unsatisfiable => 416,
        error.TooManyRequests => 429,
        error.RequestHeaderFieldsTooLarge => 431,

        // Range errors that should be 400 (bad request)
        error.MultiRange, error.NonBytesUnit => 400,

        // Redirect errors
        error.InvalidRedirectStatus => 500,

        // Server errors (5xx) - everything else
        else => 500,
    };
}

/// Get human-readable error message for diagnostics
pub fn getErrorMessage(err: HttpAnyError) []const u8 {
    return error_messages.ErrorMessages.get(err);
}

/// Get error message with context
pub fn formatError(allocator: std.mem.Allocator, err: HttpAnyError, context: []const u8) ![]const u8 {
    return error_messages.ErrorMessages.format(allocator, err, context);
}
