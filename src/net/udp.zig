const std = @import("std");

pub const UdpSocket = struct {
    fd: std.posix.socket_t,
};

pub fn setNonBlocking(fd: std.posix.socket_t, enable: bool) !void {
    const posix = std.posix;
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    // Use portable O_NONBLOCK bit position (0x0004 on Darwin, 0x0800 on Linux)
    const O_NONBLOCK = @as(@TypeOf(flags), 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    const new_flags = if (enable) flags | O_NONBLOCK else flags & ~O_NONBLOCK;
    _ = try posix.fcntl(fd, posix.F.SETFL, new_flags);
}

pub fn setReuseAddr(fd: std.posix.socket_t, enable: bool) !void {
    const posix = std.posix;
    var one: c_int = if (enable) 1 else 0;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));
}

pub fn setIpv6Only(fd: std.posix.socket_t, v6only: bool) void {
    const posix = std.posix;
    var val: c_int = if (v6only) 1 else 0;
    // Best-effort: some platforms don’t expose IPV6_V6ONLY or ignore it.
    if (@hasDecl(posix, "IPV6_V6ONLY")) {
        _ = posix.setsockopt(fd, posix.IPPROTO.IPV6, posix.IPV6_V6ONLY, std.mem.asBytes(&val)) catch {};
    }
}

pub fn bindUdp4Any(port: u16, nonblock: bool) !UdpSocket {
    const posix = std.posix;
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

pub fn bindUdp6AnyDual(port: u16, nonblock: bool) !UdpSocket {
    const posix = std.posix;
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

pub fn close(self: *UdpSocket) void {
    // Best-effort close; ignore errors.
    // Set fd to -1 to prevent double-close if struct is copied
    if (self.fd >= 0) {
        std.posix.close(self.fd);
        self.fd = -1;
    }
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
    const posix = std.posix;
    if (@hasDecl(posix.SO, "REUSEPORT")) {
        var one: c_int = if (enable) 1 else 0;
        _ = posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&one)) catch {};
    }
}

// Socket buffer tuning helpers for high-throughput scenarios
pub fn setRecvBufferSize(fd: std.posix.socket_t, size: u32) !void {
    const posix = std.posix;
    const size_bytes = std.mem.asBytes(&size);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, size_bytes);
}

pub fn setSendBufferSize(fd: std.posix.socket_t, size: u32) !void {
    const posix = std.posix;
    const size_bytes = std.mem.asBytes(&size);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, size_bytes);
}

// Enable broadcast for UDP (useful for discovery protocols)
pub fn setBroadcast(fd: std.posix.socket_t, enable: bool) !void {
    const posix = std.posix;
    var val: c_int = if (enable) 1 else 0;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&val));
}
