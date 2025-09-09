const std = @import("std");
const QuicServer = @import("server").QuicServer;
const ServerConfig = @import("config").ServerConfig;
const http = @import("http");

var g_enable_progress_log: bool = false;
var g_disable_hash: bool = false;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // Enable verbose app-level logs only when H3_DEBUG is set (keeps perf high by default)
    if (std.process.getEnvVarOwned(allocator, "H3_DEBUG")) |_| {
        g_enable_progress_log = true;
    } else |_| {}

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    var port: u16 = 4433;
    var cert_path: []const u8 = "third_party/quiche/quiche/examples/cert.crt";
    var key_path: []const u8 = "third_party/quiche/quiche/examples/cert.key";
    var qlog_dir: ?[]const u8 = "qlogs";
    var cc_algo: []const u8 = "bbr2"; // default to bbr2 for perf experiments (falls back internally)
    var enable_pacing: bool = true;   // enable pacing with BBR/BBR2
    
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
        } else if (std.mem.eql(u8, args[i], "--cc") and i + 1 < args.len) {
            i += 1;
            cc_algo = args[i];
        } else if (std.mem.eql(u8, args[i], "--pacing")) {
            enable_pacing = true;
        } else if (std.mem.eql(u8, args[i], "--no-pacing")) {
            enable_pacing = false;
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
    std.debug.print("CC:   {s}\n", .{cc_algo});
    std.debug.print("Pacing: {s}\n\n", .{if (enable_pacing) "on" else "off"});
    
    // Check for chunk size configuration
    const chunk_kb_str = std.process.getEnvVarOwned(allocator, "H3_CHUNK_KB") catch null;
    defer if (chunk_kb_str) |c| allocator.free(c);
    
    if (chunk_kb_str) |chunk_str| {
        const chunk_kb = std.fmt.parseInt(usize, chunk_str, 10) catch 256;
        const chunk_bytes = chunk_kb * 1024;
        http.streaming.setDefaultChunkSize(chunk_bytes);
        std.debug.print("Chunk: {d} KiB (H3_CHUNK_KB={s})\n", .{ chunk_kb, chunk_str });
    } else {
        std.debug.print("Chunk: {d} KiB\n", .{http.streaming.getDefaultChunkSize() / 1024});
    }
    
    // Check if hashing is disabled
    const disable_hash = std.process.getEnvVarOwned(allocator, "H3_NO_HASH") catch null;
    defer if (disable_hash) |d| allocator.free(d);
    g_disable_hash = if (disable_hash) |d| std.mem.eql(u8, d, "1") else false;
    
    if (g_disable_hash) {
        std.debug.print("SHA-256: disabled (H3_NO_HASH=1)\n\n", .{});
    } else {
        std.debug.print("SHA-256: enabled\n", .{});
    }
    std.debug.print("\n", .{});
    
    // Create server configuration
    const config = ServerConfig{
        .bind_port = port,
        .bind_addr = "127.0.0.1", // Bind to loopback for tests/sandbox
        .cert_path = cert_path,
        .key_path = key_path,
        .qlog_dir = qlog_dir,

        // Prioritize h3 for M3, keep hq-interop for compatibility
        .alpn_protocols = &.{ "h3", "hq-interop" },

        // Tuned for local perf tests: increase flow control to reduce update churn
        .idle_timeout_ms = 120_000,
        .initial_max_data = 64 * 1024 * 1024, // aggregate recv window
        .initial_max_stream_data_bidi_remote = 8 * 1024 * 1024, // peer→us per-stream for uploads
        .initial_max_streams_bidi = 64,
        .initial_max_streams_uni = 64,

        // Disable quiche's internal debug logging by default for performance
        .enable_debug_logging = false,
        .debug_log_throttle = 100,
        .enable_pacing = enable_pacing,
        .cc_algorithm = cc_algo,
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
    
    // Upload streaming endpoints (M5 - push-mode callbacks)
    try server.routeStreaming(.POST, "/upload/stream", .{
        .on_headers = uploadStreamOnHeaders,
        .on_body_chunk = uploadStreamOnChunk,
        .on_body_complete = uploadStreamOnComplete,
    });
    try server.routeStreaming(.POST, "/upload/echo", .{
        .on_headers = uploadEchoOnHeaders,
        .on_body_chunk = uploadEchoOnChunk,
        .on_body_complete = uploadEchoOnComplete,
    });
    
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
    std.debug.print("  POST /upload/stream (streaming upload with SHA-256)\n", .{});
    std.debug.print("  POST /upload/echo (bidirectional echo)\n", .{});
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
    
    // Enhanced safety checks
    // 1. Check for double slash in raw path (absolute path attempt)
    // The router collapses empty segments, so /download//etc/passwd becomes /download/etc/passwd
    // We need to check the raw decoded path to detect this
    if (req.path_decoded.len >= 11 and 
        std.mem.startsWith(u8, req.path_decoded, "/download/") and 
        req.path_decoded[10] == '/') {
        try res.jsonError(403, "Absolute paths not allowed");
        return;
    }
    
    // 2. Don't allow .. in path (path traversal)
    if (std.mem.indexOf(u8, file_path, "..") != null) {
        try res.jsonError(403, "Path traversal not allowed");
        return;
    }
    
    // 3. Don't allow absolute paths (in case wildcard captures one)
    if (std.fs.path.isAbsolute(file_path)) {
        try res.jsonError(403, "Absolute paths not allowed");
        return;
    }
    
    // 4. Don't allow empty path
    if (file_path.len == 0) {
        try res.jsonError(400, "File path required");
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
    const chunk_sz = http.streaming.getDefaultChunkSize();
    res.partial_response = try http.streaming.PartialResponse.initGenerator(
        allocator,
        ctx,
        generate1GB,
        chunk_sz,
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
    
    // Send response with checksum header and content length
    try res.header(http.Headers.ContentType, "application/octet-stream");
    try res.header(http.Headers.ContentLength, "10485760"); // 10MB exactly
    var checksum_buf: [20]u8 = undefined;
    const checksum_str = try std.fmt.bufPrint(&checksum_buf, "{d}", .{checksum});
    try res.header("X-Checksum", checksum_str);
    
    // Use writeAll which handles backpressure properly
    // If it returns StreamBlocked, the updated invokeHandler will handle it
    try res.writeAll(data);
    try res.end(null);
}

// Upload streaming handlers - demonstrate push-mode callbacks
// These process uploads without buffering entire request

// Context for tracking upload state
const UploadContext = struct {
    hasher: std.crypto.hash.sha2.Sha256,
    bytes_received: usize,
    start_time: i64,
    compute_hash: bool,
};

fn uploadStreamOnHeaders(req: *http.Request, res: *http.Response) !void {
    _ = res; // Response not used in headers callback for this handler
    // Called when headers complete - can send early response or validate
    const content_length = req.contentLength();
    
    // Allocate context for tracking upload
    const ctx = try req.arena.allocator().create(UploadContext);
    ctx.* = .{
        .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        .bytes_received = 0,
        .start_time = std.time.milliTimestamp(),
        .compute_hash = !g_disable_hash,
    };
    
    // Store context in request's user_data field
    req.user_data = @ptrCast(ctx);
    
    if (content_length) |len| {
        std.debug.print("Upload starting: {} bytes expected\n", .{len});
    } else {
        std.debug.print("Upload starting: chunked transfer\n", .{});
    }
}

fn uploadStreamOnChunk(req: *http.Request, res: *http.Response, chunk: []const u8) !void {
    _ = res; // Not sending response during chunks
    
    // Retrieve context from user_data
    const ctx = if (req.user_data) |ptr|
        @as(*UploadContext, @ptrCast(@alignCast(ptr)))
    else {
        std.debug.print("Missing upload context in chunk handler\n", .{});
        return;
    };
    
    // Update SHA-256 hash only if enabled
    if (ctx.compute_hash) {
        ctx.hasher.update(chunk);
    }
    ctx.bytes_received += chunk.len;
    
    // Optional progress log every MB when enabled
    if (g_enable_progress_log) {
        if (ctx.bytes_received % (1024 * 1024) == 0) {
            std.debug.print("Upload progress: {} MB\n", .{ctx.bytes_received / (1024 * 1024)});
        }
    }
}

fn uploadStreamOnComplete(req: *http.Request, res: *http.Response) !void {
    // Retrieve and finalize context from user_data
    const ctx = if (req.user_data) |ptr|
        @as(*UploadContext, @ptrCast(@alignCast(ptr)))
    else {
        try res.jsonError(500, "Missing upload context");
        return;
    };
    
    const elapsed_ms = std.time.milliTimestamp() - ctx.start_time;
    
    // Compute final hash if enabled
    var hash_hex_buf: [64]u8 = undefined;
    var hash_hex: []const u8 = "disabled";
    
    if (ctx.compute_hash) {
        var hash: [32]u8 = undefined;
        ctx.hasher.final(&hash);
        
        // Format hash as hex string
        for (&hash, 0..) |byte, i| {
            _ = try std.fmt.bufPrint(hash_hex_buf[i*2..][0..2], "{x:0>2}", .{byte});
        }
        hash_hex = &hash_hex_buf;
    }
    
    // Send response with upload stats
    const response = struct {
        bytes_received: usize,
        sha256: []const u8,
        elapsed_ms: i64,
        throughput_mbps: f64,
    }{
        .bytes_received = ctx.bytes_received,
        .sha256 = hash_hex,
        .elapsed_ms = elapsed_ms,
        .throughput_mbps = if (elapsed_ms > 0) 
            @as(f64, @floatFromInt(ctx.bytes_received)) * 8.0 / (@as(f64, @floatFromInt(elapsed_ms)) * 1000.0)
        else 
            0.0,
    };
    
    try res.jsonValue(response);
    
    std.debug.print("Upload complete: {} bytes, SHA-256: {s}\n", .{ctx.bytes_received, hash_hex});
}

// Echo upload handlers - demonstrate bidirectional streaming
fn uploadEchoOnHeaders(req: *http.Request, res: *http.Response) !void {
    _ = req;
    
    // Start response immediately - bidirectional streaming
    try res.status(200);
    try res.header(http.Headers.ContentType, "text/plain");
    try res.header("X-Echo-Mode", "streaming");
    
    // Don't call end() - keep stream open for writing chunks
}

fn uploadEchoOnChunk(req: *http.Request, res: *http.Response, chunk: []const u8) !void {
    _ = req;
    
    // Echo each chunk back immediately
    // This demonstrates bidirectional streaming - response before request completes
    res.writeAll(chunk) catch |err| switch (err) {
        error.StreamBlocked => {
            // Backpressure - data queued for later transmission via PartialResponse
            std.debug.print("Echo backpressure, data queued for retry\n", .{});
        },
        else => return err,
    };
}

fn uploadEchoOnComplete(req: *http.Request, res: *http.Response) !void {
    _ = req;
    
    // Send final chunk and close stream
    res.writeAll("\n--- Upload Complete ---\n") catch |err| switch (err) {
        error.StreamBlocked => {
            // Backpressure on final message - data queued for retry
            std.debug.print("Final message blocked, queued for retry\n", .{});
        },
        else => return err,
    };
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
        \\  --cc <algo>      Congestion control: cubic|reno|bbr|bbr2 (default: bbr2)
        \\  --pacing         Enable pacing (default)
        \\  --no-pacing      Disable pacing
        \\  --help           Show this help message
        \\
        \\Test with quiche-client:
        \\  cd third_party/quiche
        \\  cargo run -p quiche --bin quiche-client -- \
        \\    https://127.0.0.1:4433/ --no-verify --alpn h3
        \\
    , .{});
}
