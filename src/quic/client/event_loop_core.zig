const std = @import("std");
const quiche = @import("quiche");
const client_errors = @import("errors.zig");

const ClientError = client_errors.ClientError;
const QuicheError = quiche.QuicheError;
const posix = std.posix;

pub fn Impl(comptime ClientType: type) type {
    return struct {
        const Self = ClientType;

        pub fn flushSend(self: *Self) ClientError!void {
            const conn = try self.requireConn();
            const sock = self.socket orelse return ClientError.NoSocket;

            while (true) {
                var send_info: quiche.c.quiche_send_info = undefined;
                const written = conn.send(self.send_buf[0..], &send_info) catch |err| switch (err) {
                    QuicheError.Done => break,
                    else => return ClientError.QuicSendFailed,
                };

                const payload = self.send_buf[0..written];
                const dest_ptr: *const posix.sockaddr = if (send_info.to_len != 0)
                    @ptrCast(&send_info.to)
                else
                    @ptrCast(&self.remote_addr);
                const dest_len: posix.socklen_t = if (send_info.to_len != 0)
                    send_info.to_len
                else
                    self.remote_addr_len;

                _ = posix.sendto(sock.fd, payload, 0, dest_ptr, dest_len) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return ClientError.IoFailure,
                };
            }
        }

        pub fn handleReadable(self: *Self, fd: posix.socket_t) ClientError!void {
            const sock = self.socket orelse return ClientError.NoSocket;
            if (sock.fd != fd) return ClientError.NoSocket;

            const conn = try self.requireConn();

            while (true) {
                var peer_addr: posix.sockaddr.storage = undefined;
                var peer_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
                const n = posix.recvfrom(
                    sock.fd,
                    self.recv_buf[0..],
                    0,
                    @ptrCast(&peer_addr),
                    &peer_len,
                ) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return ClientError.IoFailure,
                };
                if (n == 0) break;

                if (self.config.enable_debug_logging) {
                    std.debug.print("[client] recvfrom bytes={d}\n", .{n});
                }

                var recv_info = quiche.c.quiche_recv_info{
                    .from = @ptrCast(&peer_addr),
                    .from_len = peer_len,
                    .to = @ptrCast(&self.local_addr),
                    .to_len = self.local_addr_len,
                };

                const slice = self.recv_buf[0..n];
                _ = conn.recv(slice, &recv_info) catch |err| switch (err) {
                    QuicheError.Done => break,
                    else => return ClientError.QuicRecvFailed,
                };

                if (self.config.enable_debug_logging) {
                    std.debug.print("[client] quiche.recv consumed={d}\n", .{n});
                }
            }

            try self.flushSend();
            self.afterQuicProgress();
            try self.flushSend();
        }

        pub fn handleTimeout(self: *Self) ClientError!void {
            const conn = try self.requireConn();
            conn.onTimeout();
            try self.flushSend();
            self.afterQuicProgress();
        }

        pub fn afterQuicProgress(self: *Self) void {
            updateTimeout(self);
            self.sendPendingBodies();
            checkHandshakeState(self);
            self.processReadableWtStreams();
            self.processWritableWtStreams();
            processH3Events(self);
            self.processReadableWtStreams();
            self.processWritableWtStreams();
            self.processDatagrams();
        }

        pub fn updateTimeout(self: *Self) void {
            if (self.timeout_timer) |handle| {
                const conn = if (self.conn) |*conn_ref| conn_ref else return;
                const timeout_ms = conn.timeoutAsMillis();
                if (timeout_ms == std.math.maxInt(u64)) {
                    self.event_loop.stopTimer(handle);
                    return;
                }
                const after_s = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
                self.event_loop.startTimer(handle, after_s, 0);
            }
        }

        pub fn stopTimeoutTimer(self: *Self) void {
            if (self.timeout_timer) |handle| {
                self.event_loop.stopTimer(handle);
            }
        }

        pub fn checkHandshakeState(self: *Self) void {
            const conn = if (self.conn) |*conn_ref| conn_ref else return;
            if (self.state != .connecting) return;

            if (conn.isEstablished()) {
                self.state = .established;
                self.handshake_error = null;
                stopTimeoutTimer(self);
                self.stopConnectTimer();
                self.event_loop.stop();
                return;
            }

            if (conn.isClosed()) {
                self.recordFailure(ClientError.ConnectionClosed);
            }
        }

        pub fn processH3Events(self: *Self) void {
            const conn = if (self.conn) |*conn_ref| conn_ref else return;
            const h3_conn = blk: {
                if (self.h3_conn) |*ptr| break :blk ptr;
                return;
            };

            while (true) {
                const result = h3_conn.poll(conn);
                if (result == null) break;
                var poll = result.?;
                defer poll.deinit();

                if (self.config.enable_debug_logging) {
                    std.debug.print(
                        "[client] poll event={s} stream={d}\n",
                        .{ @tagName(poll.event_type), poll.stream_id },
                    );
                }

                switch (poll.event_type) {
                    .Headers => self.onH3Headers(poll.stream_id, poll.raw_event),
                    .Data => self.onH3Data(poll.stream_id),
                    .Finished => self.onH3Finished(poll.stream_id),
                    .GoAway => self.onH3GoAway(poll.stream_id),
                    .Reset => self.onH3Reset(poll.stream_id),
                    .PriorityUpdate => {},
                }
            }

            var it = self.requests.iterator();
            while (it.next()) |entry| {
                const stream_id = entry.key_ptr.*;
                const state = entry.value_ptr.*;
                if (!state.finished and state.status != null) {
                    if (state.content_length) |expected| {
                        if (state.bytes_received >= expected) {
                            self.onH3Finished(stream_id);
                            continue;
                        }
                        self.onH3Data(stream_id);
                    }

                    if (conn.streamFinished(stream_id)) {
                        self.onH3Finished(stream_id);
                    }
                }
            }
        }
    };
}
