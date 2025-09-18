const M = @import("client/mod.zig");

pub const QuicClient = M.QuicClient;
pub const ClientError = M.ClientError;
pub const ClientConfig = M.ClientConfig;
pub const ServerEndpoint = M.ServerEndpoint;
pub const FetchHandle = M.FetchHandle;
pub const FetchResponse = M.FetchResponse;
pub const FetchOptions = M.FetchOptions;
pub const HeaderPair = M.HeaderPair;
pub const ResponseEvent = M.ResponseEvent;
pub const DatagramEvent = M.DatagramEvent;
pub const ResponseCallback = M.ResponseCallback;
pub const RequestBodyProvider = M.RequestBodyProvider;
pub const BodyChunkResult = M.BodyChunkResult;

// Export the helpers module for convenience
pub const helpers = @import("client/helpers.zig");

// Export the connection pool
pub const ConnectionPool = @import("client/pool.zig").ConnectionPool;
