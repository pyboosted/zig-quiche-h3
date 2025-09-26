const std = @import("std");
const quiche = @import("quiche");
const h3 = @import("h3");
const h3_datagram = h3.datagram;
const http = @import("http");
const wt_capsules = http.webtransport_capsules;
const client = @import("mod.zig");
const ClientError = client.ClientError;
const AutoHashMap = std.AutoHashMap;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

/// Client-side WebTransport session management
/// IMPORTANT: Client can only originate WebTransport streams - peer-initiated
/// streams are not surfaced by the quiche C API
pub const WebTransportSession = struct {
    /// The CONNECT stream ID that established this session (reuses FetchState stream_id)
    session_id: u64,

    /// Reference to the client that owns this session
    client: *client.QuicClient,

    /// Session state tracking
    state: State = .connecting,

    /// Path used in the CONNECT request
    path: []const u8,

    /// Datagram statistics for this session
    datagrams_sent: u64 = 0,
    datagrams_received: u64 = 0,

    /// User data pointer for application state
    user_data: ?*anyopaque = null,

    /// Queue for received datagrams
    datagram_queue: ArrayListUnmanaged([]u8),

    /// Pending outbound datagrams awaiting QUIC capacity
    pending_datagrams: ArrayListUnmanaged([]u8),

    /// Buffer for partial capsule frames on CONNECT stream
    capsule_buffer: ArrayListUnmanaged(u8),

    /// Negotiated limits and flags received via capsules
    accept_info: AcceptInfo = .{},

    /// Last close capsule information, if any
    close_info: ?CloseInfo = null,

    /// Active WebTransport streams initiated by the client
    streams: AutoHashMap(u64, *Stream),
    outgoing_uni_count: u64 = 0,
    outgoing_bidi_count: u64 = 0,

    pub const State = enum {
        connecting, // CONNECT request sent, awaiting response
        established, // 200 response received
        closed, // Session terminated
    };

    pub const AcceptInfo = struct {
        legacy_accept: bool = false,
        max_streams_uni: ?u64 = null,
        max_streams_bidi: ?u64 = null,
        max_data: ?u64 = null,
        drain_requested: bool = false,
    };

    pub const CloseInfo = struct {
        application_error_code: u32,
        reason: []const u8,
    };

    pub const StreamDataHandler = *const fn (stream: *Stream, data: []const u8, fin: bool, ctx: ?*anyopaque) ClientError!void;

    pub const Stream = struct {
        session: *WebTransportSession,
        stream_id: u64,
        dir: h3.WebTransportSession.StreamDir,
        writable: bool = true,
        pending_fin: bool = false,
        on_data: ?StreamDataHandler = null,
        on_data_ctx: ?*anyopaque = null,
        recv_queue: ArrayListUnmanaged([]u8),
        recv_buffered_bytes: usize = 0,
        fin_received: bool = false,

        pub fn send(self: *Stream, data: []const u8, fin: bool) ClientError!usize {
            if (self.session.state != .established) return ClientError.InvalidState;
            if (!self.writable and data.len > 0) return ClientError.StreamBlocked;

            if (data.len == 0) {
                if (!fin) return 0;
                try self.sendFinInternal(true);
                return 0;
            }

            const conn = try self.session.client.requireConn();
            const written = conn.streamSend(self.stream_id, data, false) catch |err| switch (err) {
                quiche.QuicheError.FlowControl, quiche.QuicheError.Done => {
                    self.writable = false;
                    self.session.client.ensureStreamWritable(self.stream_id, data.len);
                    if (fin) self.pending_fin = true;
                    return ClientError.StreamBlocked;
                },
                else => return ClientError.QuicSendFailed,
            };

            if (written < data.len) {
                self.writable = false;
                self.session.client.ensureStreamWritable(self.stream_id, data.len - written);
                if (fin) self.pending_fin = true;
            } else if (fin) {
                self.sendFinInternal(false) catch |err| switch (err) {
                    ClientError.StreamBlocked => {
                        self.pending_fin = true;
                        self.session.client.ensureStreamWritable(self.stream_id, 0);
                        return written;
                    },
                    else => return err,
                };
                try self.session.client.flushSend();
                self.session.client.afterQuicProgress();
                return written;
            }

            try self.session.client.flushSend();
            self.session.client.afterQuicProgress();

            return written;
        }

        pub fn sendAll(self: *Stream, data: []const u8, fin: bool) ClientError!void {
            var offset: usize = 0;
            const total = data.len;
            while (offset < total) {
                const remaining = data[offset..];
                const apply_fin = fin and (offset + remaining.len == total);
                const written = try self.send(remaining, apply_fin);
                offset += written;
                if (written < remaining.len) {
                    if (!self.writable) return ClientError.StreamBlocked;
                }
            }
            if (total == 0 and fin) {
                _ = try self.send(&.{}, true);
            }
        }

        pub fn close(self: *Stream) ClientError!void {
            _ = try self.send(&.{}, true);
        }

        pub fn isWritable(self: *const Stream) bool {
            return self.writable;
        }

        pub fn destroy(self: *Stream) void {
            self.session.removeStream(self.stream_id);
        }

        pub fn setDataHandler(self: *Stream, handler: StreamDataHandler, ctx: ?*anyopaque) void {
            self.on_data = handler;
            self.on_data_ctx = ctx;
        }

        pub fn clearDataHandler(self: *Stream) void {
            self.on_data = null;
            self.on_data_ctx = null;
        }

        pub fn receive(self: *Stream) ?[]u8 {
            if (self.recv_queue.items.len == 0) return null;
            const payload = self.recv_queue.orderedRemove(0);
            if (self.recv_buffered_bytes >= payload.len) {
                self.recv_buffered_bytes -= payload.len;
            } else {
                self.recv_buffered_bytes = 0;
            }
            return payload;
        }

        pub fn freeReceived(self: *Stream, data: []u8) void {
            self.session.client.allocator.free(data);
        }

        pub fn isFinished(self: *const Stream) bool {
            return self.fin_received and self.recv_queue.items.len == 0;
        }

        pub fn handleIncoming(self: *Stream, data: []const u8, fin: bool) ClientError!void {
            if (data.len > 0) {
                try self.deliverData(data);
            }
            if (fin and !self.fin_received) {
                self.fin_received = true;
                self.writable = false;
                if (self.on_data) |cb| {
                    try cb(self, &.{}, true, self.on_data_ctx);
                }
            }
        }

        fn deliverData(self: *Stream, data: []const u8) ClientError!void {
            const allocator = self.session.client.allocator;
            const copy = try allocator.dupe(u8, data);
            errdefer allocator.free(copy);

            if (self.on_data) |cb| {
                try cb(self, copy, false, self.on_data_ctx);
                allocator.free(copy);
            } else {
                try self.enqueueCopy(copy);
            }
        }

        fn enqueueCopy(self: *Stream, copy: []u8) ClientError!void {
            const cfg = self.session.client.config;
            if (cfg.wt_stream_recv_queue_len != 0 and self.recv_queue.items.len >= cfg.wt_stream_recv_queue_len) {
                self.session.client.allocator.free(copy);
                return ClientError.StreamBlocked;
            }
            if (cfg.wt_stream_recv_buffer_bytes != 0 and self.recv_buffered_bytes + copy.len > cfg.wt_stream_recv_buffer_bytes) {
                self.session.client.allocator.free(copy);
                return ClientError.StreamBlocked;
            }
            try self.recv_queue.append(self.session.client.allocator, copy);
            self.recv_buffered_bytes += copy.len;
        }

        fn sendFinInternal(self: *Stream, flush_after: bool) ClientError!void {
            const conn = try self.session.client.requireConn();
            const result = conn.streamSend(self.stream_id, &[_]u8{}, true) catch |err| switch (err) {
                quiche.QuicheError.FlowControl, quiche.QuicheError.Done => {
                    self.writable = false;
                    self.pending_fin = true;
                    self.session.client.ensureStreamWritable(self.stream_id, 0);
                    return ClientError.StreamBlocked;
                },
                else => return ClientError.QuicSendFailed,
            };
            _ = result;
            self.pending_fin = false;
            if (flush_after) {
                try self.session.client.flushSend();
                self.session.client.afterQuicProgress();
            }
        }
    };

    pub fn openUniStream(self: *WebTransportSession) ClientError!*Stream {
        return self.openStream(h3.WebTransportSession.StreamDir.uni);
    }

    pub fn openBidiStream(self: *WebTransportSession) ClientError!*Stream {
        return self.openStream(h3.WebTransportSession.StreamDir.bidi);
    }

    fn openStream(self: *WebTransportSession, dir: h3.WebTransportSession.StreamDir) ClientError!*Stream {
        if (self.state != .established) return ClientError.InvalidState;

        const cfg = self.client.config;
        switch (dir) {
            .uni => if (self.accept_info.max_streams_uni) |limit| {
                if (self.outgoing_uni_count >= limit) return ClientError.StreamBlocked;
            } else if (cfg.wt_max_outgoing_uni != 0 and self.outgoing_uni_count >= cfg.wt_max_outgoing_uni) {
                return ClientError.StreamBlocked;
            },
            .bidi => if (self.accept_info.max_streams_bidi) |limit| {
                if (self.outgoing_bidi_count >= limit) return ClientError.StreamBlocked;
            } else if (cfg.wt_max_outgoing_bidi != 0 and self.outgoing_bidi_count >= cfg.wt_max_outgoing_bidi) {
                return ClientError.StreamBlocked;
            },
        }

        const stream_id = try self.client.allocLocalStreamId(dir);
        const stream = try self.client.allocator.create(Stream);
        stream.* = .{
            .session = self,
            .stream_id = stream_id,
            .dir = dir,
            .recv_queue = ArrayListUnmanaged([]u8){},
        };

        try self.streams.put(stream_id, stream);
        try self.client.wt_streams.put(stream_id, stream);

        switch (dir) {
            .uni => self.outgoing_uni_count += 1,
            .bidi => self.outgoing_bidi_count += 1,
        }

        var preface: [16]u8 = undefined;
        var off: usize = 0;
        const stream_type = switch (dir) {
            .uni => h3.WebTransportSession.UNI_STREAM_TYPE,
            .bidi => h3.WebTransportSession.BIDI_STREAM_TYPE,
        };
        off += h3_datagram.encodeVarint(preface[off..], stream_type) catch unreachable;
        off += h3_datagram.encodeVarint(preface[off..], self.session_id) catch unreachable;

        const conn = try self.client.requireConn();
        const written = conn.streamSend(stream_id, preface[0..off], false) catch |err| switch (err) {
            quiche.QuicheError.FlowControl, quiche.QuicheError.Done => {
                self.ensureWritableRegistration(stream_id, off);
                stream.writable = false;
                return ClientError.StreamBlocked;
            },
            else => return ClientError.QuicSendFailed,
        };

        if (written < off) {
            self.ensureWritableRegistration(stream_id, off - written);
            stream.writable = false;
        }

        self.client.updateStreamIndicesFor(stream_id);
        try self.client.flushSend();
        self.client.afterQuicProgress();
        return stream;
    }

    fn ensureWritableRegistration(self: *WebTransportSession, stream_id: u64, hint: usize) void {
        self.client.ensureStreamWritable(stream_id, hint);
    }

    fn removeStream(self: *WebTransportSession, stream_id: u64) void {
        self.removeStreamInternal(stream_id, true);
    }

    pub fn removeStreamInternal(self: *WebTransportSession, stream_id: u64, free_stream: bool) void {
        if (self.streams.fetchRemove(stream_id)) |kv| {
            const stream_ptr = kv.value;
            _ = self.client.wt_streams.remove(stream_id);
            switch (stream_ptr.dir) {
                .uni => {
                    if (self.outgoing_uni_count > 0) self.outgoing_uni_count -= 1;
                },
                .bidi => {
                    if (self.outgoing_bidi_count > 0) self.outgoing_bidi_count -= 1;
                },
            }
            stream_ptr.writable = false;
            stream_ptr.pending_fin = false;
            if (free_stream) {
                for (stream_ptr.recv_queue.items) |payload| {
                    self.client.allocator.free(payload);
                }
                stream_ptr.recv_queue.deinit(self.client.allocator);
            }
            if (free_stream) self.client.allocator.destroy(stream_ptr);
        } else {
            _ = self.client.wt_streams.remove(stream_id);
        }
    }

    /// Check if this session is affected by GOAWAY
    pub fn isGoingAway(self: *const WebTransportSession) bool {
        return self.client.goaway_received and
            self.session_id > (self.client.goaway_stream_id orelse std.math.maxInt(u64));
    }

    /// Send a datagram on this WebTransport session
    /// The datagram will be prefixed with the session_id as a varint
    pub fn sendDatagram(self: *WebTransportSession, payload: []const u8) !void {
        if (self.state != .established) {
            return error.SessionNotEstablished;
        }

        if (self.isGoingAway()) {
            return error.GoAwayReceived;
        }

        const conn = self.client.requireConn() catch return error.DatagramSendFailed;

        const prefix_len = h3_datagram.varintLen(self.session_id);
        const total_len = prefix_len + payload.len;

        const max_len = conn.dgramMaxWritableLen() orelse
            return error.DatagramNotEnabled;
        if (total_len > max_len) {
            return error.DatagramTooLarge;
        }

        var buf = try self.client.allocator.alloc(u8, total_len);
        var keep_ownership = true;
        defer if (keep_ownership) self.client.allocator.free(buf);

        const written = h3_datagram.encodeVarint(buf, self.session_id) catch unreachable;
        std.debug.assert(written == prefix_len);
        @memcpy(buf[written..][0..payload.len], payload);

        if (self.pending_datagrams.items.len > 0) {
            keep_ownership = false;
            self.enqueuePendingDatagram(buf) catch |queue_err| {
                return queue_err;
            };
            return error.WouldBlock;
        }

        const sent = conn.dgramSend(buf) catch |err| {
            if (err == error.Done) {
                keep_ownership = false;
                self.enqueuePendingDatagram(buf) catch |queue_err| {
                    return queue_err;
                };
                return error.WouldBlock;
            }
            return error.DatagramSendFailed;
        };

        if (sent != total_len) {
            return error.DatagramSendFailed;
        }

        self.markDatagramSent();
        self.client.flushSend() catch {};
        self.client.afterQuicProgress();
    }

    /// Receive a queued datagram if available
    /// Caller owns the returned memory and must free it
    pub fn receiveDatagram(self: *WebTransportSession) ?[]u8 {
        if (self.datagram_queue.items.len == 0) return null;
        return self.datagram_queue.orderedRemove(0);
    }

    /// Queue an incoming datagram for this session
    /// Called internally by the client when processing H3 datagrams
    pub fn queueDatagram(self: *WebTransportSession, payload: []const u8) !void {
        const copy = try self.client.allocator.dupe(u8, payload);
        errdefer self.client.allocator.free(copy);
        try self.datagram_queue.append(self.client.allocator, copy);
        self.datagrams_received += 1;
    }

    fn enqueuePendingDatagram(self: *WebTransportSession, buf: []u8) !void {
        const limit = self.client.config.dgram_send_queue_len;
        if (limit != 0 and self.pending_datagrams.items.len >= limit) {
            self.client.allocator.free(buf);
            self.client.datagram_stats.dropped_send += 1;
            return error.WouldBlock;
        }
        try self.pending_datagrams.append(self.client.allocator, buf);
    }

    fn markDatagramSent(self: *WebTransportSession) void {
        self.datagrams_sent += 1;
        self.client.datagram_stats.sent += 1;
    }

    pub fn flushPendingDatagrams(self: *WebTransportSession) void {
        if (self.pending_datagrams.items.len == 0) return;
        const conn_ref = blk: {
            if (self.client.conn) |*conn_ptr| break :blk conn_ptr;
            return;
        };

        var sent_any = false;
        while (self.pending_datagrams.items.len > 0) {
            const buf = self.pending_datagrams.items[0];
            const sent = conn_ref.dgramSend(buf) catch |err| {
                if (err == error.Done) {
                    break;
                }
                self.client.datagram_stats.dropped_send += 1;
                self.client.allocator.free(buf);
                _ = self.pending_datagrams.orderedRemove(0);
                continue;
            };

            if (sent != buf.len) {
                self.client.datagram_stats.dropped_send += 1;
                self.client.allocator.free(buf);
                _ = self.pending_datagrams.orderedRemove(0);
                continue;
            }

            self.client.allocator.free(buf);
            _ = self.pending_datagrams.orderedRemove(0);
            self.markDatagramSent();
            sent_any = true;
        }

        if (sent_any) {
            self.client.flushSend() catch {};
        }
    }

    /// Handle state transition when CONNECT response is received
    pub fn handleConnectResponse(self: *WebTransportSession, status: u16) void {
        switch (status) {
            200 => {
                self.state = .established;
                // Session successfully established
            },
            else => {
                self.state = .closed;
                // Session rejected by server
            },
        }
    }

    /// Convenience close helper using default code/reason
    pub fn close(self: *WebTransportSession) void {
        _ = self.closeWith(0, &.{}) catch {};
    }

    /// Close the WebTransport session and free all resources
    /// After calling this, the session pointer is no longer valid
    pub fn closeWith(self: *WebTransportSession, code: u32, reason: []const u8) ClientError!void {
        if (self.state == .closed) {
            self.finalizeClose();
            return;
        }

        if (self.state == .established) {
            if (reason.len > wt_capsules.MAX_CLOSE_REASON_BYTES) {
                return ClientError.InvalidState;
            }
            const capsule = wt_capsules.Capsule{
                .close_session = .{ .application_error_code = code, .reason = reason },
            };
            try self.sendCapsule(capsule);
        }

        self.state = .closed;
        self.client.markWebTransportSessionClosed(self.session_id);
        self.finalizeClose();
    }

    /// Process capsule bytes received on the CONNECT stream
    pub fn processCapsuleBytes(self: *WebTransportSession, bytes: []const u8) ClientError!void {
        try self.capsule_buffer.appendSlice(self.client.allocator, bytes);

        var offset: usize = 0;
        while (true) {
            const buf = self.capsule_buffer.items[offset..];
            if (buf.len == 0) break;

            const type_res = h3_datagram.decodeVarint(buf) catch |err| {
                if (err == error.BufferTooShort) break;
                return ClientError.H3Error;
            };
            const len_res = h3_datagram.decodeVarint(buf[type_res.consumed..]) catch |err| {
                if (err == error.BufferTooShort) break;
                return ClientError.H3Error;
            };
            const payload_len = len_res.value;
            const payload_usize = @as(usize, @intCast(payload_len));
            const capsule_len = type_res.consumed + len_res.consumed + payload_usize;
            if (buf.len < capsule_len) break; // Wait for more bytes

            const capsule_slice = buf[0..capsule_len];
            const capsule_type_val = type_res.value;

            if (capsule_type_val == 0x3c) {
                self.accept_info.legacy_accept = true;
                self.client.recordLegacySessionAcceptReceived();
                offset += capsule_len;
                continue;
            }

            const decoded = wt_capsules.decode(capsule_slice) catch |err| switch (err) {
                error.BufferTooShort, error.InvalidLength => break,
                error.InvalidCapsuleType => {
                    offset += capsule_len;
                    continue;
                },
                error.ReasonTooLong, error.ValueTooLarge => return ClientError.InvalidState,
            };

            offset += decoded.consumed;
            self.client.recordCapsuleReceived(decoded.capsule.capsuleType());
            try self.handleCapsule(decoded.capsule);
        }

        if (offset > 0) {
            const remaining = self.capsule_buffer.items.len - offset;
            std.mem.copyForwards(u8, self.capsule_buffer.items[0..remaining], self.capsule_buffer.items[offset..]);
            self.capsule_buffer.shrinkRetainingCapacity(remaining);
        }
    }

    pub fn acceptInfo(self: *const WebTransportSession) AcceptInfo {
        return self.accept_info;
    }

    pub fn closeInfo(self: *const WebTransportSession) ?CloseInfo {
        return self.close_info;
    }

    fn sendCapsule(self: *WebTransportSession, capsule: wt_capsules.Capsule) ClientError!void {
        const conn = try self.client.requireConn();
        const needed = capsule.maxEncodedLen();
        var stack: [256]u8 = undefined;
        var buf = if (needed <= stack.len)
            stack[0..needed]
        else
            try self.client.allocator.alloc(u8, needed);
        defer if (needed > stack.len) self.client.allocator.free(buf);

        const written = capsule.encode(buf) catch |err| switch (err) {
            error.ReasonTooLong, error.ValueTooLarge => return ClientError.InvalidState,
            error.BufferTooShort, error.InvalidCapsuleType, error.InvalidLength => return ClientError.H3Error,
        };

        const sent = conn.streamSend(self.session_id, buf[0..written], false) catch {
            return ClientError.QuicSendFailed;
        };
        if (sent != written) {
            return ClientError.QuicSendFailed;
        }

        self.client.recordCapsuleSent(capsule);
        try self.client.flushSend();
        self.client.afterQuicProgress();
    }

    fn handleCapsule(self: *WebTransportSession, capsule: wt_capsules.Capsule) ClientError!void {
        switch (capsule) {
            .close_session => |info| {
                const allocator = self.client.allocator;
                if (self.close_info) |existing| {
                    allocator.free(@constCast(existing.reason));
                }
                const reason_copy = try allocator.dupe(u8, info.reason);
                self.close_info = .{
                    .application_error_code = info.application_error_code,
                    .reason = reason_copy,
                };
                self.state = .closed;
                self.client.markWebTransportSessionClosed(self.session_id);
            },
            .drain_session => {
                self.accept_info.drain_requested = true;
            },
            .max_streams => |info| {
                switch (info.dir) {
                    .uni => self.accept_info.max_streams_uni = info.maximum,
                    .bidi => self.accept_info.max_streams_bidi = info.maximum,
                }
            },
            .streams_blocked => |_| {},
            .max_data => |info| {
                self.accept_info.max_data = info.maximum;
            },
            .data_blocked => |_| {},
        }
    }

    fn finalizeClose(self: *WebTransportSession) void {
        const session_id = self.session_id;
        const client_ref = self.client;

        if (client_ref.requests.get(session_id)) |state| {
            _ = client_ref.requests.remove(session_id);
            state.destroy();
        }

        if (client_ref.wt_sessions.contains(session_id)) {
            client_ref.cleanupWebTransportSession(session_id);
        } else {
            for (self.datagram_queue.items) |dgram| {
                client_ref.allocator.free(dgram);
            }
            self.datagram_queue.deinit(client_ref.allocator);
            for (self.pending_datagrams.items) |buf| {
                client_ref.allocator.free(buf);
            }
            self.pending_datagrams.deinit(client_ref.allocator);
            self.capsule_buffer.deinit(client_ref.allocator);
            if (self.close_info) |info| {
                client_ref.allocator.free(@constCast(info.reason));
                self.close_info = null;
            }
            client_ref.allocator.free(self.path);
            client_ref.allocator.destroy(self);
        }
    }
};

/// Helper to check if headers indicate WebTransport CONNECT
pub fn isWebTransportConnect(headers: []const client.HeaderPair) bool {
    var has_connect = false;
    var has_protocol = false;

    for (headers) |pair| {
        if (std.mem.eql(u8, pair.name, ":method") and std.mem.eql(u8, pair.value, "CONNECT")) {
            has_connect = true;
        } else if (std.mem.eql(u8, pair.name, ":protocol") and std.mem.eql(u8, pair.value, "webtransport")) {
            has_protocol = true;
        }
    }

    return has_connect and has_protocol;
}

/// Build Extended CONNECT headers for WebTransport
pub fn buildWebTransportHeaders(
    allocator: std.mem.Allocator,
    authority: []const u8,
    path: []const u8,
    extra_headers: []const client.HeaderPair,
) ![]quiche.h3.Header {
    const base_count: usize = 5; // Core WebTransport headers
    const total = base_count + extra_headers.len;

    var headers = try allocator.alloc(quiche.h3.Header, total);
    headers[0] = makeHeader(":method", "CONNECT");
    headers[1] = makeHeader(":protocol", "webtransport");
    headers[2] = makeHeader(":scheme", "https");
    headers[3] = makeHeader(":authority", authority);
    headers[4] = makeHeader(":path", path);

    // Add any extra headers
    for (extra_headers, base_count..) |pair, idx| {
        headers[idx] = makeHeader(pair.name, pair.value);
    }

    return headers;
}

fn makeHeader(name_literal: []const u8, value_slice: []const u8) quiche.h3.Header {
    return .{
        .name = name_literal.ptr,
        .name_len = name_literal.len,
        .value = value_slice.ptr,
        .value_len = value_slice.len,
    };
}

// ===== Unit Tests =====
const testing = std.testing;

test "WebTransport: isWebTransportConnect identifies Extended CONNECT" {
    const headers_wt = [_]client.HeaderPair{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":protocol", .value = "webtransport" },
        .{ .name = ":path", .value = "/wt" },
    };

    const headers_regular = [_]client.HeaderPair{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
    };

    const headers_connect_only = [_]client.HeaderPair{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":path", .value = "/" },
    };

    try testing.expect(isWebTransportConnect(&headers_wt));
    try testing.expect(!isWebTransportConnect(&headers_regular));
    try testing.expect(!isWebTransportConnect(&headers_connect_only));
}

test "WebTransport: buildWebTransportHeaders creates valid headers" {
    const allocator = testing.allocator;
    const authority = "example.com:443";
    const path = "/webtransport";
    const extra_headers = [_]client.HeaderPair{
        .{ .name = "origin", .value = "https://example.com" },
    };

    const headers = try buildWebTransportHeaders(
        allocator,
        authority,
        path,
        &extra_headers,
    );
    defer allocator.free(headers);

    try testing.expect(headers.len == 6);

    // Check core headers
    try testing.expectEqualStrings(headers[0].name[0..headers[0].name_len], ":method");
    try testing.expectEqualStrings(headers[0].value[0..headers[0].value_len], "CONNECT");

    try testing.expectEqualStrings(headers[1].name[0..headers[1].name_len], ":protocol");
    try testing.expectEqualStrings(headers[1].value[0..headers[1].value_len], "webtransport");

    try testing.expectEqualStrings(headers[2].name[0..headers[2].name_len], ":scheme");
    try testing.expectEqualStrings(headers[2].value[0..headers[2].value_len], "https");

    try testing.expectEqualStrings(headers[3].name[0..headers[3].name_len], ":authority");
    try testing.expectEqualStrings(headers[3].value[0..headers[3].value_len], authority);

    try testing.expectEqualStrings(headers[4].name[0..headers[4].name_len], ":path");
    try testing.expectEqualStrings(headers[4].value[0..headers[4].value_len], path);

    // Check extra header
    try testing.expectEqualStrings(headers[5].name[0..headers[5].name_len], "origin");
    try testing.expectEqualStrings(headers[5].value[0..headers[5].value_len], "https://example.com");
}

test "WebTransport: varint encoding for session IDs" {
    // Test various session ID sizes
    const test_cases = [_]struct { id: u64, expected_len: usize }{
        .{ .id = 0, .expected_len = 1 },
        .{ .id = 63, .expected_len = 1 },
        .{ .id = 64, .expected_len = 2 },
        .{ .id = 16383, .expected_len = 2 },
        .{ .id = 16384, .expected_len = 4 },
        .{ .id = 1073741823, .expected_len = 4 },
        .{ .id = 1073741824, .expected_len = 8 },
    };

    for (test_cases) |tc| {
        const len = h3_datagram.varintLen(tc.id);
        try testing.expectEqual(tc.expected_len, len);

        // Test encoding/decoding round-trip
        var buf: [8]u8 = undefined;
        const encoded_len = h3_datagram.encodeVarint(&buf, tc.id) catch unreachable;
        try testing.expectEqual(tc.expected_len, encoded_len);

        const decoded = try h3_datagram.decodeVarint(buf[0..encoded_len]);
        try testing.expectEqual(tc.id, decoded.value);
        try testing.expectEqual(tc.expected_len, decoded.len);
    }
}

test "WebTransport: capsule processing updates session state" {
    const cfg = client.ClientConfig{ .enable_webtransport = true };
    var client_ptr = try client.QuicClient.init(testing.allocator, cfg);
    defer client_ptr.deinit();

    const allocator = client_ptr.allocator;
    const session_id: u64 = 4;
    var session = try allocator.create(WebTransportSession);
    session.* = .{
        .session_id = session_id,
        .client = client_ptr,
        .state = .established,
        .path = try allocator.dupe(u8, "/wt"),
        .datagram_queue = ArrayListUnmanaged([]u8){},
        .pending_datagrams = ArrayListUnmanaged([]u8){},
        .capsule_buffer = ArrayListUnmanaged(u8){},
        .streams = AutoHashMap(u64, *WebTransportSession.Stream).init(allocator),
    };

    try client_ptr.wt_sessions.put(session_id, session);

    var buf: [256]u8 = undefined;

    const max_streams_capsule = wt_capsules.Capsule{ .max_streams = .{ .dir = .uni, .maximum = 7 } };
    const written = try max_streams_capsule.encode(buf[0..]);
    try session.processCapsuleBytes(buf[0..written]);
    var accept = session.acceptInfo();
    try testing.expectEqual(@as(?u64, 7), accept.max_streams_uni);
    try testing.expect(!accept.legacy_accept);

    var legacy_buf: [16]u8 = undefined;
    var legacy_off: usize = 0;
    legacy_off += h3_datagram.encodeVarint(legacy_buf[legacy_off..], 0x3c) catch unreachable;
    legacy_off += h3_datagram.encodeVarint(legacy_buf[legacy_off..], 0) catch unreachable;
    try session.processCapsuleBytes(legacy_buf[0..legacy_off]);
    accept = session.acceptInfo();
    try testing.expect(accept.legacy_accept);
    try testing.expectEqual(@as(usize, 2), client_ptr.wt_capsules_received_total);
    try testing.expectEqual(@as(usize, 1), client_ptr.wt_legacy_session_accept_received);

    const close_capsule = wt_capsules.Capsule{
        .close_session = .{ .application_error_code = 0xdead, .reason = "bye" },
    };
    const close_written = try close_capsule.encode(buf[0..]);
    try session.processCapsuleBytes(buf[0..close_written]);
    try testing.expectEqual(WebTransportSession.State.closed, session.state);
    const close_info = session.closeInfo().?;
    try testing.expectEqual(@as(u32, 0xdead), close_info.application_error_code);
    try testing.expectEqualStrings("bye", close_info.reason);
    try testing.expectEqual(@as(usize, 3), client_ptr.wt_capsules_received_total);
    try testing.expectEqual(@as(usize, 1), client_ptr.wt_capsules_received.close_session);

    client_ptr.cleanupWebTransportSession(session_id);
}

test "WebTransport: pending datagram queue respects limit" {
    const cfg = client.ClientConfig{
        .enable_webtransport = true,
        .dgram_send_queue_len = 1,
        .wt_stream_recv_buffer_bytes = 1024,
    };
    var client_ptr = try client.QuicClient.init(testing.allocator, cfg);
    defer client_ptr.deinit();

    const allocator = client_ptr.allocator;
    const session_id: u64 = 9;
    var session = try allocator.create(WebTransportSession);
    session.* = .{
        .session_id = session_id,
        .client = client_ptr,
        .state = .established,
        .path = try allocator.dupe(u8, "/wt"),
        .datagram_queue = ArrayListUnmanaged([]u8){},
        .pending_datagrams = ArrayListUnmanaged([]u8){},
        .capsule_buffer = ArrayListUnmanaged(u8){},
        .streams = AutoHashMap(u64, *WebTransportSession.Stream).init(allocator),
    };

    try client_ptr.wt_sessions.put(session_id, session);

    const first = try allocator.alloc(u8, 4);
    try session.enqueuePendingDatagram(first);
    try testing.expectEqual(@as(usize, 1), session.pending_datagrams.items.len);

    const second = try allocator.alloc(u8, 4);
    try testing.expectError(error.WouldBlock, session.enqueuePendingDatagram(second));
    try testing.expectEqual(@as(u64, 1), client_ptr.datagram_stats.dropped_send);

    client_ptr.cleanupWebTransportSession(session_id);
}

test "WebTransport: stream receive queue enforces limits" {
    const cfg = client.ClientConfig{
        .enable_webtransport = true,
        .wt_stream_recv_queue_len = 1,
        .wt_stream_recv_buffer_bytes = 8,
    };
    var client_ptr = try client.QuicClient.init(testing.allocator, cfg);
    defer client_ptr.deinit();

    const allocator = client_ptr.allocator;
    const session_id: u64 = 11;
    var session = try allocator.create(WebTransportSession);
    session.* = .{
        .session_id = session_id,
        .client = client_ptr,
        .state = .established,
        .path = try allocator.dupe(u8, "/wt"),
        .datagram_queue = ArrayListUnmanaged([]u8){},
        .pending_datagrams = ArrayListUnmanaged([]u8){},
        .capsule_buffer = ArrayListUnmanaged(u8){},
        .streams = AutoHashMap(u64, *WebTransportSession.Stream).init(allocator),
    };
    try client_ptr.wt_sessions.put(session_id, session);

    const stream_id: u64 = 20;
    var stream = try allocator.create(WebTransportSession.Stream);
    stream.* = .{
        .session = session,
        .stream_id = stream_id,
        .dir = h3.WebTransportSession.StreamDir.bidi,
        .recv_queue = ArrayListUnmanaged([]u8){},
    };
    try session.streams.put(stream_id, stream);
    try client_ptr.wt_streams.put(stream_id, stream);

    try stream.handleIncoming("hi", false);
    try testing.expectEqual(@as(usize, 1), stream.recv_queue.items.len);

    const first = stream.receive().?;
    try testing.expectEqualStrings("hi", first);
    stream.freeReceived(first);
    try testing.expect(stream.recv_queue.items.len == 0);

    const ok = "aa";
    try stream.handleIncoming(ok, false);

    const overflow = "bbbb";
    try testing.expectError(ClientError.StreamBlocked, stream.handleIncoming(overflow, false));

    client_ptr.cleanupWebTransportSession(session_id);
}

test "WebTransport: stream data handler receives fin" {
    const cfg = client.ClientConfig{ .enable_webtransport = true };
    var client_ptr = try client.QuicClient.init(testing.allocator, cfg);
    defer client_ptr.deinit();

    const allocator = client_ptr.allocator;
    const session_id: u64 = 12;
    var session = try allocator.create(WebTransportSession);
    session.* = .{
        .session_id = session_id,
        .client = client_ptr,
        .state = .established,
        .path = try allocator.dupe(u8, "/wt"),
        .datagram_queue = ArrayListUnmanaged([]u8){},
        .pending_datagrams = ArrayListUnmanaged([]u8){},
        .capsule_buffer = ArrayListUnmanaged(u8){},
        .streams = AutoHashMap(u64, *WebTransportSession.Stream).init(allocator),
    };

    const stream_id: u64 = 30;
    var stream = try allocator.create(WebTransportSession.Stream);
    stream.* = .{
        .session = session,
        .stream_id = stream_id,
        .dir = h3.WebTransportSession.StreamDir.bidi,
        .recv_queue = ArrayListUnmanaged([]u8){},
    };
    try session.streams.put(stream_id, stream);
    try client_ptr.wt_streams.put(stream_id, stream);

    const State = struct {
        data_calls: *usize,
        fin_seen: *bool,
    };

    var data_calls: usize = 0;
    var fin_seen = false;
    const Handler = struct {
        pub fn onData(
            strm: *WebTransportSession.Stream,
            payload: []const u8,
            fin: bool,
            ctx: ?*anyopaque,
        ) ClientError!void {
            _ = strm;
            const state: *State = @ptrCast(@alignCast(ctx.?));
            if (payload.len > 0) {
                state.data_calls.* += 1;
            }
            if (fin) {
                state.fin_seen.* = true;
            }
        }
    };

    var handler_state = State{ .data_calls = &data_calls, .fin_seen = &fin_seen };

    stream.setDataHandler(Handler.onData, &handler_state);

    try stream.handleIncoming("pong", false);
    try stream.handleIncoming(&.{}, true);

    try testing.expectEqual(@as(usize, 1), data_calls);
    try testing.expect(fin_seen);
    try testing.expect(stream.isFinished());

    client_ptr.cleanupWebTransportSession(session_id);
}
