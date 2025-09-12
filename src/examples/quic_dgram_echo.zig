const std = @import("std");
const QuicServer = @import("server").QuicServer;
const ServerConfig = @import("config").ServerConfig;
const http = @import("http");
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
        .cc_algorithm = "cubic",
        .enable_dgram = true,
        .dgram_recv_queue_len = 1024,
        .dgram_send_queue_len = 1024,
    };

    const server = try QuicServer.init(allocator, config);
    defer server.deinit();

    // Readiness route
    try server.route(.GET, "/", indexHandler);

    // Echo any received QUIC DATAGRAM back to the sender
    server.onDatagram(datagramEcho, null);

    try server.bind();
    std.debug.print("QUIC DATAGRAM echo server on 127.0.0.1:{d}\n", .{port});
    try server.run();
}

fn indexHandler(_: *http.Request, res: *http.Response) http.HandlerError!void {
    try res.header(http.Headers.ContentType, http.MimeTypes.TextPlain);
    try res.writeAll("ok\n");
    try res.end(null);
}

fn datagramEcho(server: *QuicServer, conn: *connection.Connection, payload: []const u8, _: ?*anyopaque) http.DatagramError!void {
    // Echo back, ignore transient backpressure
    server.sendDatagram(conn, payload) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
}
