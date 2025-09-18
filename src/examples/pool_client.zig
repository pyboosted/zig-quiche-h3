const std = @import("std");
const client = @import("client");
const args = @import("args");

const QuicClient = client.QuicClient;
const ConnectionPool = client.ConnectionPool;
const ClientConfig = client.ClientConfig;
const ServerEndpoint = client.ServerEndpoint;
const FetchOptions = client.FetchOptions;

const CliArgs = struct {
    host: []const u8 = "localhost",
    port: u16 = 4433,
    paths: []const u8 = "/,/test,/status",
    requests: u32 = 10,
    pooled: bool = false,
};

/// Simple example demonstrating connection pooling for HTTP/3
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parser = args.Parser(CliArgs);
    const parsed_args = try parser.parse(allocator, argv);

    const config = ClientConfig{
        .verify_peer = false, // Don't verify for local testing
        .grease = true,
        .enable_dgram = false,
    };

    const endpoint = ServerEndpoint{
        .host = parsed_args.host,
        .port = parsed_args.port,
    };

    // Parse paths to request
    var paths = std.ArrayList([]const u8){};
    defer paths.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, parsed_args.paths, ',');
    while (it.next()) |path| {
        try paths.append(allocator, path);
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, "/");
    }

    const start_time = std.time.milliTimestamp();

    if (parsed_args.pooled) {
        std.debug.print("=== Using Connection Pool ===\n", .{});
        try runWithPool(allocator, config, endpoint, paths.items, parsed_args.requests);
    } else {
        std.debug.print("=== Without Connection Pool (new connection per request) ===\n", .{});
        try runWithoutPool(allocator, config, endpoint, paths.items, parsed_args.requests);
    }

    const elapsed = std.time.milliTimestamp() - start_time;
    std.debug.print("\nTotal time: {}ms\n", .{elapsed});
}

/// Run requests using connection pooling
fn runWithPool(
    allocator: std.mem.Allocator,
    config: ClientConfig,
    endpoint: ServerEndpoint,
    paths: []const []const u8,
    num_requests: u32,
) !void {
    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    pool.max_per_host = 3; // Limit concurrent connections per host
    pool.max_idle_ms = 10000; // 10 second idle timeout

    std.debug.print("Pool initialized (max {} connections per host)\n", .{pool.max_per_host});

    var completed: u32 = 0;
    var errors: u32 = 0;

    for (0..num_requests) |i| {
        const path = paths[i % paths.len];

        // Acquire connection from pool
        const conn = pool.acquire(endpoint) catch |err| {
            std.debug.print("Request #{}: Failed to acquire connection: {}\n", .{ i + 1, err });
            errors += 1;
            continue;
        };

        // Use the connection
        const response = conn.fetch(.{
            .method = "GET",
            .path = path,
        }) catch |err| {
            std.debug.print("Request #{}: Failed to fetch {s}: {}\n", .{ i + 1, path, err });
            pool.remove(conn); // Remove failed connection
            errors += 1;
            continue;
        };

        std.debug.print("Request #{}: GET {s} -> {} ({} bytes)\n", .{
            i + 1,
            path,
            response.status,
            response.body.len,
        });

        // Clean up response
        var mut_response = response;
        mut_response.deinit(allocator);

        // Release connection back to pool for reuse
        pool.release(conn);
        completed += 1;

        // Print pool stats periodically
        if ((i + 1) % 5 == 0) {
            const stats = pool.getStats();
            std.debug.print("  [Pool stats: {} total, {} idle, {} active]\n", .{
                stats.total_connections,
                stats.idle_connections,
                stats.active_connections,
            });
        }
    }

    const final_stats = pool.getStats();
    std.debug.print("\n=== Pool Summary ===\n", .{});
    std.debug.print("Requests completed: {}/{}\n", .{ completed, num_requests });
    std.debug.print("Errors: {}\n", .{errors});
    std.debug.print("Final pool state:\n", .{});
    std.debug.print("  Total connections created: {}\n", .{final_stats.total_connections});
    std.debug.print("  Idle connections: {}\n", .{final_stats.idle_connections});
    std.debug.print("  Active connections: {}\n", .{final_stats.active_connections});
    std.debug.print("  Hosts connected: {}\n", .{final_stats.hosts_connected});

    // Clean up idle connections
    const cleaned = pool.cleanup();
    if (cleaned > 0) {
        std.debug.print("  Cleaned up {} idle connections\n", .{cleaned});
    }
}

/// Run requests without pooling (new connection for each request)
fn runWithoutPool(
    allocator: std.mem.Allocator,
    config: ClientConfig,
    endpoint: ServerEndpoint,
    paths: []const []const u8,
    num_requests: u32,
) !void {
    var completed: u32 = 0;
    var errors: u32 = 0;

    for (0..num_requests) |i| {
        const path = paths[i % paths.len];

        // Create new connection for each request
        var conn = QuicClient.init(allocator, config) catch |err| {
            std.debug.print("Request #{}: Failed to create client: {}\n", .{ i + 1, err });
            errors += 1;
            continue;
        };
        defer conn.deinit();

        conn.connect(endpoint) catch |err| {
            std.debug.print("Request #{}: Failed to connect: {}\n", .{ i + 1, err });
            errors += 1;
            continue;
        };

        const response = conn.fetch(.{
            .method = "GET",
            .path = path,
        }) catch |err| {
            std.debug.print("Request #{}: Failed to fetch {s}: {}\n", .{ i + 1, path, err });
            errors += 1;
            continue;
        };

        std.debug.print("Request #{}: GET {s} -> {} ({} bytes) [new connection]\n", .{
            i + 1,
            path,
            response.status,
            response.body.len,
        });

        // Clean up response
        var mut_response = response;
        mut_response.deinit(allocator);

        completed += 1;
    }

    std.debug.print("\n=== No Pool Summary ===\n", .{});
    std.debug.print("Requests completed: {}/{}\n", .{ completed, num_requests });
    std.debug.print("Errors: {}\n", .{errors});
    std.debug.print("Created {} new connections (one per request)\n", .{completed});
}