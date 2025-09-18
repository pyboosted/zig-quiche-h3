// Utility module - common helpers and tools

pub const auto_hash = @import("auto_hash.zig");
pub const error_messages = @import("error_messages.zig");

// Re-export commonly used utilities
pub const AutoContext = auto_hash.AutoContext;
pub const ErrorMessages = error_messages.ErrorMessages;
