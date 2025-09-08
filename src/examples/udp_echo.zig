const std = @import("std");
const EventLoop = @import("event_loop").EventLoop;
const IoCallback = @import("event_loop").IoCallback;
const TimerCallback = @import("event_loop").TimerCallback;
const SignalCallback = @import("event_loop").SignalCallback;
const udp = @import("udp");

const posix = std.posix;

const DEFAULT_PORT: u16 = 4433;

const EchoCtx = struct {
    fd: posix.socket_t,
    packets_echoed: *u64,
};

const TimerCtx = struct {
    loop: *EventLoop,
    last_count: *u64,
    total_count: *u64,
};

const SigCtx = struct {
    loop: *EventLoop,
    echo_ctx6: *EchoCtx,
    echo_ctx4: *EchoCtx,
};

fn on_udp_read(fd: posix.socket_t, _revents: u32, user: *anyopaque) void {
    _ = _revents;
    const ctx: *EchoCtx = @ptrCast(@alignCast(user));
    var buf: [1500]u8 = undefined; // Typical Ethernet MTU

    while (true) {
        var sa_storage: posix.sockaddr.storage = undefined;
        var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const n = posix.recvfrom(fd, buf[0..], 0, @ptrCast(&sa_storage), &sa_len) catch |err| switch (err) {
            error.WouldBlock => break,
            error.ConnectionResetByPeer, error.ConnectionRefused => break,
            else => {
                std.debug.print("recvfrom error: {s}\n", .{@errorName(err)});
                break;
            },
        };
        _ = posix.sendto(fd, buf[0..n], 0, @ptrCast(&sa_storage), sa_len) catch {};
        ctx.packets_echoed.* += 1;
    }
}

fn on_tick(user: *anyopaque) void {
    const tctx: *TimerCtx = @ptrCast(@alignCast(user));
    const total = tctx.total_count.*;
    const last = tctx.last_count.*;
    const delta = total - last;
    tctx.last_count.* = total;
    std.debug.print("[udp-echo] {d} packets/sec (total {d})\n", .{ delta, total });
}

fn on_signal(signum: c_int, user: *anyopaque) void {
    var sctx: *SigCtx = @ptrCast(@alignCast(user));
    const sig_name = if (signum == std.posix.SIG.INT) "SIGINT" else "SIGTERM";
    std.debug.print("\n{s} received, cleaning up...\n", .{sig_name});
    
    // Close sockets immediately to free the port
    if (sctx.echo_ctx6.fd >= 0) {
        posix.close(sctx.echo_ctx6.fd);
        sctx.echo_ctx6.fd = -1;
    }
    if (sctx.echo_ctx4.fd >= 0 and sctx.echo_ctx4.fd != sctx.echo_ctx6.fd) {
        posix.close(sctx.echo_ctx4.fd);
        sctx.echo_ctx4.fd = -1;
    }
    
    sctx.loop.stop();
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    
    // Heap-allocate shared counters
    const packets_echoed = try gpa.create(u64);
    defer gpa.destroy(packets_echoed);
    packets_echoed.* = 0;
    
    const last_count = try gpa.create(u64);
    defer gpa.destroy(last_count);
    last_count.* = 0;

    const loop = try EventLoop.initLibev(gpa);
    defer loop.deinit();

    std.debug.print("Starting UDP echo on port {d} (IPv6 dual-stack preferred)\n", .{ DEFAULT_PORT });

    // Allocate echo contexts first
    const echo_ctx6 = try gpa.create(EchoCtx);
    defer gpa.destroy(echo_ctx6);
    echo_ctx6.* = .{ .fd = -1, .packets_echoed = packets_echoed };
    
    const echo_ctx4 = try gpa.create(EchoCtx);
    defer gpa.destroy(echo_ctx4);
    echo_ctx4.* = .{ .fd = -1, .packets_echoed = packets_echoed };
    
    // Heap-allocate signal context with references to socket contexts
    const sig_ctx = try gpa.create(SigCtx);
    defer gpa.destroy(sig_ctx);
    sig_ctx.* = .{ .loop = loop, .echo_ctx6 = echo_ctx6, .echo_ctx4 = echo_ctx4 };
    
    // Register both SIGINT and SIGTERM handlers
    try loop.addSigint(on_signal, @as(*anyopaque, @ptrCast(sig_ctx)));
    try loop.addSigterm(on_signal, @as(*anyopaque, @ptrCast(sig_ctx)));

    // Use the new unified binding helper - much simpler!
    const sockets = udp.bindAny(DEFAULT_PORT, true);
    if (!sockets.hasAny()) return error.FailedToBindSocket;
    
    // Register IPv6 socket if bound
    if (sockets.v6) |sock6| {
        echo_ctx6.fd = sock6.fd;
        try loop.addUdpIo(sock6.fd, on_udp_read, @as(*anyopaque, @ptrCast(echo_ctx6)));
        std.debug.print("IPv6 [::]:{d} bound\n", .{ DEFAULT_PORT });
    }
    
    // Register IPv4 socket if bound
    if (sockets.v4) |sock4| {
        echo_ctx4.fd = sock4.fd;
        try loop.addUdpIo(sock4.fd, on_udp_read, @as(*anyopaque, @ptrCast(echo_ctx4)));
        std.debug.print("IPv4 0.0.0.0:{d} bound\n", .{ DEFAULT_PORT });
    }

    const tctx = try gpa.create(TimerCtx);
    defer gpa.destroy(tctx);
    tctx.* = .{ .loop = loop, .last_count = last_count, .total_count = packets_echoed };
    try loop.addTimer(1.0, 1.0, on_tick, @as(*anyopaque, @ptrCast(tctx)));

    std.debug.print("Send UDP packets with: nc -u localhost {d}\n", .{ DEFAULT_PORT });
    loop.run();

    // Cleanup file descriptors (if not already closed by signal handler)
    if (echo_ctx6.fd >= 0) {
        posix.close(echo_ctx6.fd);
        echo_ctx6.fd = -1;
    }
    if (echo_ctx4.fd >= 0 and echo_ctx4.fd != echo_ctx6.fd) {
        posix.close(echo_ctx4.fd);
        echo_ctx4.fd = -1;
    }
    std.debug.print("UDP echo stopped. Total packets echoed: {d}\n", .{ packets_echoed.* });
}
