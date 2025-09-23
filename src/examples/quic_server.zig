const std = @import("std");
const QuicServer = @import("server").QuicServer;
const ServerConfig = @import("config").ServerConfig;
const http = @import("http");
const handlers = @import("handlers");
const routing = @import("routing");
const routing_gen = @import("routing_gen");
const connection = @import("connection");
const server_logging = @import("server").server_logging;
const args = @import("args");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize runtime logging from environment variables
    server_logging.initRuntime();

    // Parse command-line arguments
    const ServerArgs = struct {
        port: u16 = 4433,
        cert: []const u8 = "third_party/quiche/quiche/examples/cert.crt",
        key: []const u8 = "third_party/quiche/quiche/examples/cert.key",
        no_qlog: bool = false,
        files_dir: []const u8 = ".",

        pub const descriptions = .{
            .port = "Port to listen on for QUIC connections",
            .cert = "Path to TLS certificate file",
            .key = "Path to TLS private key file",
            .no_qlog = "Disable qlog output",
            .files_dir = "Base directory for serving files via /download/*",
        };
    };

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parser = args.Parser(ServerArgs);
    const parsed = try parser.parse(allocator, argv);

    // Set the global files directory for handlers
    handlers.g_files_dir = parsed.files_dir;

    const config = ServerConfig{
        .bind_port = parsed.port,
        .bind_addr = "127.0.0.1",
        .cert_path = parsed.cert,
        .key_path = parsed.key,
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .enable_pacing = true,
        .cc_algorithm = "bbr2",
        .enable_dgram = true,
        .dgram_recv_queue_len = 1024,
        .dgram_send_queue_len = 1024,
        .qlog_dir = if (parsed.no_qlog) null else "qlogs",
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
        routing_gen.STREAM("/slow", .{ .method = .GET, .on_headers = handlers.slowStreamOnHeaders }),
        routing_gen.GET("/stream/1gb", handlers.stream1GBHandler),
        routing_gen.GET("/stream/test", handlers.streamTestHandler),
        routing_gen.GET("/trailers/demo", handlers.trailersDemoHandler),
        routing_gen.STREAM("/upload/stream", .{ .on_headers = handlers.uploadStreamOnHeaders, .on_body_chunk = handlers.uploadStreamOnChunk, .on_body_complete = handlers.uploadStreamOnComplete }),
        routing_gen.STREAM("/upload/echo", .{ .on_headers = handlers.uploadEchoOnHeaders, .on_body_chunk = handlers.uploadEchoOnChunk, .on_body_complete = handlers.uploadEchoOnComplete }),
        routing_gen.ROUTE_OPTS(.GET, "/h3dgram/echo", handlers.h3dgramEchoHandler, .{ .on_h3_dgram = handlers.h3dgramEchoCallback }),
    });
    var router = RouterT{};
    const matcher: routing.Matcher = router.matcher();

    var server = try QuicServer.init(allocator, config, matcher);
    defer server.deinit();

    handlers.registerEventLoop(server.eventLoop());
    handlers.registerServer(server);
    server.onDatagram(datagramEcho, null);

    try server.bind();
    std.debug.print("QUIC server running on 127.0.0.1:{d}\n", .{parsed.port});
    try server.run();
}

fn datagramEcho(server: *QuicServer, conn: *connection.Connection, payload: []const u8, _: ?*anyopaque) http.DatagramError!void {
    server.sendDatagram(conn, payload) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
}
