const std = @import("std");
const QuicServer = @import("server").QuicServer;
const ServerConfig = @import("config").ServerConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    var port: u16 = 4433;
    var cert_path: []const u8 = "third_party/quiche/quiche/examples/cert.crt";
    var key_path: []const u8 = "third_party/quiche/quiche/examples/cert.key";
    var qlog_dir: ?[]const u8 = "qlogs";
    
    // Simple argument parsing
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
        } else if (std.mem.eql(u8, args[i], "--no-qlog")) {
            qlog_dir = null;
        } else if (std.mem.eql(u8, args[i], "--help")) {
            printHelp();
            return;
        }
    }
    
    std.debug.print("\n=== QUIC Server (Milestone 3 - HTTP/3) ===\n", .{});
    std.debug.print("Port: {d}\n", .{port});
    std.debug.print("Cert: {s}\n", .{cert_path});
    std.debug.print("Key:  {s}\n", .{key_path});
    if (qlog_dir) |dir| {
        std.debug.print("Qlog: {s}/\n", .{dir});
    } else {
        std.debug.print("Qlog: disabled\n", .{});
    }
    std.debug.print("\n", .{});
    
    // Create server configuration
    const config = ServerConfig{
        .bind_port = port,
        .cert_path = cert_path,
        .key_path = key_path,
        .qlog_dir = qlog_dir,
        
        // Prioritize h3 for M3, keep hq-interop for compatibility
        .alpn_protocols = &.{ "h3", "hq-interop" },
        
        // Conservative settings for M2
        .idle_timeout_ms = 30_000,
        .initial_max_data = 2 * 1024 * 1024,
        .initial_max_streams_bidi = 10,
        .initial_max_streams_uni = 10,
        
        // Enable debug logging
        .enable_debug_logging = true,
        .debug_log_throttle = 100, // Less verbose
    };
    
    // Create and run server
    const server = try QuicServer.init(allocator, config);
    defer server.deinit();
    
    try server.bind();
    try server.run();
}

fn printHelp() void {
    std.debug.print(
        \\Usage: quic_server [options]
        \\
        \\Options:
        \\  --port <port>    Server port (default: 4433)
        \\  --cert <path>    Certificate file path
        \\  --key <path>     Private key file path
        \\  --no-qlog        Disable qlog output
        \\  --help           Show this help message
        \\
        \\Test with quiche-client:
        \\  cd third_party/quiche
        \\  cargo run -p quiche --bin quiche-client -- \
        \\    https://127.0.0.1:4433/ --no-verify --alpn h3
        \\
    , .{});
}