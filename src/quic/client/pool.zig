const std = @import("std");
const QuicClient = @import("mod.zig").QuicClient;
const ClientConfig = @import("mod.zig").ClientConfig;
const ServerEndpoint = @import("mod.zig").ServerEndpoint;
const ClientError = @import("mod.zig").ClientError;

/// Connection pool for efficient HTTP/3 connection reuse
/// Manages multiple connections per host with automatic cleanup
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.StringHashMap(ConnectionEntry),
    config: ClientConfig,
    max_per_host: usize = 6,
    max_idle_ms: i64 = 30000,
    max_total: usize = 100,
    total_count: usize = 0,

    const Self = @This();

    /// Entry for a single host's connections
    const ConnectionEntry = struct {
        allocator: std.mem.Allocator,
        endpoint: ServerEndpoint,
        clients: std.ArrayList(*QuicClient),
        last_used: std.ArrayList(i64),

        fn init(allocator: std.mem.Allocator, endpoint: ServerEndpoint) ConnectionEntry {
            return .{
                .allocator = allocator,
                .endpoint = endpoint,
                .clients = std.ArrayList(*QuicClient).init(allocator),
                .last_used = std.ArrayList(i64).init(allocator),
            };
        }

        fn deinit(self: *ConnectionEntry) void {
            // Clean up all clients
            for (self.clients.items) |client| {
                client.deinit();
                self.allocator.destroy(client);
            }
            self.clients.deinit();
            self.last_used.deinit();
        }

        /// Find an idle connection or null if none available
        fn findIdle(self: *ConnectionEntry) ?struct { client: *QuicClient, index: usize } {
            for (self.clients.items, 0..) |client, i| {
                if (client.isIdle()) {
                    return .{ .client = client, .index = i };
                }
            }
            return null;
        }

        /// Remove stale connections
        fn removeStale(self: *ConnectionEntry, now: i64, max_idle_ms: i64) usize {
            var removed: usize = 0;
            var i: usize = 0;
            while (i < self.clients.items.len) {
                const idle_time = now - self.last_used.items[i];
                if (idle_time > max_idle_ms) {
                    // Remove stale connection
                    const client = self.clients.swapRemove(i);
                    _ = self.last_used.swapRemove(i);
                    client.deinit();
                    self.allocator.destroy(client);
                    removed += 1;
                    // Don't increment i since we removed an item
                } else {
                    i += 1;
                }
            }
            return removed;
        }
    };

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
    pub fn acquire(self: *Self, endpoint: ServerEndpoint) ClientError!*QuicClient {
        const key = try self.makeKey(endpoint);
        defer self.allocator.free(key);

        const now = std.time.milliTimestamp();

        // Get or create entry for this host
        const gop = try self.connections.getOrPut(try self.allocator.dupe(u8, key));
        if (!gop.found_existing) {
            gop.value_ptr.* = ConnectionEntry.init(self.allocator, endpoint);
        }

        var entry = gop.value_ptr;

        // Clean up stale connections first
        const removed = entry.removeStale(now, self.max_idle_ms);
        self.total_count -= removed;

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
            // Try to free up space by removing oldest idle connection globally
            if (!try self.reclaimOldest()) {
                return ClientError.ConnectionPoolExhausted;
            }
        }

        // Create new connection
        const client = try self.createConnection(endpoint);
        errdefer {
            client.deinit();
            self.allocator.destroy(client);
        }

        try entry.clients.append(client);
        try entry.last_used.append(now);
        self.total_count += 1;

        return client;
    }

    /// Release a connection back to the pool
    /// The connection becomes available for reuse
    pub fn release(self: *Self, client: *QuicClient) void {
        // Mark the connection as available by updating last_used time
        const now = std.time.milliTimestamp();

        // Find the connection in the pool and update its timestamp
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.clients.items, 0..) |c, i| {
                if (c == client) {
                    entry.value_ptr.last_used.items[i] = now;
                    return;
                }
            }
        }
    }

    /// Remove a specific connection from the pool
    /// Use this when a connection encounters an error
    pub fn remove(self: *Self, client: *QuicClient) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.clients.items, 0..) |c, i| {
                if (c == client) {
                    _ = entry.value_ptr.clients.swapRemove(i);
                    _ = entry.value_ptr.last_used.swapRemove(i);
                    client.deinit();
                    self.allocator.destroy(client);
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
            for (entry.value_ptr.clients.items) |client| {
                total_connections += 1;
                if (client.isIdle()) {
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
            self.total_count -= removed;
        }

        return total_removed;
    }

    // Private helper functions

    fn makeKey(self: *Self, endpoint: ServerEndpoint) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ endpoint.host, endpoint.port });
    }

    fn createConnection(self: *Self, endpoint: ServerEndpoint) !*QuicClient {
        const client = try self.allocator.create(QuicClient);
        errdefer self.allocator.destroy(client);

        client.* = try QuicClient.init(self.allocator, self.config);
        errdefer client.deinit();

        try client.connect(endpoint);
        return client;
    }

    fn reclaimOldest(self: *Self) !bool {
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_entry: ?*ConnectionEntry = null;
        var oldest_index: usize = 0;

        // Find the oldest idle connection
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.clients.items, 0..) |client, i| {
                if (client.isIdle() and entry.value_ptr.last_used.items[i] < oldest_time) {
                    oldest_time = entry.value_ptr.last_used.items[i];
                    oldest_entry = entry.value_ptr;
                    oldest_index = i;
                }
            }
        }

        if (oldest_entry) |entry| {
            // Remove the oldest idle connection
            const client = entry.clients.swapRemove(oldest_index);
            _ = entry.last_used.swapRemove(oldest_index);
            client.deinit();
            self.allocator.destroy(client);
            self.total_count -= 1;
            return true;
        }

        return false;
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

    var entry = ConnectionPool.ConnectionEntry.init(allocator, .{
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