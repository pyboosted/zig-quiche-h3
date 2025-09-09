const std = @import("std");

// Forward declarations for Request and Response types
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// HTTP handler function type
pub const Handler = *const fn (*Request, *Response) anyerror!void;

/// Streaming callback types for push-mode request body handling
/// These callbacks receive Response pointer for bidirectional streaming
pub const OnHeaders = *const fn (req: *Request, res: *Response) anyerror!void;
pub const OnBodyChunk = *const fn (req: *Request, res: *Response, chunk: []const u8) anyerror!void;
pub const OnBodyComplete = *const fn (req: *Request, res: *Response) anyerror!void;

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
    TRACE,
    
    pub fn fromString(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "CONNECT")) return .CONNECT;
        if (std.mem.eql(u8, s, "TRACE")) return .TRACE;
        return null;
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

/// Map common errors to HTTP status codes
pub fn errorToStatus(err: anyerror) u16 {
    return switch (err) {
        error.NotFound => @intFromEnum(Status.NotFound),
        error.MethodNotAllowed => @intFromEnum(Status.MethodNotAllowed),
        error.BadRequest => @intFromEnum(Status.BadRequest),
        error.PayloadTooLarge => @intFromEnum(Status.PayloadTooLarge),
        error.RequestHeaderFieldsTooLarge => @intFromEnum(Status.RequestHeaderFieldsTooLarge),
        error.Unauthorized => @intFromEnum(Status.Unauthorized),
        error.Forbidden => @intFromEnum(Status.Forbidden),
        error.RequestTimeout => @intFromEnum(Status.RequestTimeout),
        error.TooManyRequests => @intFromEnum(Status.TooManyRequests),
        else => @intFromEnum(Status.InternalServerError),
    };
}

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