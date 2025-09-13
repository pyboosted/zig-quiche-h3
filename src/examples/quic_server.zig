const std = @import("std");
const QuicServer = @import("server").QuicServer;
const ServerConfig = @import("config").ServerConfig;
const http = @import("http");
const handlers = @import("handlers");
const routing = @import("routing");
const routing_gen = @import("routing_gen");
const connection = @import("connection");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI minimal
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var port: u16 = 4433;
    var cert_path: []const u8 = "third_party/quiche/quiche/examples/cert.crt";
    var key_path: []const u8 = "third_party/quiche/quiche/examples/cert.key";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--cert") and i + 1 < args.len) {
            i += 1;
            cert_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--key") and i + 1 < args.len) {
            i += 1;
            key_path = args[i];
        }
    }

    const config = ServerConfig{
        .bind_port = port,
        .bind_addr = "127.0.0.1",
        .cert_path = cert_path,
        .key_path = key_path,
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .enable_pacing = true,
        .cc_algorithm = "bbr2",
        .enable_dgram = true,
        .dgram_recv_queue_len = 1024,
        .dgram_send_queue_len = 1024,
    };

    // Define routes using generator helpers (comptime) via wrapper type
    const RouterT = routing_gen.compileMatcherType(&[_]routing_gen.RouteDef{
        routing_gen.GET("/", handlers.indexHandler),
        routing_gen.GET("/api/users", handlers.listUsersHandler),
        routing_gen.POST("/api/users", handlers.createUserHandler),
        routing_gen.GET("/api/users/:id", handlers.getUserHandler),
        routing_gen.POST("/api/users", handlers.createUserHandler),
        routing_gen.POST("/api/echo", handlers.echoHandler),
        routing_gen.GET("/files/*", handlers.filesHandler),
        routing_gen.GET("/download/*", handlers.downloadHandler),
        routing_gen.GET("/stream/1gb", handlers.stream1GBHandler),
        routing_gen.GET("/stream/test", handlers.streamTestHandler),
        routing_gen.GET("/trailers/demo", handlers.trailersDemoHandler),
        routing_gen.STREAM("/upload/stream", .{ 
            .on_headers = handlers.uploadStreamOnHeaders, 
            .on_body_chunk = handlers.uploadStreamOnChunk, 
            .on_body_complete = handlers.uploadStreamOnComplete 
        }),
        routing_gen.STREAM("/upload/echo", .{ 
            .on_headers = handlers.uploadEchoOnHeaders, 
            .on_body_chunk = handlers.uploadEchoOnChunk, 
            .on_body_complete = handlers.uploadEchoOnComplete 
        }),
        routing_gen.ROUTE_OPTS(.GET, "/h3dgram/echo", handlers.h3dgramEchoHandler, .{ .on_h3_dgram = handlers.h3dgramEchoCallback }),
    });
    var router = RouterT{};
    const matcher: routing.Matcher = router.matcher();

    var server = try QuicServer.init(allocator, config, matcher);
    defer server.deinit();

    server.onDatagram(datagramEcho, null);

    try server.bind();
    std.debug.print("QUIC server running on 127.0.0.1:{d}\n", .{port});
    try server.run();
}

fn datagramEcho(server: *QuicServer, conn: *connection.Connection, payload: []const u8, _: ?*anyopaque) http.DatagramError!void {
    server.sendDatagram(conn, payload) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
}
