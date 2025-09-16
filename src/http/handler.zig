const std = @import("std");
const errors = @import("errors");

// Forward declarations for Request and Response types
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// HTTP handler function type
pub const Handler = *const fn (*Request, *Response) errors.HandlerError!void;

/// Streaming callback types for push-mode request body handling
/// These callbacks receive Response pointer for bidirectional streaming
pub const OnHeaders = *const fn (req: *Request, res: *Response) errors.StreamingError!void;
pub const OnBodyChunk = *const fn (req: *Request, res: *Response, chunk: []const u8) errors.StreamingError!void;
pub const OnBodyComplete = *const fn (req: *Request, res: *Response) errors.StreamingError!void;

/// H3 DATAGRAM callback type for request-associated datagrams
/// Receives the request context, response for sending datagrams back, and payload
pub const OnH3Datagram = *const fn (req: *Request, res: *Response, payload: []const u8) errors.DatagramError!void;

/// WebTransport session handler called when a new WebTransport session is established
/// The session pointer is opaque to avoid circular dependencies
pub const OnWebTransportSession = *const fn (req: *Request, sess: *anyopaque) errors.WebTransportError!void;

/// WebTransport datagram handler for session-bound datagrams
/// Called when a datagram is received for an active WebTransport session
pub const OnWebTransportDatagram = *const fn (sess: *anyopaque, payload: []const u8) errors.WebTransportError!void;

/// WebTransport stream callbacks
pub const OnWebTransportUniOpen = *const fn (sess: *anyopaque, stream: *anyopaque) errors.WebTransportStreamError!void;
pub const OnWebTransportBidiOpen = *const fn (sess: *anyopaque, stream: *anyopaque) errors.WebTransportStreamError!void;
pub const OnWebTransportStreamData = *const fn (stream: *anyopaque, data: []const u8, fin: bool) errors.WebTransportStreamError!void;
pub const OnWebTransportStreamClosed = *const fn (stream: *anyopaque) void;

/// HTTP methods
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,
    CONNECT,
    CONNECT_UDP,
    TRACE,

    const MethodLookup = struct {
        const Entry = struct { str: []const u8, method: Method };

        // Build compile-time lookup table sorted by string length then alphabetically
        // This enables fast rejection and efficient lookup
        const methods = blk: {
            const entries = [_]Entry{
                .{ .str = "GET", .method = .GET },
                .{ .str = "PUT", .method = .PUT },
                .{ .str = "HEAD", .method = .HEAD },
                .{ .str = "POST", .method = .POST },
                .{ .str = "PATCH", .method = .PATCH },
                .{ .str = "TRACE", .method = .TRACE },
                .{ .str = "DELETE", .method = .DELETE },
                .{ .str = "OPTIONS", .method = .OPTIONS },
                .{ .str = "CONNECT", .method = .CONNECT },
                .{ .str = "CONNECT-UDP", .method = .CONNECT_UDP },
            };
            break :blk entries;
        };

        // Use a simple perfect hash based on string length and first char
        // This gives us O(1) lookup for all standard HTTP methods
        pub fn lookup(s: []const u8) ?Method {
            // Fast path: check common methods by length and first char
            switch (s.len) {
                3 => {
                    if (s[0] == 'G' and std.mem.eql(u8, s, "GET")) return .GET;
                    if (s[0] == 'P' and std.mem.eql(u8, s, "PUT")) return .PUT;
                },
                4 => {
                    if (s[0] == 'H' and std.mem.eql(u8, s, "HEAD")) return .HEAD;
                    if (s[0] == 'P' and std.mem.eql(u8, s, "POST")) return .POST;
                },
                5 => {
                    if (s[0] == 'P' and std.mem.eql(u8, s, "PATCH")) return .PATCH;
                    if (s[0] == 'T' and std.mem.eql(u8, s, "TRACE")) return .TRACE;
                },
                6 => {
                    if (s[0] == 'D' and std.mem.eql(u8, s, "DELETE")) return .DELETE;
                },
                7 => {
                    if (s[0] == 'O' and std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
                    if (s[0] == 'C' and std.mem.eql(u8, s, "CONNECT")) return .CONNECT;
                },
                11 => {
                    if (s[0] == 'C' and std.mem.eql(u8, s, "CONNECT-UDP")) return .CONNECT_UDP;
                },
                else => {},
            }
            return null;
        }
    };

    pub fn fromString(s: []const u8) ?Method {
        return MethodLookup.lookup(s);
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
            .CONNECT => "CONNECT",
            .CONNECT_UDP => "CONNECT-UDP",
            .TRACE => "TRACE",
        };
    }
};

/// Common HTTP status codes
pub const Status = enum(u16) {
    // 2xx Success
    OK = 200,
    Created = 201,
    Accepted = 202,
    NoContent = 204,
    ResetContent = 205,
    PartialContent = 206,

    // 3xx Redirection
    MovedPermanently = 301,
    Found = 302,
    SeeOther = 303,
    NotModified = 304,
    TemporaryRedirect = 307,
    PermanentRedirect = 308,

    // 4xx Client Error
    BadRequest = 400,
    Unauthorized = 401,
    PaymentRequired = 402,
    Forbidden = 403,
    NotFound = 404,
    MethodNotAllowed = 405,
    NotAcceptable = 406,
    RequestTimeout = 408,
    Conflict = 409,
    Gone = 410,
    LengthRequired = 411,
    PreconditionFailed = 412,
    PayloadTooLarge = 413,
    URITooLong = 414,
    UnsupportedMediaType = 415,
    RangeNotSatisfiable = 416,
    ExpectationFailed = 417,
    ImATeapot = 418,
    MisdirectedRequest = 421,
    UnprocessableEntity = 422,
    TooManyRequests = 429,
    RequestHeaderFieldsTooLarge = 431,

    // 5xx Server Error
    InternalServerError = 500,
    NotImplemented = 501,
    BadGateway = 502,
    ServiceUnavailable = 503,
    GatewayTimeout = 504,
    HTTPVersionNotSupported = 505,

    pub fn toInt(self: Status) u16 {
        return @intFromEnum(self);
    }

    pub fn fromInt(code: u16) Status {
        return @enumFromInt(code);
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .OK => "OK",
            .Created => "Created",
            .Accepted => "Accepted",
            .NoContent => "No Content",
            .ResetContent => "Reset Content",
            .PartialContent => "Partial Content",
            .MovedPermanently => "Moved Permanently",
            .Found => "Found",
            .SeeOther => "See Other",
            .NotModified => "Not Modified",
            .TemporaryRedirect => "Temporary Redirect",
            .PermanentRedirect => "Permanent Redirect",
            .BadRequest => "Bad Request",
            .Unauthorized => "Unauthorized",
            .PaymentRequired => "Payment Required",
            .Forbidden => "Forbidden",
            .NotFound => "Not Found",
            .MethodNotAllowed => "Method Not Allowed",
            .NotAcceptable => "Not Acceptable",
            .RequestTimeout => "Request Timeout",
            .Conflict => "Conflict",
            .Gone => "Gone",
            .LengthRequired => "Length Required",
            .PreconditionFailed => "Precondition Failed",
            .PayloadTooLarge => "Payload Too Large",
            .URITooLong => "URI Too Long",
            .UnsupportedMediaType => "Unsupported Media Type",
            .RangeNotSatisfiable => "Range Not Satisfiable",
            .ExpectationFailed => "Expectation Failed",
            .ImATeapot => "I'm a teapot",
            .MisdirectedRequest => "Misdirected Request",
            .UnprocessableEntity => "Unprocessable Entity",
            .TooManyRequests => "Too Many Requests",
            .RequestHeaderFieldsTooLarge => "Request Header Fields Too Large",
            .InternalServerError => "Internal Server Error",
            .NotImplemented => "Not Implemented",
            .BadGateway => "Bad Gateway",
            .ServiceUnavailable => "Service Unavailable",
            .GatewayTimeout => "Gateway Timeout",
            .HTTPVersionNotSupported => "HTTP Version Not Supported",
        };
    }
};

/// Re-export of the centralized error->status mapper
pub const errorToStatus = errors.errorToStatus;

/// Re-export error unions for downstream convenience
pub const HandlerError = errors.HandlerError;
pub const StreamingError = errors.StreamingError;
pub const DatagramError = errors.DatagramError;
pub const WebTransportError = errors.WebTransportError;
pub const WebTransportStreamError = errors.WebTransportStreamError;
pub const GeneratorError = errors.GeneratorError;

/// Common HTTP headers
pub const Headers = struct {
    pub const ContentType = "content-type";
    pub const ContentLength = "content-length";
    pub const ContentEncoding = "content-encoding";
    pub const Accept = "accept";
    pub const AcceptEncoding = "accept-encoding";
    pub const AcceptLanguage = "accept-language";
    pub const Allow = "allow";
    pub const Authorization = "authorization";
    pub const CacheControl = "cache-control";
    pub const Connection = "connection";
    pub const Cookie = "cookie";
    pub const Date = "date";
    pub const ETag = "etag";
    pub const Expires = "expires";
    pub const Host = "host";
    pub const IfModifiedSince = "if-modified-since";
    pub const IfNoneMatch = "if-none-match";
    pub const LastModified = "last-modified";
    pub const Location = "location";
    pub const Origin = "origin";
    pub const Referer = "referer";
    pub const Server = "server";
    pub const SetCookie = "set-cookie";
    pub const UserAgent = "user-agent";
    pub const Vary = "vary";
    pub const WWWAuthenticate = "www-authenticate";
    pub const Range = "range";
    pub const AcceptRanges = "accept-ranges";
    pub const ContentRange = "content-range";
};

/// Common MIME types
pub const MimeTypes = struct {
    pub const TextPlain = "text/plain";
    pub const TextHtml = "text/html";
    pub const TextCss = "text/css";
    pub const TextJavascript = "text/javascript";
    pub const ApplicationJson = "application/json";
    pub const ApplicationXml = "application/xml";
    pub const ApplicationOctetStream = "application/octet-stream";
    pub const ApplicationFormUrlencoded = "application/x-www-form-urlencoded";
    pub const MultipartFormData = "multipart/form-data";
    pub const ImagePng = "image/png";
    pub const ImageJpeg = "image/jpeg";
    pub const ImageGif = "image/gif";
    pub const ImageSvg = "image/svg+xml";
    pub const ImageWebp = "image/webp";
};
