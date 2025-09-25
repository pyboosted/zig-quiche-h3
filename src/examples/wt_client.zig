const std = @import("std");
const client = @import("client");

const ClientConfig = client.ClientConfig;
const QuicClient = client.QuicClient;
const WebTransportSession = client.webtransport.WebTransportSession;

const DEFAULT_WAIT_MS: u32 = 2_000;
const POLL_SLICE_MS: u32 = 50;

const CliError = error{
    MissingUrl,
    MissingUrlValue,
    UnknownArgument,
};

const CliOptions = struct {
    url: []const u8,
    quiet: bool,
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
        }
        std.process.exit(1);
    };

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 4433;
    var path: []const u8 = "/wt/echo";
    try parseUrl(cli.url, &host, &port, &path);

    const config = ClientConfig{
        .enable_webtransport = true,
        .enable_dgram = true,
        .dgram_recv_queue_len = 128,
        .dgram_send_queue_len = 128,
        .wt_max_outgoing_uni = 8,
        .wt_max_outgoing_bidi = 4,
        .wt_stream_recv_queue_len = 64,
        .wt_stream_recv_buffer_bytes = 512 * 1024,
    };

    var quic_client = try QuicClient.init(allocator, config);
    defer quic_client.deinit();

    const host_owned = try allocator.dupe(u8, host);
    defer allocator.free(host_owned);

    try quic_client.connect(.{ .host = host_owned, .port = port });

    const session = try quic_client.openWebTransport(path);
    const handshake = client.FetchHandle{ .client = quic_client, .stream_id = session.session_id };
    var fetch = try handshake.await();
    defer fetch.deinit(allocator);

    if (!cli.quiet) {
        std.debug.print("WebTransport session established!\n", .{});
        std.debug.print("Session ID: {d}\n", .{session.session_id});
    }

    const datagram_payload = "WebTransport datagram #0";
    try sendDatagramWithRetry(session, datagram_payload, cli.quiet);

    var recv_index: u32 = 0;
    var remaining_wait: u32 = DEFAULT_WAIT_MS;
    while (recv_index == 0 and remaining_wait > 0) {
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

    if (recv_index == 0) {
        std.debug.print("[client] timed out waiting for echoed datagram\n", .{});
        std.process.exit(1);
    }

    if (!cli.quiet) {
        std.debug.print("WebTransport test complete!\n", .{});
    }
}

fn sendDatagramWithRetry(session: *WebTransportSession, payload: []const u8, quiet: bool) !void {
    while (true) {
        session.sendDatagram(payload) catch |err| switch (err) {
            error.WouldBlock => {
                pumpClient(session.client, 10);
                continue;
            },
            else => return err,
        };
        if (!quiet) {
            std.debug.print("Sent: WebTransport datagram #0\n", .{});
        }
        break;
    }
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
            std.debug.print("Received echo: WebTransport datagram #{d}\n", .{recv_index.*});
        }
        recv_index.* += 1;
        allocator.free(payload);
    }
}

fn parseCli(argv: []const [:0]u8) CliError!CliOptions {
    var url_value: []const u8 = "";
    var quiet = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.sliceTo(argv[i], 0);
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--url=")) {
            url_value = arg[6..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--url")) {
            if (i + 1 >= argv.len) return CliError.MissingUrlValue;
            url_value = std.mem.sliceTo(argv[i + 1], 0);
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
        if (url_value.len == 0) {
            url_value = arg;
            continue;
        }
        return CliError.UnknownArgument;
    }

    if (url_value.len == 0) return CliError.MissingUrl;
    return CliOptions{ .url = url_value, .quiet = quiet };
}

fn printUsage(program_name: [:0]const u8) void {
    const name = std.mem.sliceTo(program_name, 0);
    std.debug.print("Usage: {s} [options] <url>\n\n", .{name});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --url <value>          WebTransport URL (https://host:port/path)\n", .{});
    std.debug.print("  -q, --quiet            Reduce log output\n", .{});
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
