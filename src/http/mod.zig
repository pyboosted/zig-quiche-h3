// HTTP module - exports all HTTP-related types and functions

pub const pattern = @import("pattern.zig");
pub const handler = @import("handler.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const router = @import("router.zig");
pub const json = @import("json.zig");
pub const streaming = @import("streaming.zig");
pub const range = @import("range.zig");

// Re-export commonly used types at the module level
pub const Router = router.Router;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Handler = handler.Handler;
pub const Method = handler.Method;
pub const Status = handler.Status;
pub const Headers = handler.Headers;
pub const MimeTypes = handler.MimeTypes;
pub const Header = request.Header;
pub const MatchResult = router.MatchResult;

// Streaming callback types
pub const OnHeaders = handler.OnHeaders;
pub const OnBodyChunk = handler.OnBodyChunk;
pub const OnBodyComplete = handler.OnBodyComplete;

// Utility functions
pub const errorToStatus = handler.errorToStatus;
