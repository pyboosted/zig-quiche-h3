const std = @import("std");
const client = @import("client");

const ClientConfig = client.ClientConfig;
const QuicClient = client.QuicClient;
const WebTransportSession = client.webtransport.WebTransportSession;

const DEFAULT_WAIT_MS: u32 = 2_000;
const POLL_SLICE_MS: u32 = 50;
const STREAM_DEFAULT_CHUNK: usize = 64 * 1024;
const STREAM_SEND_BATCH_MAX: usize = 64 * 1024;
const STREAM_SEND_BATCH_MIN: usize = 8 * 1024;
const STREAM_RECV_TIMEOUT_MS: i64 = 30_000;
const STREAM_SEND_SLEEP_MS: u32 = 10;
const STREAM_SEND_PUMP_THRESHOLD: usize = 4;
const CLIENT_CONNECT_TIMEOUT_MS: u64 = 5_000;
const CLIENT_REQUEST_TIMEOUT_MS: u64 = 5_000;

const CliError = error{
    MissingUrl,
    MissingUrlValue,
    UnknownArgument,
    InvalidNumber,
};

const CliOptions = struct {
    url: []const u8,
    quiet: bool = false,
    datagram_count: u32 = 1,
    payload_size: usize = 0,
    expect_close: bool = false,
    stream_bytes: usize = 0,
    stream_chunk: usize = 0,
    stream_delay_ms: u32 = 0,
};

const StreamEchoResult = struct {
    verified_bytes: usize,
    blocked: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parseCli(argv) catch |err| {
        switch (err) {
            CliError.MissingUrl, CliError.MissingUrlValue => {
                printUsage(argv[0]);
            },
            CliError.UnknownArgument => {
                std.debug.print("Error: Unknown argument\n\n", .{});
                printUsage(argv[0]);
            },
            CliError.InvalidNumber => {
                std.debug.print("Error: Invalid numeric value\n\n", .{});
                printUsage(argv[0]);
            },
        }
        std.process.exit(1);
    };

    std.debug.print(
        "[client] options: stream_bytes={d} stream_chunk={d} stream_delay_ms={d}\n",
        .{ cli.stream_bytes, cli.stream_chunk, cli.stream_delay_ms },
    );

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 4433;
    var path: []const u8 = "/wt/echo";
    try parseUrl(cli.url, &host, &port, &path);

    const config = ClientConfig{
        .connect_timeout_ms = CLIENT_CONNECT_TIMEOUT_MS,
        .request_timeout_ms = CLIENT_REQUEST_TIMEOUT_MS,
        .enable_webtransport = true,
        .enable_dgram = true,
        .dgram_recv_queue_len = 128,
        .dgram_send_queue_len = 128,
        .wt_max_outgoing_uni = 8,
        .wt_max_outgoing_bidi = 4,
        .wt_stream_recv_queue_len = 64,
        .wt_stream_recv_buffer_bytes = 512 * 1024,
        .qlog_dir = "qlogs/client",
    };

    var quic_client = try QuicClient.init(allocator, config);
    defer quic_client.deinit();

    const host_owned = try allocator.dupe(u8, host);
    defer allocator.free(host_owned);

    try quic_client.connect(.{ .host = host_owned, .port = port });

    const session = quic_client.openWebTransport(path) catch |err| {
        std.debug.print("[client] WebTransport connect failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const handshake = client.FetchHandle{ .client = quic_client, .stream_id = session.session_id };
    var fetch = handshake.await() catch |err| {
        std.debug.print("[client] WebTransport handshake failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer fetch.deinit(allocator);

    if (!cli.quiet) {
        std.debug.print("WebTransport session established!\n", .{});
        std.debug.print("Session ID: {d}\n", .{session.session_id});
    }

    if (cli.expect_close) {
        var remaining: i64 = DEFAULT_WAIT_MS * 5;
        while (remaining > 0 and session.state != .closed) {
            const slice: u32 = if (remaining >= POLL_SLICE_MS) POLL_SLICE_MS else @intCast(remaining);
            pumpClient(quic_client, slice);
            remaining -= @intCast(slice);
        }
        if (session.state != .closed) {
            std.debug.print("[client] session did not close within timeout\n", .{});
            std.process.exit(1);
        }
        std.debug.print("[client] WebTransport session closed by peer\n", .{});
        return;
    }

    if (cli.stream_bytes > 0) {
        const result = runStreamEcho(allocator, quic_client, session, cli);
        std.debug.print(
            "[client] stream echo verified bytes={d} blocked={s}\n",
            .{ result.verified_bytes, if (result.blocked) "true" else "false" },
        );
        return;
    }

    if (cli.datagram_count == 0) {
        if (!cli.quiet) {
            std.debug.print("WebTransport session established (no datagrams requested)\n", .{});
        }
        return;
    }

    var send_index: u32 = 0;
    while (send_index < cli.datagram_count) : (send_index += 1) {
        {
            const payload = try buildPayload(allocator, cli, send_index);
            defer allocator.free(payload);
            try sendDatagramWithRetry(session, payload, cli.quiet, send_index);
        }
    }

    var recv_index: u32 = 0;
    const effective_count: u32 = if (cli.datagram_count == 0) 1 else cli.datagram_count;
    const multiplier: u32 = if (effective_count > 3) 3 else effective_count;
    var remaining_wait: u32 = DEFAULT_WAIT_MS * multiplier;
    while (recv_index < cli.datagram_count and remaining_wait > 0) {
        const slice = if (remaining_wait >= POLL_SLICE_MS) POLL_SLICE_MS else remaining_wait;
        pumpClient(quic_client, slice);
        if (session.state == .closed) break;
        drainSession(session, &recv_index, cli.quiet);
        if (slice >= remaining_wait) {
            remaining_wait = 0;
        } else {
            remaining_wait -= slice;
        }
    }

    if (recv_index < cli.datagram_count) {
        std.debug.print(
            "[client] timed out waiting for echoed datagram(s); received {d}/{d}\n",
            .{ recv_index, cli.datagram_count },
        );
        std.process.exit(1);
    }

    if (!cli.quiet) {
        std.debug.print("WebTransport test complete!\n", .{});
    }
}

fn sendDatagramWithRetry(
    session: *WebTransportSession,
    payload: []const u8,
    quiet: bool,
    index: u32,
) !void {
    while (true) {
        session.sendDatagram(payload) catch |err| switch (err) {
            error.WouldBlock => {
                pumpClient(session.client, 10);
                continue;
            },
            else => return err,
        };
        if (!quiet) {
            std.debug.print(
                "Sent: WebTransport datagram #{d} (len={d})\n",
                .{ index, payload.len },
            );
        }
        break;
    }
}

fn buildPayload(allocator: std.mem.Allocator, opts: CliOptions, index: u32) ![]u8 {
    if (opts.payload_size == 0) {
        return std.fmt.allocPrint(allocator, "WebTransport datagram #{d}", .{index});
    }

    const payload = try allocator.alloc(u8, opts.payload_size);
    for (payload, 0..) |*byte, i| {
        const ch: u8 = @intCast('A' + @as(u8, @intCast((i + index) % 26)));
        byte.* = ch;
    }
    return payload;
}

fn pumpClient(qc: *QuicClient, duration_ms: u32) void {
    if (duration_ms == 0) return;
    const deadline = std.time.milliTimestamp() + @as(i64, duration_ms);
    while (std.time.milliTimestamp() < deadline) {
        qc.event_loop.poll();
        qc.afterQuicProgress();
    }
}

fn drainSession(session: *WebTransportSession, recv_index: *u32, quiet: bool) void {
    if (session.state == .closed) return;
    const allocator = session.client.allocator;
    while (session.receiveDatagram()) |payload| {
        if (!quiet) {
            std.debug.print(
                "Received echo: WebTransport datagram #{d} (len={d})\n",
                .{ recv_index.*, payload.len },
            );
        }
        recv_index.* += 1;
        allocator.free(payload);
    }
}

fn runStreamEcho(
    allocator: std.mem.Allocator,
    quic_client: *QuicClient,
    session: *WebTransportSession,
    opts: CliOptions,
) StreamEchoResult {
    var chunk_size = if (opts.stream_chunk > 0) opts.stream_chunk else STREAM_DEFAULT_CHUNK;
    if (opts.stream_bytes > 0 and chunk_size > opts.stream_bytes) {
        chunk_size = opts.stream_bytes;
    }
    if (chunk_size == 0) {
        chunk_size = 1;
    }

    const stream = session.openBidiStream() catch |err| {
        std.debug.print("[client] failed to open WT bidi stream: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer stream.destroy();
    if (!opts.quiet) {
        std.debug.print("[client] opened bidi stream id={d}\n", .{stream.stream_id});
    }

    const send_buf = allocator.alloc(u8, chunk_size) catch {
        std.debug.print("[client] failed to allocate send buffer ({d} bytes)\n", .{chunk_size});
        std.process.exit(1);
    };
    defer allocator.free(send_buf);

    const verify_buf = allocator.alloc(u8, chunk_size) catch {
        std.debug.print("[client] failed to allocate verify buffer ({d} bytes)\n", .{chunk_size});
        std.process.exit(1);
    };
    defer allocator.free(verify_buf);

    var total_sent: usize = 0;
    var verified_offset: usize = 0;
    var blocked = false;
    var fin_seen = false;

    while (total_sent < opts.stream_bytes) {
        const remaining = opts.stream_bytes - total_sent;
        const to_send = if (remaining < chunk_size) remaining else chunk_size;
        fillPattern(send_buf[0..to_send], total_sent);

        var chunk_offset: usize = 0;
        var batch_limit = if (to_send < STREAM_SEND_BATCH_MAX) to_send else STREAM_SEND_BATCH_MAX;
        var writes_since_pump: usize = 0;
        while (chunk_offset < to_send) {
            const remaining_chunk = to_send - chunk_offset;
            if (batch_limit > remaining_chunk) batch_limit = remaining_chunk;
            const batch_len = batch_limit;
            const slice = send_buf[chunk_offset .. chunk_offset + batch_len];
            const written = stream.send(slice, false) catch |err| switch (err) {
                client.ClientError.StreamBlocked => {
                    blocked = true;
                    pumpClient(quic_client, STREAM_SEND_SLEEP_MS);
                    writes_since_pump = 0;
                    drainStreamEcho(stream, &verified_offset, opts.stream_bytes, verify_buf);
                    if (stream.isFinished()) fin_seen = true;
                    if (!opts.quiet) {
                        std.debug.print(
                            "[client] stream blocked while sending chunk offset={d} remaining={d}\n",
                            .{ total_sent + chunk_offset, to_send - chunk_offset },
                        );
                    }
                    if (batch_limit > STREAM_SEND_BATCH_MIN) {
                        batch_limit = batch_limit / 2;
                        if (batch_limit < STREAM_SEND_BATCH_MIN) batch_limit = STREAM_SEND_BATCH_MIN;
                    }
                    continue;
                },
                else => {
                    std.debug.print("[client] stream send error: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                },
            };
            chunk_offset += written;
            writes_since_pump += 1;
            if (!opts.quiet) {
                std.debug.print(
                    "[client] sent {d} bytes (chunk offset now {d} of {d})\n",
                    .{ written, chunk_offset, to_send },
                );
            }
            if (written < batch_len) {
                blocked = true;
            }
            if (written == batch_limit and batch_limit < STREAM_SEND_BATCH_MAX) {
                const new_remaining = to_send - chunk_offset;
                var new_limit = batch_limit * 2;
                if (new_limit > STREAM_SEND_BATCH_MAX) new_limit = STREAM_SEND_BATCH_MAX;
                if (new_limit > new_remaining) new_limit = new_remaining;
                if (new_limit > 0) batch_limit = new_limit;
            }
            if (writes_since_pump >= STREAM_SEND_PUMP_THRESHOLD) {
                pumpClient(quic_client, STREAM_SEND_SLEEP_MS);
                writes_since_pump = 0;
                drainStreamEcho(stream, &verified_offset, opts.stream_bytes, verify_buf);
                if (stream.isFinished()) fin_seen = true;
            }
        }

        total_sent += to_send;
        if (!opts.quiet) {
            std.debug.print("[client] total sent {d} of {d}\n", .{ total_sent, opts.stream_bytes });
        }

        if (opts.stream_delay_ms > 0) {
            std.Thread.sleep(@as(u64, opts.stream_delay_ms) * std.time.ns_per_ms);
        }

        pumpClient(quic_client, STREAM_SEND_SLEEP_MS);
        drainStreamEcho(stream, &verified_offset, opts.stream_bytes, verify_buf);
        if (stream.isFinished()) fin_seen = true;
    }

    sendStreamFin(stream, quic_client, &blocked);
    if (!opts.quiet) {
        std.debug.print("[client] sent FIN\n", .{});
    }
    pumpClient(quic_client, STREAM_SEND_SLEEP_MS);
    drainStreamEcho(stream, &verified_offset, opts.stream_bytes, verify_buf);
    if (stream.isFinished()) fin_seen = true;

    const extra_wait_ms: i64 = @as(i64, opts.stream_delay_ms) * 4;
    const deadline = std.time.milliTimestamp() + STREAM_RECV_TIMEOUT_MS + extra_wait_ms;
    while ((verified_offset < opts.stream_bytes or !fin_seen) and std.time.milliTimestamp() < deadline) {
        pumpClient(quic_client, POLL_SLICE_MS);
        drainStreamEcho(stream, &verified_offset, opts.stream_bytes, verify_buf);
        if (stream.isFinished()) fin_seen = true;
    }

    if (verified_offset != opts.stream_bytes) {
        std.debug.print(
            "[client] stream echo incomplete: received {d} of {d} bytes\n",
            .{ verified_offset, opts.stream_bytes },
        );
        std.process.exit(1);
    }

    if (!fin_seen) {
        std.debug.print("[client] stream echo timed out waiting for FIN\n", .{});
        std.process.exit(1);
    }

    return .{ .verified_bytes = verified_offset, .blocked = blocked };
}

fn sendStreamFin(stream: *client.webtransport.WebTransportSession.Stream, quic_client: *QuicClient, blocked: *bool) void {
    while (true) {
        const result = stream.send(&.{}, true) catch |err| switch (err) {
            client.ClientError.StreamBlocked => {
                blocked.* = true;
                pumpClient(quic_client, STREAM_SEND_SLEEP_MS);
                continue;
            },
            else => {
                std.debug.print("[client] stream FIN send error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            },
        };
        _ = result;
        break;
    }
}

fn drainStreamEcho(
    stream: *client.webtransport.WebTransportSession.Stream,
    verified_offset: *usize,
    expected_total: usize,
    verify_buf: []u8,
) void {
    while (stream.receive()) |payload| {
        defer stream.freeReceived(payload);
        if (verified_offset.* + payload.len > expected_total) {
            std.debug.print(
                "[client] stream echo exceeded expected bytes: have {d}, expected {d}\n",
                .{ verified_offset.* + payload.len, expected_total },
            );
            std.process.exit(1);
        }
        fillPattern(verify_buf[0..payload.len], verified_offset.*);
        if (!std.mem.eql(u8, payload, verify_buf[0..payload.len])) {
            std.debug.print(
                "[client] stream echo mismatch at offset {d}\n",
                .{verified_offset.*},
            );
            std.process.exit(1);
        }
        verified_offset.* += payload.len;
    }
}

fn fillPattern(buf: []u8, start: usize) void {
    for (buf, 0..) |*byte, idx| {
        byte.* = patternByte(start + idx);
    }
}

fn patternByte(pos: usize) u8 {
    return @intCast((pos % 251) + 1);
}

fn parseCli(argv: []const [:0]u8) CliError!CliOptions {
    var opts = CliOptions{ .url = "" };

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.sliceTo(argv[i], 0);

        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            opts.quiet = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--count")) {
            if (i + 1 >= argv.len) return CliError.MissingUrlValue;
            const value = std.mem.sliceTo(argv[i + 1], 0);
            opts.datagram_count = std.fmt.parseInt(u32, value, 10) catch return CliError.InvalidNumber;
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--count=")) {
            const value = arg[8..];
            opts.datagram_count = std.fmt.parseInt(u32, value, 10) catch return CliError.InvalidNumber;
            continue;
        }

        if (std.mem.eql(u8, arg, "--payload-size")) {
            if (i + 1 >= argv.len) return CliError.MissingUrlValue;
            const value = std.mem.sliceTo(argv[i + 1], 0);
            opts.payload_size = std.fmt.parseInt(usize, value, 10) catch return CliError.InvalidNumber;
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--payload-size=")) {
            const value = arg[15..];
            opts.payload_size = std.fmt.parseInt(usize, value, 10) catch return CliError.InvalidNumber;
            continue;
        }

        if (std.mem.eql(u8, arg, "--stream-bytes")) {
            if (i + 1 >= argv.len) return CliError.MissingUrlValue;
            const value = std.mem.sliceTo(argv[i + 1], 0);
            opts.stream_bytes = std.fmt.parseInt(usize, value, 10) catch return CliError.InvalidNumber;
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--stream-bytes=")) {
            const value = arg[15..];
            opts.stream_bytes = std.fmt.parseInt(usize, value, 10) catch return CliError.InvalidNumber;
            continue;
        }

        if (std.mem.eql(u8, arg, "--stream-chunk")) {
            if (i + 1 >= argv.len) return CliError.MissingUrlValue;
            const value = std.mem.sliceTo(argv[i + 1], 0);
            opts.stream_chunk = std.fmt.parseInt(usize, value, 10) catch return CliError.InvalidNumber;
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--stream-chunk=")) {
            const value = arg[15..];
            opts.stream_chunk = std.fmt.parseInt(usize, value, 10) catch return CliError.InvalidNumber;
            continue;
        }

        if (std.mem.eql(u8, arg, "--stream-delay")) {
            if (i + 1 >= argv.len) return CliError.MissingUrlValue;
            const value = std.mem.sliceTo(argv[i + 1], 0);
            opts.stream_delay_ms = std.fmt.parseInt(u32, value, 10) catch return CliError.InvalidNumber;
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--stream-delay=")) {
            const value = arg[15..];
            opts.stream_delay_ms = std.fmt.parseInt(u32, value, 10) catch return CliError.InvalidNumber;
            continue;
        }

        if (std.mem.eql(u8, arg, "--expect-close")) {
            opts.expect_close = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--url=")) {
            opts.url = arg[6..];
            continue;
        }

        if (std.mem.eql(u8, arg, "--url")) {
            if (i + 1 >= argv.len) return CliError.MissingUrlValue;
            opts.url = std.mem.sliceTo(argv[i + 1], 0);
            i += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(argv[0]);
            std.process.exit(0);
        }

        if (arg.len > 0 and arg[0] == '-') {
            return CliError.UnknownArgument;
        }

        if (opts.url.len == 0) {
            opts.url = arg;
            continue;
        }

        return CliError.UnknownArgument;
    }

    if (opts.url.len == 0) return CliError.MissingUrl;
    return opts;
}

fn printUsage(program_name: [:0]const u8) void {
    const name = std.mem.sliceTo(program_name, 0);
    std.debug.print("Usage: {s} [options] <url>\n\n", .{name});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --url <value>          WebTransport URL (https://host:port/path)\n", .{});
    std.debug.print("  -q, --quiet            Reduce log output\n", .{});
    std.debug.print("  --count <n>            Number of datagrams to send (default: 1)\n", .{});
    std.debug.print("  --payload-size <n>     Override datagram payload size in bytes\n", .{});
    std.debug.print("  --stream-bytes <n>     Send and verify WebTransport stream echo\n", .{});
    std.debug.print("  --stream-chunk <n>     Chunk size for stream sends (default 64KiB)\n", .{});
    std.debug.print("  --stream-delay <ms>    Delay between stream chunks in milliseconds\n", .{});
    std.debug.print("  --expect-close         Treat peer-initiated close as success\n", .{});
}

fn parseUrl(url: []const u8, host_out: *[]const u8, port_out: *u16, path_out: *[]const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    const remainder = url[8..];
    const slash_index = (std.mem.indexOfScalar(u8, remainder, '/')) orelse return error.InvalidUrl;
    const authority = remainder[0..slash_index];
    const path = remainder[slash_index..];
    if (authority.len == 0 or path.len == 0) return error.InvalidUrl;

    if ((std.mem.indexOfScalar(u8, authority, ':'))) |colon| {
        const host = authority[0..colon];
        const port_str = authority[colon + 1 ..];
        if (port_str.len == 0) return error.InvalidUrl;
        const port_value = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidUrl;
        host_out.* = host;
        port_out.* = port_value;
    } else {
        host_out.* = authority;
        port_out.* = 443;
    }
    path_out.* = path;
}
