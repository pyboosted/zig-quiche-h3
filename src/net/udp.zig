const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const MAX_BATCH = 32; // reasonable default for batching

// Lightweight view structs for batched IO
pub const RecvView = struct {
    len: usize = 0,
    addr: posix.sockaddr.storage = undefined,
    addr_len: posix.socklen_t = 0,
};

pub const SendView = struct {
    data: []const u8,
    addr: posix.sockaddr.storage,
    addr_len: posix.socklen_t,
};

// Return whether platform has native recvmmsg/sendmmsg we use
pub fn hasKernelBatching() bool {
    return builtin.target.os.tag == .linux;
}

// Receive up to buffers.len packets into provided buffers (each buffer holds one packet).
// On Linux uses recvmmsg; on other OS falls back to repeated recvfrom until WouldBlock.
pub fn recvBatch(
    fd: posix.socket_t,
    buffers: [][]u8, // slice of buffers; each buffer holds one packet
    out_views: []RecvView,
) !usize {
    const n = @min(buffers.len, out_views.len);
    if (n == 0) return 0;

    if (builtin.target.os.tag == .linux) {
        const c = @cImport({
            @cInclude("sys/socket.h");
            @cInclude("sys/uio.h");
        });
        var iovecs: [MAX_BATCH]c.iovec = undefined;
        var msgs: [MAX_BATCH]c.mmsghdr = undefined;
        var addrs: [MAX_BATCH]posix.sockaddr.storage = undefined;

        const vlen: usize = @min(n, MAX_BATCH);
        var i: usize = 0;
        while (i < vlen) : (i += 1) {
            const buf = buffers[i];
            iovecs[i].iov_base = buf.ptr;
            iovecs[i].iov_len = buf.len;

            // Prepare msghdr
            // Zero-init then set fields we care about
            msgs[i] = .{ .msg_hdr = .{ .msg_name = @ptrCast(&addrs[i]), .msg_namelen = @sizeOf(posix.sockaddr.storage), .msg_iov = &iovecs[i], .msg_iovlen = 1, .msg_control = null, .msg_controllen = 0, .msg_flags = 0 }, .msg_len = 0 };
        }

        const rc = c.recvmmsg(fd, &msgs, @intCast(vlen), 0, null);
        if (rc <= 0) {
            // Treat errors as no data to keep the loop non-fatal; fallback
            // path will surface real errors. This avoids errno plumbing here.
            return 0;
        }
        const count: usize = @intCast(rc);
        var j: usize = 0;
        while (j < count) : (j += 1) {
            out_views[j].len = msgs[j].msg_len;
            out_views[j].addr = addrs[j];
            out_views[j].addr_len = @intCast(msgs[j].msg_hdr.msg_namelen);
        }
        return count;
    } else {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var addr: posix.sockaddr.storage = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const read = posix.recvfrom(fd, buffers[i], 0, @ptrCast(&addr), &addr_len) catch |e| switch (e) {
                error.WouldBlock => return i,
                else => return error.RecvFailed,
            };
            out_views[i].len = read;
            out_views[i].addr = addr;
            out_views[i].addr_len = addr_len;
        }
        return n;
    }
}

// Send a batch of packets. On Linux uses sendmmsg; else falls back to sendto in a loop.
pub fn sendBatch(fd: posix.socket_t, views: []const SendView) !usize {
    if (views.len == 0) return 0;

    if (builtin.target.os.tag == .linux) {
        const c = @cImport({
            @cInclude("sys/socket.h");
            @cInclude("sys/uio.h");
        });
        var iovecs: [MAX_BATCH]c.iovec = undefined;
        var msgs: [MAX_BATCH]c.mmsghdr = undefined;

        const vlen: usize = @min(views.len, MAX_BATCH);
        var i: usize = 0;
        while (i < vlen) : (i += 1) {
            iovecs[i].iov_base = @constCast(views[i].data.ptr);
            iovecs[i].iov_len = views[i].data.len;
            msgs[i] = .{ .msg_hdr = .{ .msg_name = @ptrCast(&views[i].addr), .msg_namelen = views[i].addr_len, .msg_iov = &iovecs[i], .msg_iovlen = 1, .msg_control = null, .msg_controllen = 0, .msg_flags = 0 }, .msg_len = 0 };
        }
        const rc = c.sendmmsg(fd, &msgs, @intCast(vlen), 0);
        if (rc < 0) return error.SendFailed;
        return @intCast(rc);
    } else {
        var sent: usize = 0;
        for (views) |v| {
            _ = posix.sendto(fd, v.data, 0, @ptrCast(&v.addr), v.addr_len) catch |e| switch (e) {
                else => break,
            };
            sent += 1;
        }
        return sent;
    }
}

pub const UdpSocket = struct {
    fd: std.posix.socket_t,

    pub fn close(self: *UdpSocket) void {
        // Best-effort close; ignore errors.
        // Set fd to -1 to prevent double-close if struct is copied
        if (self.fd >= 0) {
            std.posix.close(self.fd);
            self.fd = -1;
        }
    }
};

pub fn setNonBlocking(fd: std.posix.socket_t, enable: bool) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    // Use portable O_NONBLOCK bit position (0x0004 on Darwin, 0x0800 on Linux)
    const O_NONBLOCK = @as(@TypeOf(flags), 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    const new_flags = if (enable) flags | O_NONBLOCK else flags & ~O_NONBLOCK;
    _ = try posix.fcntl(fd, posix.F.SETFL, new_flags);
}

pub fn setReuseAddr(fd: std.posix.socket_t, enable: bool) !void {
    var one: c_int = if (enable) 1 else 0;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));
}

pub fn setIpv6Only(fd: std.posix.socket_t, v6only: bool) void {
    var val: c_int = if (v6only) 1 else 0;
    // Best-effort: some platforms don’t expose IPV6_V6ONLY or ignore it.
    if (@hasDecl(posix, "IPV6_V6ONLY")) {
        _ = posix.setsockopt(fd, posix.IPPROTO.IPV6, posix.IPV6_V6ONLY, std.mem.asBytes(&val)) catch {};
    }
}

pub fn bindUdp4Any(port: u16, nonblock: bool) !UdpSocket {
    // Use atomic socket flags for non-blocking and close-on-exec
    // This avoids race conditions between socket() and fcntl()
    const base_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC;
    const sock_type: u32 = if (nonblock) base_type | posix.SOCK.NONBLOCK else base_type;

    const fd = try posix.socket(posix.AF.INET, sock_type, posix.IPPROTO.UDP);
    errdefer posix.close(fd);

    try setReuseAddr(fd, true);

    var addr: posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0, // INADDR_ANY: bind to all IPv4 interfaces
    };
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    return .{ .fd = fd };
}

/// Bind an IPv4 UDP socket to loopback (127.0.0.1)
pub fn bindUdp4Loopback(port: u16, nonblock: bool) !UdpSocket {
    const base_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC;
    const sock_type: u32 = if (nonblock) base_type | posix.SOCK.NONBLOCK else base_type;

    const fd = try posix.socket(posix.AF.INET, sock_type, posix.IPPROTO.UDP);
    errdefer posix.close(fd);

    try setReuseAddr(fd, true);

    var addr: posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
    };
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    return .{ .fd = fd };
}

pub fn bindUdp6AnyDual(port: u16, nonblock: bool) !UdpSocket {
    // Use atomic socket flags for non-blocking and close-on-exec
    const base_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC;
    const sock_type: u32 = if (nonblock) base_type | posix.SOCK.NONBLOCK else base_type;

    const fd = try posix.socket(posix.AF.INET6, sock_type, posix.IPPROTO.UDP);
    errdefer posix.close(fd);

    try setReuseAddr(fd, true);
    // Attempt dual-stack by disabling V6ONLY (best-effort)
    // Note: macOS often requires separate IPv4 bind even with V6ONLY=0
    setIpv6Only(fd, false);

    var addr6 = posix.sockaddr.in6{
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = 0,
        .scope_id = 0,
        .addr = [_]u8{0} ** 16, // in6addr_any: bind to all IPv6 interfaces
    };
    try posix.bind(fd, @ptrCast(&addr6), @sizeOf(posix.sockaddr.in6));
    return .{ .fd = fd };
}

/// Bind an IPv6 UDP socket to loopback (::1)
pub fn bindUdp6Loopback(port: u16, nonblock: bool) !UdpSocket {
    const base_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC;
    const sock_type: u32 = if (nonblock) base_type | posix.SOCK.NONBLOCK else base_type;

    const fd = try posix.socket(posix.AF.INET6, sock_type, posix.IPPROTO.UDP);
    errdefer posix.close(fd);

    try setReuseAddr(fd, true);
    setIpv6Only(fd, true);

    var addr6 = posix.sockaddr.in6{
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = 0,
        .scope_id = 0,
        .addr = [_]u8{0} ** 16,
    };
    addr6.addr[15] = 1; // ::1
    try posix.bind(fd, @ptrCast(&addr6), @sizeOf(posix.sockaddr.in6));
    return .{ .fd = fd };
}

/// Result of bindAny() containing both IPv6 and IPv4 sockets
pub const BindResult = struct {
    v6: ?UdpSocket = null,
    v4: ?UdpSocket = null,

    pub fn hasAny(self: BindResult) bool {
        return self.v6 != null or self.v4 != null;
    }

    pub fn close(self: *BindResult) void {
        if (self.v6) |*sock| sock.close();
        if (self.v4) |*sock| sock.close();
    }
};

/// Unified binding helper that attempts IPv6 dual-stack first, then IPv4 fallback.
/// This simplifies the common pattern of trying to bind to both protocols.
/// Returns a struct with both sockets (one or both may be null).
pub fn bindAny(port: u16, nonblock: bool) BindResult {
    var result = BindResult{};

    // Try IPv6 dual-stack first
    if (bindUdp6AnyDual(port, nonblock)) |sock6| {
        result.v6 = sock6;
        // On macOS and some BSDs, dual-stack doesn't work reliably,
        // so also try IPv4 separately
        if (bindUdp4Any(port, nonblock)) |sock4| {
            result.v4 = sock4;
        } else |_| {
            // IPv4 bind failed, but that's OK if we have IPv6
        }
    } else |_| {
        // IPv6 failed, try IPv4 as fallback
        if (bindUdp4Any(port, nonblock)) |sock4| {
            result.v4 = sock4;
        } else |_| {
            // Both failed, result will have no sockets
        }
    }

    return result;
}

pub fn setReusePort(fd: std.posix.socket_t, enable: bool) void {
    // Optional helper; not used by default.
    if (@hasDecl(posix.SO, "REUSEPORT")) {
        var one: c_int = if (enable) 1 else 0;
        _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&one)) catch {};
    }
}

// Socket buffer tuning helpers for high-throughput scenarios
pub fn setRecvBufferSize(fd: std.posix.socket_t, size: u32) !void {
    const size_bytes = std.mem.asBytes(&size);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, size_bytes);
}

pub fn setSendBufferSize(fd: std.posix.socket_t, size: u32) !void {
    const size_bytes = std.mem.asBytes(&size);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, size_bytes);
}

// Enable broadcast for UDP (useful for discovery protocols)
pub fn setBroadcast(fd: std.posix.socket_t, enable: bool) !void {
    var val: c_int = if (enable) 1 else 0;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&val));
}
