const std = @import("std");
const client = @import("mod.zig");
const QuicClient = client.QuicClient;
const ClientError = client.ClientError;
const ServerEndpoint = client.ServerEndpoint;

pub fn Helpers(comptime PoolType: type) type {
    return struct {
        const Self = PoolType;

        fn makeKey(self: *Self, endpoint: ServerEndpoint) ![]u8 {
            return std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ endpoint.host, endpoint.port });
        }

        fn createConnection(self: *Self, endpoint: ServerEndpoint) Self.AcquireError!*QuicClient {
            const client_ptr = QuicClient.init(self.allocator, self.config) catch |err| {
                return switch (err) {
                    error.OutOfMemory => ClientError.OutOfMemory,
                    else => err,
                };
            };
            errdefer {
                client_ptr.deinit();
                self.allocator.destroy(client_ptr);
            }

            try client_ptr.connect(endpoint);
            return client_ptr;
        }

        fn reclaimOldest(self: *Self) !bool {
            var oldest_time: i64 = std.math.maxInt(i64);
            var oldest_entry: ?*Self.ConnectionEntry = null;
            var oldest_index: usize = 0;

            var iter = self.connections.iterator();
            while (iter.next()) |entry| {
                for (entry.value_ptr.clients.items, 0..) |client_ptr, i| {
                    if (client_ptr.isIdle() and entry.value_ptr.last_used.items[i] < oldest_time) {
                        oldest_time = entry.value_ptr.last_used.items[i];
                        oldest_entry = entry.value_ptr;
                        oldest_index = i;
                    }
                }
            }

            if (oldest_entry) |entry| {
                const client_ptr = entry.clients.swapRemove(oldest_index);
                _ = entry.last_used.swapRemove(oldest_index);
                client_ptr.deinit();
                self.allocator.destroy(client_ptr);
                if (self.total_count > 0) self.total_count -= 1;
                return true;
            }

            return false;
        }
    };
}
