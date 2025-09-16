const std = @import("std");

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
        error.StreamBlocked, error.WouldBlock, error.Done => 503,
        error.NotFound => 404,
        error.MethodNotAllowed => 405,
        error.BadRequest => 400,
        error.PayloadTooLarge => 413,
        error.RequestHeaderFieldsTooLarge => 431,
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.RequestTimeout => 408,
        error.TooManyRequests => 429,
        else => 500,
    };
}
