const std = @import("std");
const client = @import("mod.zig");
const QuicClient = client.QuicClient;
const ServerEndpoint = client.ServerEndpoint;

pub const ConnectionEntry = struct {
    allocator: std.mem.Allocator,
    endpoint: ServerEndpoint,
    host_storage: []u8,
    sni_storage: ?[]u8,
    clients: std.ArrayListUnmanaged(*QuicClient),
    last_used: std.ArrayListUnmanaged(i64),

    pub fn init(allocator: std.mem.Allocator, endpoint: ServerEndpoint) !ConnectionEntry {
        const host_copy = try allocator.dupe(u8, endpoint.host);
        errdefer allocator.free(host_copy);

        const sni_copy = if (endpoint.sni) |s| try allocator.dupe(u8, s) else null;
        errdefer if (sni_copy) |s| allocator.free(s);

        return ConnectionEntry{
            .allocator = allocator,
            .endpoint = .{
                .host = host_copy,
                .port = endpoint.port,
                .sni = if (sni_copy) |s| s else null,
            },
            .host_storage = host_copy,
            .sni_storage = sni_copy,
            .clients = .{},
            .last_used = .{},
        };
    }

    pub fn deinit(self: *ConnectionEntry) void {
        for (self.clients.items) |client_ptr| {
            client_ptr.deinit();
            self.allocator.destroy(client_ptr);
        }
        self.clients.deinit(self.allocator);
        self.last_used.deinit(self.allocator);
        self.allocator.free(self.host_storage);
        if (self.sni_storage) |s| self.allocator.free(s);
    }

    pub fn findIdle(self: *ConnectionEntry) ?struct { client: *QuicClient, index: usize } {
        for (self.clients.items, 0..) |client_ptr, i| {
            if (client_ptr.isIdle()) {
                return .{ .client = client_ptr, .index = i };
            }
        }
        return null;
    }

    pub fn removeStale(self: *ConnectionEntry, now: i64, max_idle_ms: i64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const idle_time = now - self.last_used.items[i];
            if (idle_time > max_idle_ms) {
                const client_ptr = self.clients.swapRemove(i);
                _ = self.last_used.swapRemove(i);
                client_ptr.deinit();
                self.allocator.destroy(client_ptr);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }
};
