const std = @import("std");
const quiche = @import("quiche");

const c = quiche.c;

// Connection key for hash map - includes DCID and address family
pub const ConnectionKey = struct {
    dcid: [quiche.MAX_CONN_ID_LEN]u8,
    dcid_len: u8,
    family: std.posix.sa_family_t,
};

// Context for the hash map
pub const ConnectionKeyContext = struct {
    pub fn hash(_: ConnectionKeyContext, key: ConnectionKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.dcid[0..key.dcid_len]);
        hasher.update(std.mem.asBytes(&key.family));
        return hasher.final();
    }

    pub fn eql(_: ConnectionKeyContext, a: ConnectionKey, b: ConnectionKey) bool {
        if (a.dcid_len != b.dcid_len or a.family != b.family) return false;
        return std.mem.eql(u8, a.dcid[0..a.dcid_len], b.dcid[0..b.dcid_len]);
    }
};

// Timer handle from event loop (will be defined there)
pub const TimerHandle = opaque {};

// Connection state
pub const Connection = struct {
    // Core QUIC connection
    conn: quiche.Connection,

    // Addressing
    peer_addr: std.posix.sockaddr.storage,
    peer_addr_len: std.posix.socklen_t,
    local_port: u16,
    local_family: std.posix.sa_family_t,
    socket_fd: std.posix.socket_t, // Store the actual socket fd

    // Connection IDs
    scid: [16]u8, // Our generated SCID
    dcid: [quiche.MAX_CONN_ID_LEN]u8, // Peer's SCID (our DCID)
    dcid_len: u8,

    // State tracking
    timeout_deadline_ms: i64,
    timer_handle: ?*TimerHandle = null,
    handshake_logged: bool = false,

    // HTTP/3 connection (lazy-initialized)
    http3: ?*anyopaque = null, // Will be *h3.H3Connection, using anyopaque to avoid circular deps

    // Per-connection accounting
    active_requests: usize = 0,
    active_downloads: usize = 0,

    // Debug
    qlog_path: ?[]const u8 = null,

    // Next local-initiated stream IDs (server side):
    // server bidi starts at 1, server uni starts at 3
    next_local_bidi_stream_id: u64 = 1,
    next_local_uni_stream_id: u64 = 3,

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        // H3 connection cleanup happens in server's closeConnection() method
        // where the h3 module is available for proper type casting

        self.conn.deinit();
        if (self.qlog_path) |path| {
            // Free the full allocation including null terminator
            const full_path = path.ptr[0 .. path.len + 1];
            allocator.free(full_path);
        }
    }

    pub fn getKey(self: *const Connection) ConnectionKey {
        // Use our SCID as the key - this is the HMAC-derived ID we generated
        // The client will send this as their DCID in future packets, so we
        // can look up the connection by matching incoming DCID to our SCID
        var key_dcid: [quiche.MAX_CONN_ID_LEN]u8 = undefined;
        @memcpy(key_dcid[0..16], &self.scid);

        return .{
            .dcid = key_dcid,
            .dcid_len = 16,
            .family = @as(*const std.posix.sockaddr, @ptrCast(&self.peer_addr)).family,
        };
    }
};

// Connection table
pub const ConnectionTable = struct {
    allocator: std.mem.Allocator,
    map: std.hash_map.HashMap(ConnectionKey, *Connection, ConnectionKeyContext, 80),

    pub fn init(allocator: std.mem.Allocator) ConnectionTable {
        return .{
            .allocator = allocator,
            .map = std.hash_map.HashMap(ConnectionKey, *Connection, ConnectionKeyContext, 80).init(allocator),
        };
    }

    pub fn deinit(self: *ConnectionTable) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn put(self: *ConnectionTable, conn: *Connection) !void {
        const key = conn.getKey();
        try self.map.put(key, conn);
    }

    pub fn get(self: *ConnectionTable, key: ConnectionKey) ?*Connection {
        return self.map.get(key);
    }

    pub fn remove(self: *ConnectionTable, key: ConnectionKey) ?*Connection {
        if (self.map.fetchRemove(key)) |kv| {
            return kv.value;
        }
        return null;
    }

    pub fn count(self: *const ConnectionTable) usize {
        return self.map.count();
    }
};

// SCID generation - 16 bytes of random data
pub fn generateScid() [16]u8 {
    var scid: [16]u8 = undefined;
    std.crypto.random.bytes(&scid);
    return scid;
}

// Create a new connection
pub fn createConnection(
    allocator: std.mem.Allocator,
    q_conn: quiche.Connection,
    scid: [16]u8,
    dcid: []const u8,
    peer_addr: std.posix.sockaddr.storage,
    peer_addr_len: std.posix.socklen_t,
    local_port: u16,
    socket_fd: std.posix.socket_t,
    qlog_path: ?[]const u8,
) !*Connection {
    const conn = try allocator.create(Connection);
    errdefer allocator.destroy(conn);

    // Take ownership of qlog_path directly (already allocated by caller)

    conn.* = .{
        .conn = q_conn,
        .peer_addr = peer_addr,
        .peer_addr_len = peer_addr_len,
        .local_port = local_port,
        .local_family = switch (@as(*const std.posix.sockaddr, @ptrCast(&peer_addr)).family) {
            std.posix.AF.INET => std.posix.AF.INET,
            std.posix.AF.INET6 => std.posix.AF.INET6,
            else => return error.UnsupportedAddressFamily,
        },
        .socket_fd = socket_fd,
        .scid = scid,
        .dcid = undefined,
        .dcid_len = @intCast(dcid.len),
        .timeout_deadline_ms = 0,
        .qlog_path = qlog_path,
    };

    // Copy DCID
    if (dcid.len > quiche.MAX_CONN_ID_LEN) return error.DcidTooLong;
    @memcpy(conn.dcid[0..dcid.len], dcid);

    return conn;
}

pub fn allocLocalUniStreamId(self: *Connection) u64 {
    const id = self.next_local_uni_stream_id;
    self.next_local_uni_stream_id += 4;
    return id;
}

pub fn allocLocalBidiStreamId(self: *Connection) u64 {
    const id = self.next_local_bidi_stream_id;
    self.next_local_bidi_stream_id += 4;
    return id;
}

// Helper to format connection ID as hex
pub fn formatCid(cid: []const u8, buf: []u8) ![]const u8 {
    if (buf.len < cid.len * 2) return error.BufferTooSmall;
    const hex_chars = "0123456789abcdef";

    for (cid, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return buf[0 .. cid.len * 2];
}
