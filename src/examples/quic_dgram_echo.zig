const std = @import("std");
const QuicServer = @import("server").QuicServer;
const ServerConfig = @import("config").ServerConfig;
const http = @import("http");
const connection = @import("connection");
const routing = @import("routing");
const routing_gen = @import("routing_gen");
const args = @import("args");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ServerArgs = struct {
        port: u16 = 4433,
        cert: []const u8 = "third_party/quiche/quiche/examples/cert.crt",
        key: []const u8 = "third_party/quiche/quiche/examples/cert.key",

        pub const descriptions = .{
            .port = "Port to listen on for QUIC DATAGRAM echo",
            .cert = "Path to TLS certificate file",
            .key = "Path to TLS private key file",
        };
    };

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parser = args.Parser(ServerArgs);
    const parsed = try parser.parse(allocator, argv);

    const config = ServerConfig{
        .bind_port = parsed.port,
        .bind_addr = "127.0.0.1",
        .cert_path = parsed.cert,
        .key_path = parsed.key,
        .alpn_protocols = &.{"h3"},
        .enable_debug_logging = false,
        .enable_pacing = true,
        .cc_algorithm = "cubic",
        .enable_dgram = true,
        .dgram_recv_queue_len = 1024,
        .dgram_send_queue_len = 1024,
    };

    // Minimal route for readiness
    const routes = [_]routing_gen.RouteDef{
        .{ .pattern = "/", .method = .GET, .handler = indexHandler },
    };
    const Gen = routing_gen.compileRoutes(&routes);
    var gen = Gen.instance();
    const matcher: routing.Matcher = gen.intoMatcher();

    const server = try QuicServer.init(allocator, config, matcher);
    defer server.deinit();

    // Echo any received QUIC DATAGRAM back to the sender
    server.onDatagram(datagramEcho, null);

    try server.bind();
    std.debug.print("QUIC DATAGRAM echo server on 127.0.0.1:{d}\n", .{parsed.port});
    try server.run();
}

fn indexHandler(_: *http.Request, res: *http.Response) http.HandlerError!void {
    res.header(http.Headers.ContentType, http.MimeTypes.TextPlain) catch return error.InternalServerError;
    res.writeAll("ok\n") catch |e| switch (e) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
    res.end(null) catch |e| switch (e) {
        error.StreamBlocked => return error.StreamBlocked,
        else => return error.InternalServerError,
    };
}

fn datagramEcho(server: *QuicServer, conn: *connection.Connection, payload: []const u8, _: ?*anyopaque) http.DatagramError!void {
    // Echo back, ignore transient backpressure
    server.sendDatagram(conn, payload) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
}
