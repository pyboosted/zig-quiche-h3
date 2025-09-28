const std = @import("std");
const h3 = @import("h3");
const quiche = @import("quiche");
const ClientError = @import("mod.zig").ClientError;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub fn StreamTypes(comptime SessionType: type) type {
    return struct {
        pub const Stream = struct {
            session: *SessionType,
            stream_id: u64,
            dir: h3.WebTransportSession.StreamDir,
            writable: bool = true,
            pending_fin: bool = false,
            on_data: ?Handler = null,
            on_data_ctx: ?*anyopaque = null,
            recv_queue: ArrayListUnmanaged([]u8),
            recv_buffered_bytes: usize = 0,
            fin_received: bool = false,

            pub const Handler = *const fn (stream: *@This(), data: []const u8, fin: bool, ctx: ?*anyopaque) ClientError!void;

            pub fn send(self: *Stream, data: []const u8, fin: bool) ClientError!usize {
                if (self.session.state != .established) return ClientError.InvalidState;
                if (!self.writable and data.len > 0) {
                    self.session.client.ensureStreamWritable(self.stream_id, data.len);
                }

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
                self.session.removeStreamInternal(self.stream_id, true);
            }

            pub fn setDataHandler(self: *Stream, handler: Handler, ctx: ?*anyopaque) void {
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

        pub const StreamDataHandler = Stream.Handler;
    };
}
