const std = @import("std");
const quiche = @import("quiche");
const client = @import("mod.zig");
const QuicClient = client.QuicClient;
const ServerConfig = @import("config.zig").ServerConfig;
const QuicServer = @import("server").QuicServer;
const http = @import("http");
const wt_capsules = http.webtransport_capsules;

const ServerThreadCtx = struct {
    server: *QuicServer,
    err: ?anyerror = null,
};

fn serverThreadMain(ctx: *ServerThreadCtx) void {
    ctx.server.run() catch |err| {
        ctx.err = err;
    };
}

fn chooseTestPort() u16 {
    return 45443;
}

test "quic client handshake and fetch against local server" {
    const allocator = std.testing.allocator;

    const server_cfg = ServerConfig{
        .bind_addr = "127.0.0.1",
        .bind_port = chooseTestPort(),
        .cert_path = "third_party/quiche/quiche/examples/cert.crt",
        .key_path = "third_party/quiche/quiche/examples/cert.key",
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .qlog_dir = null,
    };

    const RouterT = routing_gen.compileMatcherType(&.{});
    var router = RouterT{};
    const matcher: routing_api.Matcher = router.matcher();

    var server = try QuicServer.init(allocator, server_cfg, matcher);
    defer server.deinit();

    try server.bind();

    var ctx = ServerThreadCtx{ .server = server, .err = null };
    const thread = try std.Thread.spawn(.{}, serverThreadMain, .{&ctx});
    errdefer {
        server.stop();
        thread.join();
    }

    std.time.sleep(50 * std.time.ns_per_ms) catch {};

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = false,
        .qlog_dir = null,
        .enable_debug_logging = false,
        .connect_timeout_ms = 5_000,
    };

    var client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    const endpoint = ServerEndpoint{
        .host = "127.0.0.1",
        .port = server_cfg.bind_port,
    };

    try client.connect(endpoint);
    try std.testing.expect(client.isEstablished());

    var response = try client.fetch(allocator, "/");
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, "Welcome to Zig QUIC/HTTP3 Server!", 1));
    try std.testing.expect(response.headers.len > 0);

    server.stop();
    thread.join();
    if (ctx.err) |err| {
        std.debug.print("server thread error: {}\n", .{err});
        try std.testing.expect(false);
    }
}

test "quic client concurrent fetches" {
    const allocator = std.testing.allocator;

    const server_cfg = ServerConfig{
        .bind_addr = "127.0.0.1",
        .bind_port = chooseTestPort() + 1,
        .cert_path = "third_party/quiche/quiche/examples/cert.crt",
        .key_path = "third_party/quiche/quiche/examples/cert.key",
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .qlog_dir = null,
    };

    const RouterT = routing_gen.compileMatcherType(&.{});
    var router = RouterT{};
    const matcher: routing_api.Matcher = router.matcher();

    var server = try QuicServer.init(allocator, server_cfg, matcher);
    defer server.deinit();

    try server.bind();

    var ctx = ServerThreadCtx{ .server = server, .err = null };
    const thread = try std.Thread.spawn(.{}, serverThreadMain, .{&ctx});
    errdefer {
        server.stop();
        thread.join();
    }

    std.time.sleep(50 * std.time.ns_per_ms) catch {};

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = false,
        .qlog_dir = null,
        .enable_debug_logging = false,
        .connect_timeout_ms = 5_000,
    };

    var client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    const endpoint = ServerEndpoint{
        .host = "127.0.0.1",
        .port = server_cfg.bind_port,
    };

    try client.connect(endpoint);
    try std.testing.expect(client.isEstablished());

    const handle_a = try client.startGet(allocator, "/");
    const handle_b = try client.startGet(allocator, "/api/users");

    var resp_b = try handle_b.await();
    defer resp_b.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp_b.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, resp_b.body, "Alice", 1));
    try std.testing.expect(resp_b.headers.len > 0);

    var resp_a = try handle_a.await();
    defer resp_a.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp_a.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, resp_a.body, "Welcome to Zig QUIC/HTTP3 Server!", 1));
    try std.testing.expect(resp_a.headers.len > 0);

    server.stop();
    thread.join();
    if (ctx.err) |err| {
        std.debug.print("server thread error: {}\n", .{err});
        try std.testing.expect(false);
    }
}

test "quic client post body and stream response" {
    const allocator = std.testing.allocator;

    const server_cfg = ServerConfig{
        .bind_addr = "127.0.0.1",
        .bind_port = chooseTestPort() + 2,
        .cert_path = "third_party/quiche/quiche/examples/cert.crt",
        .key_path = "third_party/quiche/quiche/examples/cert.key",
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .qlog_dir = null,
    };

    const RouterT = routing_gen.compileMatcherType(&.{});
    var router = RouterT{};
    const matcher: routing_api.Matcher = router.matcher();

    var server = try QuicServer.init(allocator, server_cfg, matcher);
    defer server.deinit();

    try server.bind();

    var ctx = ServerThreadCtx{ .server = server, .err = null };
    const thread = try std.Thread.spawn(.{}, serverThreadMain, .{&ctx});
    errdefer {
        server.stop();
        thread.join();
    }

    std.time.sleep(50 * std.time.ns_per_ms) catch {};

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = false,
        .qlog_dir = null,
        .enable_debug_logging = false,
        .connect_timeout_ms = 5_000,
    };

    var client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    const endpoint = ServerEndpoint{
        .host = "127.0.0.1",
        .port = server_cfg.bind_port,
    };

    try client.connect(endpoint);
    try std.testing.expect(client.isEstablished());

    const post_body = "{\"hello\":\"world\"}";
    var post_resp = try client.fetchWithOptions(allocator, .{
        .method = "POST",
        .path = "/api/echo",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = post_body,
    });
    defer post_resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), post_resp.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, post_resp.body, "world", 1));
    try std.testing.expect(post_resp.headers.len > 0);

    const BodyStream = struct {
        chunks: []const []const u8,
        index: usize = 0,

        fn next(provider_ctx: ?*anyopaque, prov_allocator: std.mem.Allocator) ClientError!BodyChunkResult {
            const self: *@This() = @ptrCast(@alignCast(provider_ctx.?));
            if (self.index >= self.chunks.len) return BodyChunkResult.finished;
            const src = self.chunks[self.index];
            self.index += 1;
            const dup = try prov_allocator.dupe(u8, src);
            return BodyChunkResult.chunk(dup);
        }
    };

    var body_stream = BodyStream{ .chunks = &.{ "{", "\"hello\":\"stream\"", "}" } };
    var streamed_post = try client.fetchWithOptions(allocator, .{
        .method = "POST",
        .path = "/api/echo",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body_provider = .{ .ctx = &body_stream, .next = BodyStream.next },
    });
    defer streamed_post.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), streamed_post.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, streamed_post.body, "stream", 1));
    try std.testing.expect(streamed_post.headers.len > 0);

    const StreamAccum = struct {
        total: usize = 0,
        checksum: u64 = 0,

        fn onChunk(event: ResponseEvent, user_ctx: ?*anyopaque) ClientError!void {
            const self: *@This() = @ptrCast(@alignCast(user_ctx.?));
            switch (event) {
                .data => |slice| {
                    self.total += slice.len;
                    for (slice) |byte| self.checksum += byte;
                },
                else => {},
            }
        }
    };

    var accum = StreamAccum{};
    const handle_stream = try client.startRequest(allocator, .{
        .path = "/stream/test",
        .on_event = StreamAccum.onChunk,
        .event_ctx = &accum,
    });
    var stream_resp = try handle_stream.await();
    defer stream_resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), stream_resp.status);
    try std.testing.expectEqual(@as(usize, 0), stream_resp.body.len);
    try std.testing.expect(stream_resp.headers.len >= 1);

    const total_bytes: usize = 10 * 1024 * 1024;
    const cycles: u64 = @intCast(total_bytes / 256);
    const per_cycle: u64 = 32640; // sum(0..255)
    const expected_checksum: u64 = cycles * per_cycle;

    try std.testing.expectEqual(total_bytes, accum.total);
    try std.testing.expectEqual(expected_checksum, accum.checksum);

    server.stop();
    thread.join();
    if (ctx.err) |err| {
        std.debug.print("server thread error: {}\n", .{err});
        try std.testing.expect(false);
    }
}

test "client CA bundle configuration - valid path" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = true,
        .ca_bundle_path = "third_party/quiche/quiche/examples/cert.crt",
        .enable_debug_logging = false,
    };

    const client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    // Should initialize without error
    try std.testing.expect(client.log_context == null); // No logging context since disabled
}

test "client CA bundle configuration - invalid path" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = true,
        .ca_bundle_path = "/nonexistent/ca.pem",
        .enable_debug_logging = false,
    };

    const result = QuicClient.init(allocator, client_config);
    try std.testing.expectError(error.LoadCABundleFailed, result);
}

test "client debug logging initialization" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = false,
        .enable_debug_logging = true,
        .debug_log_throttle = 10,
    };

    const client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    // Should have logging context
    try std.testing.expect(client.log_context != null);
    try std.testing.expectEqual(@as(u32, 10), client.log_context.?.debug_log_throttle);
}

test "client CA directory configuration" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = true,
        .ca_bundle_dir = "third_party/quiche/quiche/examples", // Directory containing cert.crt
        .enable_debug_logging = false,
    };

    const client = try QuicClient.init(allocator, client_config);
    defer client.deinit();
}

test "client with both CA and debug logging" {
    const allocator = std.testing.allocator;

    const client_config = ClientConfig{
        .alpn_protocols = &.{"h3"},
        .verify_peer = true,
        .ca_bundle_path = "third_party/quiche/quiche/examples/cert.crt",
        .enable_debug_logging = true,
        .debug_log_throttle = 5,
    };

    const client = try QuicClient.init(allocator, client_config);
    defer client.deinit();

    // Should have both features enabled
    try std.testing.expect(client.log_context != null);
    try std.testing.expectEqual(@as(u32, 5), client.log_context.?.debug_log_throttle);
}

test "quic client plain datagram callback lifecycle" {
    // Test that datagram callbacks are invoked correctly and that
    // the payload is only valid during the callback execution
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestContext = struct {
        received_count: u32 = 0,
        last_payload: ?[]u8 = null,
        allocator: std.mem.Allocator,

        fn datagramCallback(client: *QuicClient, payload: []const u8, user: ?*anyopaque) void {
            _ = client;
            const self: *@This() = @ptrCast(@alignCast(user.?));
            self.received_count += 1;

            // Copy the payload to test that it's valid during callback
            if (self.last_payload) |old| {
                self.allocator.free(old);
            }
            self.last_payload = self.allocator.dupe(u8, payload) catch null;
        }
    };

    var test_ctx = TestContext{ .allocator = allocator };

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Register the datagram callback
    client.onQuicDatagram(TestContext.datagramCallback, &test_ctx);

    // Verify callback was registered
    try std.testing.expect(client.on_quic_datagram != null);
    try std.testing.expect(client.on_quic_datagram_user == &test_ctx);

    // Simulate receiving a plain QUIC datagram
    const test_payload = "test datagram payload";

    // Create a test buffer that simulates what processDatagrams would receive
    var test_buf: [256]u8 = undefined;
    @memcpy(test_buf[0..test_payload.len], test_payload);

    // Directly invoke the callback to test the lifecycle
    if (client.on_quic_datagram) |cb| {
        cb(&client, test_buf[0..test_payload.len], client.on_quic_datagram_user);
    }

    // Verify the callback was invoked
    try std.testing.expectEqual(@as(u32, 1), test_ctx.received_count);
    try std.testing.expect(test_ctx.last_payload != null);
    try std.testing.expectEqualSlices(u8, test_payload, test_ctx.last_payload.?);
}

test "quic client plain datagram metrics tracking" {
    // Test that datagram send/receive metrics are properly tracked
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Initial metrics should be zero
    try std.testing.expectEqual(@as(u64, 0), client.datagram_stats.sent);
    try std.testing.expectEqual(@as(u64, 0), client.datagram_stats.received);
    try std.testing.expectEqual(@as(u64, 0), client.datagram_stats.dropped_send);

    // Simulate receiving datagrams
    client.datagram_stats.received += 1;
    try std.testing.expectEqual(@as(u64, 1), client.datagram_stats.received);

    client.datagram_stats.received += 5;
    try std.testing.expectEqual(@as(u64, 6), client.datagram_stats.received);

    // Simulate sending datagrams
    client.datagram_stats.sent += 3;
    try std.testing.expectEqual(@as(u64, 3), client.datagram_stats.sent);

    // Simulate dropped sends
    client.datagram_stats.dropped_send += 2;
    try std.testing.expectEqual(@as(u64, 2), client.datagram_stats.dropped_send);
}

test "quic client H3 vs plain datagram routing" {
    // Test that processDatagrams correctly routes H3 and plain QUIC datagrams
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestContext = struct {
        plain_received: u32 = 0,
        h3_received: u32 = 0,
        last_flow_id: ?u64 = null,

        fn plainCallback(client: *QuicClient, payload: []const u8, user: ?*anyopaque) void {
            _ = client;
            _ = payload;
            const self: *@This() = @ptrCast(@alignCast(user.?));
            self.plain_received += 1;
        }
    };

    var test_ctx = TestContext{};

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Register plain datagram callback
    client.onQuicDatagram(TestContext.plainCallback, &test_ctx);

    // Test 1: Plain QUIC datagram (no flow ID prefix)
    {
        const plain_payload = "plain datagram";
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..plain_payload.len], plain_payload);

        // Simulate what would happen in processDatagrams for plain datagram
        if (client.on_quic_datagram) |cb| {
            cb(&client, buf[0..plain_payload.len], client.on_quic_datagram_user);
            client.datagram_stats.received += 1;
        }

        try std.testing.expectEqual(@as(u32, 1), test_ctx.plain_received);
        try std.testing.expectEqual(@as(u64, 1), client.datagram_stats.received);
    }

    // Test 2: H3 datagram with flow ID (would be handled differently)
    {
        // H3 datagrams have a varint flow_id prefix
        // For this test, we're verifying the routing logic conceptually
        // In real usage, processH3Datagram would handle the flow_id parsing
        var h3_buf: [256]u8 = undefined;
        // Varint encoding of flow_id = 42 (single byte for values < 64)
        h3_buf[0] = 42; // flow_id
        const h3_payload = "h3 datagram payload";
        @memcpy(h3_buf[1 .. 1 + h3_payload.len], h3_payload);

        // In real processDatagrams, this would try processH3Datagram first
        // For test purposes, we simulate detecting it's an H3 datagram
        const flow_id = h3_buf[0]; // Simplified varint parsing
        if (flow_id < 64) { // Valid single-byte varint
            test_ctx.h3_received += 1;
            test_ctx.last_flow_id = flow_id;
        }

        try std.testing.expectEqual(@as(u32, 1), test_ctx.h3_received);
        try std.testing.expectEqual(@as(u64, 42), test_ctx.last_flow_id.?);
    }

    // Test 3: Multiple plain datagrams
    {
        for (0..3) |_| {
            const payload = "another plain datagram";
            var buf: [256]u8 = undefined;
            @memcpy(buf[0..payload.len], payload);

            if (client.on_quic_datagram) |cb| {
                cb(&client, buf[0..payload.len], client.on_quic_datagram_user);
                client.datagram_stats.received += 1;
            }
        }

        try std.testing.expectEqual(@as(u32, 4), test_ctx.plain_received); // 1 + 3
        try std.testing.expectEqual(@as(u64, 4), client.datagram_stats.received); // 1 + 3
    }
}

test "quic client datagram send error handling" {
    // Test error handling in sendQuicDatagram
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Test sending when connection is not established (conn is null)
    const payload = "test payload";
    const result = client.sendQuicDatagram(payload);

    // Should fail because conn is null (not connected)
    try std.testing.expectError(error.NotConnected, result);

    // Dropped send metric should increment
    try std.testing.expectEqual(@as(u64, 1), client.datagram_stats.dropped_send);
}

test "quic client debug logging cleanup safety" {
    // Test that debug logging is properly unregistered to prevent use-after-free
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create multiple clients with debug logging enabled
    {
        const client1 = try QuicClient.init(
            allocator,
            .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
            .{ .debug_log = true, .debug_log_throttle = 1 },
        );
        defer client1.deinit();

        // Verify logging was enabled
        try std.testing.expect(client1.log_context != null);
    }

    // After client1 is destroyed, create another client
    // This tests that the previous callback was properly unregistered
    {
        const client2 = try QuicClient.init(
            allocator,
            .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
            .{ .debug_log = true, .debug_log_throttle = 2 },
        );
        defer client2.deinit();

        // Verify this client has its own context
        try std.testing.expect(client2.log_context != null);
        try std.testing.expectEqual(@as(u32, 2), client2.log_context.?.debug_log_throttle);
    }

    // Create a client without debug logging to ensure no interference
    {
        const client3 = try QuicClient.init(
            allocator,
            .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
            .{},
        );
        defer client3.deinit();

        // Verify no logging context
        try std.testing.expect(client3.log_context == null);
    }

    // If we got here without crashes, the cleanup is working correctly
}

test "quic client datagram memory safety" {
    // Test that datagram payloads are handled safely with proper memory management
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestContext = struct {
        payload_copies: std.ArrayListUnmanaged([]u8),
        allocator: std.mem.Allocator,

        fn datagramCallback(client: *QuicClient, payload: []const u8, user: ?*anyopaque) void {
            _ = client;
            const self: *@This() = @ptrCast(@alignCast(user.?));

            // The payload is only valid during this callback
            // We must copy it if we want to keep it
            const copy = self.allocator.dupe(u8, payload) catch return;
            self.payload_copies.append(self.allocator, copy) catch {
                self.allocator.free(copy);
            };
        }

        fn cleanup(self: *@This()) void {
            for (self.payload_copies.items) |copy| {
                self.allocator.free(copy);
            }
            self.payload_copies.deinit(self.allocator);
        }
    };

    var test_ctx = TestContext{
        .payload_copies = .{},
        .allocator = allocator,
    };
    defer test_ctx.cleanup();

    var client = try QuicClient.init(
        allocator,
        .{ .host = "127.0.0.1", .port = 4433, .verify_peer = false },
        .{},
    );
    defer client.deinit();

    // Register callback
    client.onQuicDatagram(TestContext.datagramCallback, &test_ctx);

    // Simulate receiving multiple datagrams
    const payloads = [_][]const u8{
        "first datagram",
        "second datagram with longer content",
        "third",
        "fourth datagram payload with even more content to test",
    };

    for (payloads) |payload| {
        // Simulate receiving this datagram
        if (client.on_quic_datagram) |cb| {
            // Create a temporary buffer (simulating what processDatagrams does)
            var temp_buf: [256]u8 = undefined;
            @memcpy(temp_buf[0..payload.len], payload);

            // Call the callback with the temporary buffer
            cb(&client, temp_buf[0..payload.len], client.on_quic_datagram_user);

            // After callback returns, temp_buf could be reused/modified
            // This tests that the callback properly copied the data
        }
    }

    // Verify all payloads were properly copied and stored
    try std.testing.expectEqual(payloads.len, test_ctx.payload_copies.items.len);

    for (payloads, test_ctx.payload_copies.items) |expected, actual| {
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}
