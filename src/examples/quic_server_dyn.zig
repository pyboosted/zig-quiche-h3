const std = @import("std");
const QuicServer = @import("server").QuicServer;
const ServerConfig = @import("config").ServerConfig;
const http = @import("http");
const handlers = @import("handlers");
const routing = @import("routing");
const routing_dyn = @import("routing_dyn");
const connection = @import("connection");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Args: --port, --cert, --key
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

    var builder = routing_dyn.Builder.init(allocator);
    defer builder.deinit();

    var bptr = try builder.get("/", handlers.indexHandler);
    bptr = try bptr.get("/api/users", handlers.listUsersHandler);
    bptr = try bptr.get("/api/users/:id", handlers.getUserHandler);
    bptr = try bptr.post("/api/users", handlers.createUserHandler);
    bptr = try bptr.post("/api/echo", handlers.echoHandler);
    bptr = try bptr.post("/api/users", handlers.createUserHandler);
    bptr = try bptr.get("/files/*", handlers.filesHandler);
    bptr = try bptr.get("/download/*", handlers.downloadHandler);
    bptr = try bptr.get("/slow", handlers.slowHandler);
    bptr = try bptr.get("/stream/1gb", handlers.stream1GBHandler);
    bptr = try bptr.get("/stream/test", handlers.streamTestHandler);
    bptr = try bptr.get("/trailers/demo", handlers.trailersDemoHandler);
    bptr = try bptr.streaming("/upload/stream", .{ 
        .on_headers = handlers.uploadStreamOnHeaders, 
        .on_body_chunk = handlers.uploadStreamOnChunk, 
        .on_body_complete = handlers.uploadStreamOnComplete 
    });
    bptr = try bptr.streaming("/upload/echo", .{ 
        .on_headers = handlers.uploadEchoOnHeaders, 
        .on_body_chunk = handlers.uploadEchoOnChunk, 
        .on_body_complete = handlers.uploadEchoOnComplete 
    });
    _ = try bptr.getWithOpts("/h3dgram/echo", handlers.h3dgramEchoHandler, .{ .on_h3_dgram = handlers.h3dgramEchoCallback });

    var dyn = try builder.build();
    defer dyn.deinit();
    const matcher: routing.Matcher = dyn.intoMatcher();

    const server = try QuicServer.init(allocator, config, matcher);
    defer server.deinit();

    server.onDatagram(datagramEcho, null);

    try server.bind();
    std.debug.print("QUIC dynamic server running on 127.0.0.1:{d}\n", .{port});
    try server.run();
}

fn datagramEcho(server: *QuicServer, conn: *connection.Connection, payload: []const u8, _: ?*anyopaque) http.DatagramError!void {
    server.sendDatagram(conn, payload) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
}
