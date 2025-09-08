const std = @import("std");
const QuicServer = @import("server").QuicServer;
const ServerConfig = @import("config").ServerConfig;
const http = @import("http");

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
    
    // Register routes
    try registerRoutes(server);
    
    try server.bind();
    try server.run();
}

fn registerRoutes(server: *QuicServer) !void {
    // Root endpoint
    try server.route(.GET, "/", indexHandler);
    
    // API endpoints
    try server.route(.GET, "/api/users", listUsersHandler);
    try server.route(.GET, "/api/users/:id", getUserHandler);
    try server.route(.POST, "/api/users", createUserHandler);
    try server.route(.POST, "/api/echo", echoHandler);
    
    // Wildcard example
    try server.route(.GET, "/files/*", filesHandler);
    
    // Streaming test endpoints (Milestone 5)
    try server.route(.GET, "/download/*", downloadHandler);
    try server.route(.GET, "/stream/1gb", stream1GBHandler);
    try server.route(.GET, "/stream/test", streamTestHandler);
    
    std.debug.print("Routes registered:\n", .{});
    std.debug.print("  GET  /\n", .{});
    std.debug.print("  GET  /api/users\n", .{});
    std.debug.print("  GET  /api/users/:id\n", .{});
    std.debug.print("  POST /api/users\n", .{});
    std.debug.print("  POST /api/echo\n", .{});
    std.debug.print("  GET  /files/*\n", .{});
    std.debug.print("  GET  /download/* (file streaming)\n", .{});
    std.debug.print("  GET  /stream/1gb (1GB test)\n", .{});
    std.debug.print("  GET  /stream/test (streaming test)\n", .{});
    std.debug.print("\n", .{});
}

// Handler functions
fn indexHandler(req: *http.Request, res: *http.Response) !void {
    _ = req;
    
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>QUIC/HTTP3 Server</title></head>
        \\<body>
        \\<h1>Welcome to Zig QUIC/HTTP3 Server!</h1>
        \\<p>Milestone 4: Dynamic Routing</p>
        \\<ul>
        \\  <li><a href="/api/users">/api/users</a> - List users</li>
        \\  <li><a href="/api/users/123">/api/users/123</a> - Get user by ID</li>
        \\  <li><a href="/files/test.txt">/files/test.txt</a> - Wildcard route</li>
        \\</ul>
        \\</body>
        \\</html>
    ;
    
    try res.header(http.Headers.ContentType, http.MimeTypes.TextHtml);
    try res.writeAll(html);
    try res.end(null);
}

fn listUsersHandler(req: *http.Request, res: *http.Response) !void {
    _ = req;
    
    // Use proper JSON serialization with an array of structs
    const users = [_]struct { id: u32, name: []const u8 }{
        .{ .id = 1, .name = "Alice" },
        .{ .id = 2, .name = "Bob" },
        .{ .id = 3, .name = "Charlie" },
    };
    
    try res.jsonValue(users);
}

fn getUserHandler(req: *http.Request, res: *http.Response) !void {
    const id = req.getParam("id") orelse return error.BadRequest;
    
    // Use proper JSON serialization with struct
    const user = struct {
        id: []const u8,
        name: []const u8,
    }{
        .id = id,
        .name = try std.fmt.allocPrint(req.arena.allocator(), "User {s}", .{id}),
    };
    try res.jsonValue(user);
}

fn createUserHandler(req: *http.Request, res: *http.Response) !void {
    // Read request body
    const body = try req.readAll(1024 * 1024); // 1MB max
    
    // For M4, echo back with metadata
    if (body.len > 0) {
        try res.status(@intFromEnum(http.Status.Created));
        const response = struct {
            message: []const u8,
            received: []const u8,
        }{
            .message = "User created",
            .received = body,
        };
        try res.jsonValue(response);
    } else {
        try res.jsonError(400, "Request body required");
    }
}

fn filesHandler(req: *http.Request, res: *http.Response) !void {
    const wildcard_path = req.getParam("*") orelse "";
    
    // Use proper JSON serialization
    const response = struct {
        requested_file: []const u8,
        note: []const u8,
    }{
        .requested_file = wildcard_path,
        .note = "This is a wildcard route demo",
    };
    try res.jsonValue(response);
}

fn echoHandler(req: *http.Request, res: *http.Response) !void {
    // Read request body
    const body = try req.readAll(1024 * 1024); // 1MB max
    
    // Get content type from request
    const content_type = req.contentType() orelse "text/plain";
    
    // Echo back with proper JSON serialization
    if (body.len > 0) {
        const response = struct {
            received_bytes: usize,
            content_type: []const u8,
            echo: []const u8,
        }{
            .received_bytes = body.len,
            .content_type = content_type,
            .echo = body,
        };
        try res.jsonValue(response);
    } else {
        const response = struct {
            received_bytes: usize,
            note: []const u8,
        }{
            .received_bytes = 0,
            .note = "No body received",
        };
        try res.jsonValue(response);
    }
}

// Streaming handlers for Milestone 5
fn downloadHandler(req: *http.Request, res: *http.Response) !void {
    const file_path = req.getParam("*") orelse "";
    
    // Build absolute path (safely, avoiding path traversal)
    const allocator = req.arena.allocator();
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    
    // Simple safety check - don't allow .. in path
    if (std.mem.indexOf(u8, file_path, "..") != null) {
        try res.jsonError(403, "Path traversal not allowed");
        return;
    }
    
    const full_path = try std.fs.path.join(allocator, &.{ cwd, file_path });
    
    // Try to send the file using zero-copy streaming
    res.sendFile(full_path) catch |err| {
        switch (err) {
            error.FileNotFound => try res.jsonError(404, "File not found"),
            error.AccessDenied => try res.jsonError(403, "Access denied"),
            else => try res.jsonError(500, "Internal server error"),
        }
    };
}

// Context for 1GB generator
const OneGBContext = struct {
    pattern: []const u8,
    total_written: usize,
    total_size: usize,
};

fn generate1GB(ctx: *anyopaque, buf: []u8) anyerror!usize {
    const context = @as(*OneGBContext, @ptrCast(@alignCast(ctx)));
    
    if (context.total_written >= context.total_size) {
        return 0; // Done generating
    }
    
    // Fill buffer with pattern
    var written: usize = 0;
    while (written < buf.len and context.total_written < context.total_size) {
        const pattern_offset = context.total_written % context.pattern.len;
        const to_copy = @min(
            context.pattern.len - pattern_offset,
            buf.len - written,
            context.total_size - context.total_written
        );
        
        @memcpy(buf[written..][0..to_copy], context.pattern[pattern_offset..][0..to_copy]);
        written += to_copy;
        context.total_written += to_copy;
    }
    
    return written;
}

fn stream1GBHandler(req: *http.Request, res: *http.Response) !void {
    const allocator = req.arena.allocator();
    
    // Create generator context
    const ctx = try allocator.create(OneGBContext);
    ctx.* = .{
        .pattern = "0123456789ABCDEF",
        .total_written = 0,
        .total_size = 1024 * 1024 * 1024, // 1GB
    };
    
    try res.header(http.Headers.ContentType, "application/octet-stream");
    try res.header(http.Headers.ContentLength, "1073741824"); // 1GB
    
    // Use generator-based streaming to avoid blocking the event loop
    res.partial_response = try http.streaming.PartialResponse.initGenerator(
        allocator,
        ctx,
        generate1GB,
        64 * 1024, // 64KB buffer
        1024 * 1024 * 1024, // 1GB total
        true // Send FIN when complete
    );
    
    // Start the streaming - processWritableStreams will continue it
    try res.processPartialResponse();
}

fn streamTestHandler(req: *http.Request, res: *http.Response) !void {
    // Generate test data with checksum
    const allocator = req.arena.allocator();
    const test_size = 10 * 1024 * 1024; // 10MB
    
    // Generate predictable test data
    const data = try allocator.alloc(u8, test_size);
    for (data, 0..) |*byte, i| {
        byte.* = @truncate(i % 256);
    }
    
    // Calculate simple checksum
    var checksum: u32 = 0;
    for (data) |byte| {
        checksum = checksum +% byte;
    }
    
    // Send response with checksum header
    try res.header(http.Headers.ContentType, "application/octet-stream");
    var checksum_buf: [20]u8 = undefined;
    const checksum_str = try std.fmt.bufPrint(&checksum_buf, "{d}", .{checksum});
    try res.header("X-Checksum", checksum_str);
    
    // Use writeAll which handles backpressure properly
    // If it returns StreamBlocked, the updated invokeHandler will handle it
    try res.writeAll(data);
    try res.end(null);
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