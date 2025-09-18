const std = @import("std");
const args = @import("args");
const client = @import("client");

const base64 = std.base64;
const ascii = std.ascii;
const math = std.math;

pub fn main() !void {
    mainImpl() catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn mainImpl() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parser = args.Parser(CliArgs);
    const parsed = parser.parse(allocator, argv) catch |err| switch (err) {
        error.MissingUrl => {
            std.debug.print("Error: --url is required\n", .{});
            std.process.exit(2);
        },
        error.LimitRateRequiresStream => {
            std.debug.print("Error: --limit-rate requires --stream\n", .{});
            std.process.exit(2);
        },
        error.StreamRequiresFile => {
            std.debug.print("Error: --body-file-stream requires --body-file\n", .{});
            std.process.exit(2);
        },
        error.ConflictingDatagramPayloadSources => {
            std.debug.print("Error: specify either --dgram-payload or --dgram-payload-file, not both\n", .{});
            std.process.exit(2);
        },
        error.DatagramRequiresStream => {
            std.debug.print("Error: --dgram options require --stream\n", .{});
            std.process.exit(2);
        },
        error.InvalidRepeat => {
            std.debug.print("Error: --repeat must be at least 1\n", .{});
            std.process.exit(2);
        },
        error.RepeatRequiresBuffered => {
            std.debug.print("Error: --repeat>1 cannot be combined with --stream\n", .{});
            std.process.exit(2);
        },
        error.DatagramRepeatUnsupported => {
            std.debug.print("Error: --repeat>1 with DATAGRAMs is not supported yet\n", .{});
            std.process.exit(2);
        },
        else => return err,
    };

    const uri = std.Uri.parse(parsed.url) catch {
        std.debug.print("Error: invalid URL '{s}'\n", .{parsed.url});
        std.process.exit(2);
    };

    if (uri.scheme.len == 0 or !std.mem.eql(u8, uri.scheme, "https")) {
        std.debug.print("Error: only https:// URLs are supported\n", .{});
        std.process.exit(2);
    }

    const host_component = uri.host orelse {
        std.debug.print("Error: URL missing host\n", .{});
        std.process.exit(2);
    };

    const port = uri.port orelse 443;
    const path = try buildPath(allocator, uri);
    defer allocator.free(path);

    const host_dup = try componentToOwnedSlice(allocator, host_component);
    defer allocator.free(host_dup);

    var headers_slice: []client.HeaderPair = &.{};
    if (parsed.headers.len > 0) {
        headers_slice = parseHeaders(allocator, parsed.headers) catch |parse_err| switch (parse_err) {
            error.InvalidHeader => {
                std.debug.print("Error: invalid header format\n", .{});
                std.process.exit(2);
            },
            else => return parse_err,
        };
    }
    defer {
        for (headers_slice) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        if (headers_slice.len > 0) allocator.free(headers_slice);
    }

    var body_owned: ?[]u8 = null;
    if (parsed.body_file.len > 0) {
        if (!parsed.body_file_stream) {
            const data = try std.fs.cwd().readFileAlloc(allocator, parsed.body_file, std.math.maxInt(usize));
            body_owned = data;
        }
    } else if (parsed.body.len > 0) {
        body_owned = try allocator.dupe(u8, parsed.body);
    }
    defer if (body_owned) |buf| allocator.free(buf);

    var limit_rate_bps: ?u64 = null;
    if (parsed.limit_rate.len > 0) {
        limit_rate_bps = parseLimitRate(parsed.limit_rate) catch |rate_err| switch (rate_err) {
            error.InvalidRateFormat => {
                std.debug.print("Error: invalid --limit-rate format\n", .{});
                std.process.exit(2);
            },
            error.RateOverflow => {
                std.debug.print("Error: --limit-rate value is too large\n", .{});
                std.process.exit(2);
            },
            error.ZeroRate => {
                std.debug.print("Error: --limit-rate must be greater than zero\n", .{});
                std.process.exit(2);
            },
        };
    }

    var client_config = client.ClientConfig{};
    client_config.verify_peer = parsed.verify_peer;
    client_config.idle_timeout_ms = parsed.timeout_ms;
    client_config.enable_webtransport = parsed.enable_webtransport;
    if (parsed.dgram_count > 0) {
        client_config.enable_dgram = true;
        client_config.dgram_recv_queue_len = 64;
        client_config.dgram_send_queue_len = 64;
    }

    var quic_client = try client.QuicClient.init(allocator, client_config);
    defer quic_client.deinit();

    const endpoint = client.ServerEndpoint{
        .host = host_dup,
        .port = @intCast(port),
    };

    try quic_client.connect(endpoint);

    var options = client.FetchOptions{
        .method = parsed.method,
        .path = path,
        .headers = headers_slice,
    };

    const use_stream_file = parsed.body_file_stream and parsed.body_file.len > 0;
    if (parsed.repeat > 1 and use_stream_file) {
        std.debug.print("Error: --repeat>1 cannot be combined with --body-file-stream\n", .{});
        std.process.exit(2);
    }

    var file_stream_ctx: FileStream = undefined;
    if (parsed.body_file.len > 0) {
        const file_path = parsed.body_file;
        if (use_stream_file) {
            const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
            file_stream_ctx = FileStream{ .file = file };
            options.body_provider = .{ .ctx = &file_stream_ctx, .next = FileStream.next };
        } else if (body_owned) |buf| {
            options.body = buf;
        }
    } else if (body_owned) |buf| {
        options.body = buf;
    }

    defer if (use_stream_file) file_stream_ctx.file.close();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer_impl = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout_writer = &stdout_writer_impl.interface;
    defer stdout_writer.flush() catch |flush_err| {
        std.debug.print("Error flushing stdout: {}\n", .{flush_err});
    };
    var rate_limiter_storage: RateLimiter = undefined;
    var rate_limiter_ptr: ?*RateLimiter = null;
    if (limit_rate_bps) |bps| {
        rate_limiter_storage = try RateLimiter.init(bps);
        rate_limiter_ptr = &rate_limiter_storage;
    }

    var stream_output = StreamOutput{
        .writer = stdout_writer,
        .allocator = allocator,
        .mode = if (parsed.json) StreamOutput.Mode.json else StreamOutput.Mode.plain,
        .verbose = parsed.output_body,
        .rate_limiter = rate_limiter_ptr,
    };

    if (parsed.stream or limit_rate_bps != null or parsed.dgram_count > 0) {
        options.on_event = streamCallback;
        options.event_ctx = &stream_output;
    }

    const datagram_payload = try loadDatagramPayload(allocator, parsed);
    defer if (parsed.dgram_payload_file.len > 0 and parsed.dgram_count > 0) allocator.free(datagram_payload);

    if (parsed.repeat > 1) {
        try runRepeatedRequests(allocator, stdout_writer, quic_client, options, parsed, datagram_payload);
        return;
    }

    if (parsed.dgram_count > 0) {
        var handle = try quic_client.startRequest(allocator, options);
        try sendDatagramsForHandle(quic_client, handle.stream_id, datagram_payload, parsed.dgram_count, parsed.dgram_interval_ms);
        if (parsed.dgram_wait_ms > 0) {
            std.Thread.sleep(parsed.dgram_wait_ms * std.time.ns_per_ms);
        }
        var response = handle.await() catch |err| {
            return err;
        };
        defer response.deinit(allocator);
        try outputResponse(stdout_writer, allocator, response, parsed);
        return;
    }

    var response = try quic_client.fetchWithOptions(allocator, options);
    defer response.deinit(allocator);
    try outputResponse(stdout_writer, allocator, response, parsed);
}

const CliArgs = struct {
    url: []const u8 = "",
    method: []const u8 = "GET",
    headers: []const u8 = "",
    body: []const u8 = "",
    body_file: []const u8 = "",
    body_file_stream: bool = false,
    stream: bool = false,
    output_body: bool = true,
    timeout_ms: u64 = 10_000,
    json: bool = false,
    verify_peer: bool = false,
    limit_rate: []const u8 = "",
    dgram_payload: []const u8 = "",
    dgram_payload_file: []const u8 = "",
    dgram_count: usize = 0,
    dgram_interval_ms: u64 = 0,
    dgram_wait_ms: u64 = 0,
    repeat: usize = 1,
    enable_webtransport: bool = false,

    pub const descriptions = .{
        .url = "Target URL (https://host[:port]/path)",
        .method = "HTTP method to use (default: GET)",
        .headers = "Comma or newline separated headers (e.g. 'accept:application/json,foo:bar')",
        .body = "Inline request body string",
        .body_file = "Read request body from file",
        .body_file_stream = "Stream request body file without buffering entirely",
        .stream = "Stream response events instead of buffering body",
        .output_body = "Print response body when buffering (default true)",
        .timeout_ms = "Connection timeout in milliseconds",
        .json = "Emit a single JSON object instead of human-readable output",
        .verify_peer = "Verify TLS certificates (default: disabled)",
        .limit_rate = "Throttle download rate (e.g. 500K, 10M) requires --stream",
        .dgram_payload = "Send this UTF-8 payload as HTTP/3 DATAGRAMs",
        .dgram_payload_file = "Read DATAGRAM payload from file",
        .dgram_count = "Number of DATAGRAMs to send per request (default: 0)",
        .dgram_interval_ms = "Delay in milliseconds between DATAGRAM sends (default: 0)",
        .dgram_wait_ms = "Extra time to wait for DATAGRAM echoes after sends (default: 0)",
        .repeat = "Number of concurrent identical requests (default: 1)",
        .enable_webtransport = "Enable WebTransport Extended CONNECT support",
    };

    pub fn validate(self: *CliArgs) !void {
        if (self.url.len == 0) return error.MissingUrl;
        if (self.limit_rate.len > 0 and !self.stream) return error.LimitRateRequiresStream;
        if (self.body_file_stream and self.body_file.len == 0) return error.StreamRequiresFile;
        if (self.dgram_payload.len > 0 and self.dgram_payload_file.len > 0) return error.ConflictingDatagramPayloadSources;
        if (self.dgram_count > 0 and !self.stream) return error.DatagramRequiresStream;
        if (self.repeat == 0) return error.InvalidRepeat;
        if (self.repeat > 1 and self.stream) return error.RepeatRequiresBuffered;
        if (self.repeat > 1 and self.dgram_count > 0) return error.DatagramRepeatUnsupported;
    }
};

const RateLimiter = struct {
    bytes_per_second: u64,
    timer: std.time.Timer,
    total_bytes: u64,

    fn init(bytes_per_second: u64) !RateLimiter {
        return .{
            .bytes_per_second = bytes_per_second,
            .timer = try std.time.Timer.start(),
            .total_bytes = 0,
        };
    }

    fn onBytes(self: *RateLimiter, byte_count: usize) void {
        if (byte_count == 0) return;
        self.total_bytes += byte_count;

        const expected_ns_u128 = (@as(u128, self.total_bytes) * std.time.ns_per_s) / self.bytes_per_second;
        const elapsed_ns = @as(u128, self.timer.read());

        if (expected_ns_u128 > elapsed_ns) {
            const diff = expected_ns_u128 - elapsed_ns;
            const sleep_ns: u64 = if (diff > std.math.maxInt(u64))
                std.math.maxInt(u64)
            else
                @intCast(diff);
            std.Thread.sleep(sleep_ns);
        }
    }
};

const StreamOutput = struct {
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    verbose: bool = false,
    rate_limiter: ?*RateLimiter = null,
    mode: Mode = .plain,

    const Mode = enum { plain, json };
};

fn streamCallback(event: client.ResponseEvent, ctx: ?*anyopaque) client.ClientError!void {
    const stream: *StreamOutput = @ptrCast(@alignCast(ctx.?));
    const writer = stream.writer;
    switch (stream.mode) {
        .plain => switch (event) {
            .headers => |headers| {
                writer.print("event=headers\n", .{}) catch return client.ClientError.H3Error;
                for (headers) |pair| {
                    writer.print("{s}: {s}\n", .{ pair.name, pair.value }) catch return client.ClientError.H3Error;
                }
            },
            .data => |chunk| {
                if (stream.rate_limiter) |rl| {
                    rl.onBytes(chunk.len);
                }
                writer.print("event=data size={d}\n", .{chunk.len}) catch return client.ClientError.H3Error;
                if (stream.verbose and chunk.len > 0) {
                    writer.writeAll(chunk) catch return client.ClientError.H3Error;
                    writer.writeByte('\n') catch return client.ClientError.H3Error;
                }
            },
            .trailers => |trailers| {
                writer.print("event=trailers\n", .{}) catch return client.ClientError.H3Error;
                for (trailers) |pair| {
                    writer.print("{s}: {s}\n", .{ pair.name, pair.value }) catch return client.ClientError.H3Error;
                }
            },
            .finished => {
                writer.print("event=finished\n", .{}) catch return client.ClientError.H3Error;
            },
            .datagram => |d| {
                writer.print("event=datagram flow={d} size={d}\n", .{ d.flow_id, d.payload.len }) catch
                    return client.ClientError.H3Error;
                if (stream.verbose and d.payload.len > 0) {
                    writer.writeAll(d.payload) catch return client.ClientError.H3Error;
                    writer.writeByte('\n') catch return client.ClientError.H3Error;
                }
            },
        },
        .json => switch (event) {
            .headers => |headers| {
                writeJsonEventHeaders(writer, headers) catch return client.ClientError.H3Error;
            },
            .data => |chunk| {
                if (stream.rate_limiter) |rl| {
                    rl.onBytes(chunk.len);
                }
                writeJsonEventData(stream, writer, chunk) catch return client.ClientError.H3Error;
            },
            .trailers => |trailers| {
                writeJsonEventTrailers(writer, trailers) catch return client.ClientError.H3Error;
            },
            .finished => {
                writeJsonEventFinished(writer) catch return client.ClientError.H3Error;
            },
            .datagram => |d| {
                writeJsonEventDatagram(stream, writer, d) catch return client.ClientError.H3Error;
            },
        },
    }
}

fn writeJsonEventHeaders(writer: *std.io.Writer, headers: []const client.HeaderPair) !void {
    try writer.writeAll("{\"event\":\"headers\",\"headers\":[");
    for (headers, 0..) |pair, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, pair.name);
        try writer.writeAll(",\"value\":");
        try writeJsonString(writer, pair.value);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn writeJsonEventTrailers(writer: *std.io.Writer, trailers: []const client.HeaderPair) !void {
    try writer.writeAll("{\"event\":\"trailers\",\"trailers\":[");
    for (trailers, 0..) |pair, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, pair.name);
        try writer.writeAll(",\"value\":");
        try writeJsonString(writer, pair.value);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn writeJsonEventData(stream: *StreamOutput, writer: *std.io.Writer, chunk: []const u8) !void {
    const encoded = try encodeBase64(stream.allocator, chunk);
    defer stream.allocator.free(encoded);
    try writer.writeAll("{\"event\":\"data\",\"size\":");
    try writer.print("{d}", .{chunk.len});
    try writer.writeAll(",\"base64\":");
    try writeJsonString(writer, encoded);
    try writer.writeAll("}\n");
}

fn writeJsonEventFinished(writer: *std.io.Writer) !void {
    try writer.writeAll("{\"event\":\"finished\"}\n");
}

fn writeJsonEventDatagram(stream: *StreamOutput, writer: *std.io.Writer, event: client.DatagramEvent) !void {
    const encoded = try encodeBase64(stream.allocator, event.payload);
    defer stream.allocator.free(encoded);
    try writer.writeAll("{\"event\":\"datagram\",\"flow_id\":");
    try writer.print("{d}", .{event.flow_id});
    try writer.writeAll(",\"size\":");
    try writer.print("{d}", .{event.payload.len});
    try writer.writeAll(",\"base64\":");
    try writeJsonString(writer, encoded);
    try writer.writeAll("}\n");
}

fn parseLimitRate(input: []const u8) !u64 {
    if (input.len == 0) return error.InvalidRateFormat;

    var idx: usize = 0;
    while (idx < input.len and ascii.isDigit(input[idx])) : (idx += 1) {}

    if (idx == 0) return error.InvalidRateFormat;

    const number_slice = input[0..idx];
    const value = std.fmt.parseInt(u64, number_slice, 10) catch return error.InvalidRateFormat;
    if (value == 0) return error.ZeroRate;

    const suffix = input[idx..];
    if (suffix.len == 0) return value;
    if (suffix.len > 3) return error.InvalidRateFormat;

    var lower_buf: [3]u8 = undefined;
    var lower_suffix = lower_buf[0..suffix.len];
    for (suffix, 0..) |ch, i| lower_suffix[i] = ascii.toLower(ch);

    const multiplier: u64 = if (std.mem.eql(u8, lower_suffix, "k") or
        std.mem.eql(u8, lower_suffix, "kb") or
        std.mem.eql(u8, lower_suffix, "kib")) 1024 else if (std.mem.eql(u8, lower_suffix, "m") or
        std.mem.eql(u8, lower_suffix, "mb") or
        std.mem.eql(u8, lower_suffix, "mib")) 1024 * 1024 else if (std.mem.eql(u8, lower_suffix, "g") or
        std.mem.eql(u8, lower_suffix, "gb") or
        std.mem.eql(u8, lower_suffix, "gib")) 1024 * 1024 * 1024 else if (std.mem.eql(u8, lower_suffix, "t") or
        std.mem.eql(u8, lower_suffix, "tb") or
        std.mem.eql(u8, lower_suffix, "tib")) 1024 * 1024 * 1024 * 1024 else return error.InvalidRateFormat;

    const result = math.mul(u64, value, multiplier) catch return error.RateOverflow;
    return result;
}

fn printJsonResponse(
    writer: anytype,
    allocator: std.mem.Allocator,
    response: client.FetchResponse,
    include_body: bool,
) !void {
    try writer.writeByte('{');
    try writer.print("\"status\":{d}", .{response.status});

    try writer.writeAll(",\"headers\":[");
    for (response.headers, 0..) |pair, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, pair.name);
        try writer.writeAll(",\"value\":");
        try writeJsonString(writer, pair.value);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');

    try writer.writeAll(",\"trailers\":[");
    for (response.trailers, 0..) |pair, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, pair.name);
        try writer.writeAll(",\"value\":");
        try writeJsonString(writer, pair.value);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');

    if (include_body) {
        try writer.writeAll(",\"body_base64\":");
        if (response.body.len == 0) {
            try writer.writeAll("\"\"");
        } else {
            const encoded = try encodeBase64(allocator, response.body);
            defer allocator.free(encoded);
            try writeJsonString(writer, encoded);
        }
    }

    try writer.writeByte('}');
    try writer.writeByte('\n');
}

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return allocator.alloc(u8, 0);
    const blocks = (data.len + 2) / 3;
    const encoded_len = blocks * 4;
    const buf = try allocator.alloc(u8, encoded_len);
    const encoded_slice = base64.standard.Encoder.encode(buf, data);
    return buf[0..encoded_slice.len];
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    var buf: [6]u8 = .{ '\\', 'u', '0', '0', '0', '0' };
                    buf[4] = hexDigit(byte >> 4);
                    buf[5] = hexDigit(byte & 0x0F);
                    try writer.writeAll(&buf);
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn hexDigit(nibble: u8) u8 {
    const value = nibble & 0x0F;
    if (value < 10) {
        return '0' + value;
    }
    return 'a' + (value - 10);
}

fn outputResponse(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    response: client.FetchResponse,
    parsed: CliArgs,
) !void {
    if (parsed.stream) {
        if (parsed.json) {
            try printJsonResponse(writer, allocator, response, false);
        } else {
            try writer.print("status {d}\n", .{response.status});
        }
        return;
    }

    if (parsed.json) {
        try printJsonResponse(writer, allocator, response, parsed.output_body);
        return;
    }

    try writer.print("status {d}\n", .{response.status});
    try writer.writeAll("headers:\n");
    for (response.headers) |pair| {
        try writer.print("  {s}: {s}\n", .{ pair.name, pair.value });
    }
    if (response.trailers.len > 0) {
        try writer.writeAll("trailers:\n");
        for (response.trailers) |pair| {
            try writer.print("  {s}: {s}\n", .{ pair.name, pair.value });
        }
    }
    if (parsed.output_body and response.body.len > 0) {
        try writer.writeAll("body:\n");
        try writer.writeAll(response.body);
        try writer.writeByte('\n');
    }
}

fn loadDatagramPayload(allocator: std.mem.Allocator, parsed: CliArgs) ![]const u8 {
    if (parsed.dgram_count == 0) return &.{};
    if (parsed.dgram_payload_file.len > 0) {
        return try std.fs.cwd().readFileAlloc(allocator, parsed.dgram_payload_file, std.math.maxInt(usize));
    }
    return parsed.dgram_payload;
}

fn sendDatagramsForHandle(
    quic_client: *client.QuicClient,
    stream_id: u64,
    payload: []const u8,
    count: usize,
    interval_ms: u64,
) client.ClientError!void {
    if (count == 0) return;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try quic_client.sendH3Datagram(stream_id, payload);
        if (interval_ms > 0 and i + 1 < count) {
            std.Thread.sleep(interval_ms * std.time.ns_per_ms);
        }
    }
}

fn printJsonResponseWithId(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    response: client.FetchResponse,
    include_body: bool,
    request_index: usize,
) !void {
    try writer.writeByte('{');
    try writer.print("\"request\":{d},\"status\":{d}", .{ request_index, response.status });

    try writer.writeAll(",\"headers\":[");
    for (response.headers, 0..) |pair, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, pair.name);
        try writer.writeAll(",\"value\":");
        try writeJsonString(writer, pair.value);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');

    try writer.writeAll(",\"trailers\":[");
    for (response.trailers, 0..) |pair, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, pair.name);
        try writer.writeAll(",\"value\":");
        try writeJsonString(writer, pair.value);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');

    if (include_body) {
        try writer.writeAll(",\"body_base64\":");
        if (response.body.len == 0) {
            try writer.writeAll("\"\"");
        } else {
            const encoded = try encodeBase64(allocator, response.body);
            defer allocator.free(encoded);
            try writeJsonString(writer, encoded);
        }
    }

    try writer.writeByte('}');
}

fn printPlainResponseWithId(
    writer: *std.io.Writer,
    response: client.FetchResponse,
    include_body: bool,
    request_index: usize,
) !void {
    try writer.print("request {d}: status {d}\n", .{ request_index, response.status });
    try writer.writeAll("headers:\n");
    for (response.headers) |pair| {
        try writer.print("  {s}: {s}\n", .{ pair.name, pair.value });
    }
    if (response.trailers.len > 0) {
        try writer.writeAll("trailers:\n");
        for (response.trailers) |pair| {
            try writer.print("  {s}: {s}\n", .{ pair.name, pair.value });
        }
    }
    if (include_body and response.body.len > 0) {
        try writer.writeAll("body:\n");
        try writer.writeAll(response.body);
        try writer.writeByte('\n');
    }
}

fn runRepeatedRequests(
    allocator: std.mem.Allocator,
    stdout_writer: *std.io.Writer,
    quic_client: *client.QuicClient,
    options: client.FetchOptions,
    parsed: CliArgs,
    datagram_payload: []const u8,
) client.ClientError!void {
    const count = parsed.repeat;
    var handles = allocator.alloc(client.FetchHandle, count) catch {
        return client.ClientError.H3Error;
    };
    defer allocator.free(handles);

    for (handles, 0..) |*slot, idx| {
        slot.* = quic_client.startRequest(allocator, options) catch |err| {
            // drain already-started requests to keep client state clean
            for (handles[0..idx]) |started| {
                var cleanup = started.await() catch continue;
                cleanup.deinit(allocator);
            }
            return err;
        };
    }

    if (parsed.dgram_count > 0) {
        for (handles) |handle| {
            try sendDatagramsForHandle(quic_client, handle.stream_id, datagram_payload, parsed.dgram_count, parsed.dgram_interval_ms);
        }
        if (parsed.dgram_wait_ms > 0) {
            std.Thread.sleep(parsed.dgram_wait_ms * std.time.ns_per_ms);
        }
    }

    var first = true;
    if (parsed.json) {
        stdout_writer.writeByte('[') catch return client.ClientError.H3Error;
    }

    for (handles, 0..) |handle, idx| {
        var response = handle.await() catch |err| {
            return err;
        };
        defer response.deinit(allocator);

        if (parsed.json) {
            if (!first) stdout_writer.writeAll(",\n") catch return client.ClientError.H3Error;
            first = false;
            printJsonResponseWithId(stdout_writer, allocator, response, parsed.output_body, idx) catch return client.ClientError.H3Error;
        } else {
            if (idx != 0) stdout_writer.writeByte('\n') catch return client.ClientError.H3Error;
            printPlainResponseWithId(stdout_writer, response, parsed.output_body, idx) catch return client.ClientError.H3Error;
        }
    }

    if (parsed.json) {
        stdout_writer.writeAll("]\n") catch return client.ClientError.H3Error;
    }
}

const FileStream = struct {
    file: std.fs.File,
    done: bool = false,
    chunk_size: usize = 16 * 1024,

    fn next(ctx: ?*anyopaque, allocator: std.mem.Allocator) client.ClientError!client.BodyChunkResult {
        const self: *FileStream = @ptrCast(@alignCast(ctx.?));
        if (self.done) return client.BodyChunkResult.finished;

        var buffer = allocator.alloc(u8, self.chunk_size) catch {
            return client.ClientError.H3Error;
        };
        const read = self.file.read(buffer) catch {
            allocator.free(buffer);
            return client.ClientError.H3Error;
        };

        if (read == 0) {
            allocator.free(buffer);
            self.done = true;
            return client.BodyChunkResult.finished;
        }

        if (read < buffer.len) {
            buffer = buffer[0..read];
        }
        return client.BodyChunkResult{ .chunk = buffer };
    }
};

fn parseHeaders(allocator: std.mem.Allocator, header_str: []const u8) ![]client.HeaderPair {
    var list = std.ArrayListUnmanaged(client.HeaderPair){};
    defer list.deinit(allocator);
    errdefer {
        for (list.items) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
    }

    var it = std.mem.tokenizeAny(u8, header_str, ",\n");
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const colon_index = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, entry[0..colon_index], " \t");
        const value = std.mem.trim(u8, entry[(colon_index + 1)..], " \t");
        if (name.len == 0) return error.InvalidHeader;
        const name_dup = try allocator.dupe(u8, name);
        errdefer allocator.free(name_dup);
        const value_dup = try allocator.dupe(u8, value);
        errdefer allocator.free(value_dup);
        try list.append(allocator, .{ .name = name_dup, .value = value_dup });
    }

    const owned = try list.toOwnedSlice(allocator);
    errdefer {
        for (owned) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        allocator.free(owned);
    }
    return owned;
}

fn buildPath(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);

    if (uri.path.isEmpty()) {
        try writer.writeByte('/');
    } else {
        try std.fmt.format(&writer, "{f}", .{std.fmt.alt(uri.path, .formatEscaped)});
    }

    if (uri.query) |query_component| {
        try writer.writeByte('?');
        try std.fmt.format(&writer, "{f}", .{std.fmt.alt(query_component, .formatEscaped)});
    }

    return buffer.toOwnedSlice(allocator);
}

fn componentToOwnedSlice(allocator: std.mem.Allocator, component: std.Uri.Component) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);
    try std.fmt.format(&writer, "{f}", .{std.fmt.alt(component, .formatEscaped)});
    return buffer.toOwnedSlice(allocator);
}
