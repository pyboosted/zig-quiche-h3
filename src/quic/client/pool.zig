const std = @import("std");
const client_mod = @import("mod.zig");
const QuicClient = client_mod.QuicClient;
const ClientConfig = client_mod.ClientConfig;
const ServerEndpoint = client_mod.ServerEndpoint;
const ClientError = client_mod.ClientError;
const PoolEntry = @import("pool_entry.zig").ConnectionEntry;
const PoolHelpers = @import("pool_helpers.zig");

/// Connection pool for efficient HTTP/3 connection reuse
/// Manages multiple connections per host with automatic cleanup
pub const ConnectionPool = struct {
    const init_type = @typeInfo(@TypeOf(QuicClient.init));
    const QuicClientInitError = switch (init_type) {
        .@"fn" => blk: {
            const ret_type = init_type.@"fn".return_type.?;
            const ret_info = @typeInfo(ret_type);
            break :blk switch (ret_info) {
                .error_union => |err_info| err_info.error_set,
                else => @compileError("QuicClient.init must return an error union"),
            };
        },
        else => @compileError("QuicClient.init is not a function"),
    };
    pub const AcquireError = ClientError || QuicClientInitError;
    allocator: std.mem.Allocator,
    connections: std.StringHashMap(ConnectionEntry),
    config: ClientConfig,
    max_per_host: usize = 6,
    max_idle_ms: i64 = 30000,
    max_total: usize = 100,
    total_count: usize = 0,

    const Self = @This();
    const Helpers = PoolHelpers.Helpers(@This());
    pub const ConnectionEntry = PoolEntry;

    /// Initialize a new connection pool
    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) ConnectionPool {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(ConnectionEntry).init(allocator),
            .config = config,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.connections.deinit();
    }

    /// Get or create a connection to the specified endpoint
    /// Returns a borrowed connection that should be released after use
    pub fn acquire(self: *Self, endpoint: ServerEndpoint) AcquireError!*QuicClient {
        const key = try Helpers.makeKey(self, endpoint);
        defer self.allocator.free(key);

        const now = std.time.milliTimestamp();

        var entry: *ConnectionEntry = undefined;

        if (self.connections.getPtr(key)) |existing| {
            entry = existing;
        } else {
            const key_owned = try self.allocator.dupe(u8, key);
            const gop = self.connections.getOrPut(key_owned) catch |err| {
                self.allocator.free(key_owned);
                switch (err) {
                    error.OutOfMemory => return ClientError.OutOfMemory,
                }
            };

            if (gop.found_existing) {
                self.allocator.free(key_owned);
                entry = gop.value_ptr;
            } else {
                gop.value_ptr.* = ConnectionEntry.init(self.allocator, endpoint) catch |err| {
                    switch (err) {
                        error.OutOfMemory => return ClientError.OutOfMemory,
                    }
                };
                entry = gop.value_ptr;
            }
        }

        // Clean up stale connections first
        const removed = entry.removeStale(now, self.max_idle_ms);
        if (removed > self.total_count) {
            self.total_count = 0;
        } else {
            self.total_count -= removed;
        }

        // Try to find an idle connection
        if (entry.findIdle()) |result| {
            entry.last_used.items[result.index] = now;
            return result.client;
        }

        // Check if we can create a new connection
        if (entry.clients.items.len >= self.max_per_host) {
            return ClientError.ConnectionPoolExhausted;
        }

        if (self.total_count >= self.max_total) {
            if (!try Helpers.reclaimOldest(self)) {
                return ClientError.ConnectionPoolExhausted;
            }
        }

        // Create new connection
        const pooled_client = try Helpers.createConnection(self, endpoint);
        errdefer {
            pooled_client.deinit();
            self.allocator.destroy(pooled_client);
        }

        try entry.clients.append(self.allocator, pooled_client);
        try entry.last_used.append(self.allocator, now);
        self.total_count += 1;

        return pooled_client;
    }

    /// Release a connection back to the pool
    /// The connection becomes available for reuse
    pub fn release(self: *Self, pooled_client: *QuicClient) void {
        // Mark the connection as available by updating last_used time
        const now = std.time.milliTimestamp();

        // Find the connection in the pool and update its timestamp
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.clients.items, 0..) |c, i| {
                if (c == pooled_client) {
                    entry.value_ptr.last_used.items[i] = now;
                    return;
                }
            }
        }
    }

    /// Remove a specific connection from the pool
    /// Use this when a connection encounters an error
    pub fn remove(self: *Self, pooled_client: *QuicClient) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.clients.items, 0..) |c, i| {
                if (c == pooled_client) {
                    _ = entry.value_ptr.clients.swapRemove(i);
                    _ = entry.value_ptr.last_used.swapRemove(i);
                    pooled_client.deinit();
                    self.allocator.destroy(pooled_client);
                    self.total_count -= 1;
                    return;
                }
            }
        }
    }

    /// Get statistics about the pool
    pub fn getStats(self: *Self) PoolStats {
        var total_connections: usize = 0;
        var idle_connections: usize = 0;
        var active_connections: usize = 0;

        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.clients.items) |client_ptr| {
                total_connections += 1;
                if (client_ptr.isIdle()) {
                    idle_connections += 1;
                } else {
                    active_connections += 1;
                }
            }
        }

        return .{
            .total_connections = total_connections,
            .idle_connections = idle_connections,
            .active_connections = active_connections,
            .hosts_connected = self.connections.count(),
        };
    }

    /// Clean up idle connections beyond the max idle time
    pub fn cleanup(self: *Self) usize {
        const now = std.time.milliTimestamp();
        var total_removed: usize = 0;

        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            const removed = entry.value_ptr.removeStale(now, self.max_idle_ms);
            total_removed += removed;
            if (removed > self.total_count) {
                self.total_count = 0;
            } else {
                self.total_count -= removed;
            }
        }

        return total_removed;
    }

    // Private helper functions

    fn makeKey(self: *Self, endpoint: ServerEndpoint) ![]u8 {
        return Helpers.makeKey(self, endpoint);
    }

    pub const PoolStats = struct {
        total_connections: usize,
        idle_connections: usize,
        active_connections: usize,
        hosts_connected: usize,
    };
};

// Tests
test "ConnectionPool basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = ConnectionPool.init(allocator, .{});
    defer pool.deinit();

    // Set shorter idle time for testing
    pool.max_idle_ms = 100;

    // Note: This test would need a mock QuicClient for full testing
    // For now, we test the pool structure
    const stats = pool.getStats();
    try testing.expectEqual(@as(usize, 0), stats.total_connections);
}

test "ConnectionEntry stale removal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var entry = try ConnectionPool.ConnectionEntry.init(allocator, .{
        .host = "test",
        .port = 443,
    });
    defer entry.deinit();

    // Would need mock clients to test properly
    const removed = entry.removeStale(1000, 500);
    try testing.expectEqual(@as(usize, 0), removed);
}

test "ConnectionPool key generation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = ConnectionPool.init(allocator, .{});
    defer pool.deinit();

    const endpoint = ServerEndpoint{
        .host = "example.com",
        .port = 8443,
    };

    const key = try pool.makeKey(endpoint);
    defer allocator.free(key);

    try testing.expectEqualStrings("example.com:8443", key);
}
