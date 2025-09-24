const std = @import("std");
const http = @import("http");
const h3 = @import("h3");
const errors = @import("errors");
const connection = @import("connection");
const quiche = @import("quiche");
const wt_capsules = http.webtransport_capsules;

pub fn Api(comptime Server: type) type {
    return struct {
        const Self = Server;

        pub const AcceptOptions = struct {
            send_legacy_accept: bool = true,
            extra_capsules: []const wt_capsules.Capsule = &[_]wt_capsules.Capsule{},
        };

        pub const RejectOptions = struct {
            status: u16 = 403,
        };

        pub const CloseOptions = struct {
            code: u32 = 0,
            reason: []const u8 = &[_]u8{},
        };

        pub const Session = struct {
            server: *Self,
            conn: *connection.Connection,
            state: *h3.WebTransportSessionState,
            request_state: ?*Self.RequestState,

            pub fn fromOpaque(ptr: *anyopaque) *Session {
                return @ptrCast(@alignCast(ptr));
            }

            pub fn sessionId(self: *const Session) u64 {
                return self.state.session.session_id;
            }

            pub fn path(self: *const Session) []const u8 {
                return self.state.session.path;
            }

            pub fn flowId(self: *const Session) u64 {
                return self.state.flow_id;
            }

            pub fn setDatagramHandler(self: *Session, handler: http.handler.OnWebTransportDatagram) void {
                self.state.on_datagram = handler;
            }

            pub fn setUniOpenHandler(self: *Session, handler: http.handler.OnWebTransportUniOpen) errors.WebTransportError!void {
                if (!self.server.wt.enable_streams) return error.InvalidState;
                self.state.on_uni_open = handler;
            }

            pub fn setBidiOpenHandler(self: *Session, handler: http.handler.OnWebTransportBidiOpen) errors.WebTransportError!void {
                if (!self.server.wt.enable_streams) return error.InvalidState;
                if (!self.server.wt.enable_bidi) return error.InvalidState;
                self.state.on_bidi_open = handler;
            }

            pub fn setStreamDataHandler(self: *Session, handler: http.handler.OnWebTransportStreamData) errors.WebTransportError!void {
                if (!self.server.wt.enable_streams) return error.InvalidState;
                self.state.on_stream_data = handler;
            }

            pub fn setStreamClosedHandler(self: *Session, handler: http.handler.OnWebTransportStreamClosed) errors.WebTransportError!void {
                if (!self.server.wt.enable_streams) return error.InvalidState;
                self.state.on_stream_closed = handler;
            }

            pub fn sendDatagram(self: *Session, payload: []const u8) errors.WebTransportError!void {
                if (payload.len == 0) return;
                self.state.session.sendDatagram(payload) catch |err| {
                    return mapDatagramError(err);
                };
                self.server.wt.dgrams_sent += 1;
                self.state.last_activity_ms = std.time.milliTimestamp();
            }

            pub fn openUniStream(self: *Session) errors.WebTransportStreamError!*Stream {
                if (!self.server.wt.enable_streams) return error.InvalidState;
                const wt_stream = self.server.WT.openWtUniStream(self.conn, self.state) catch |err| {
                    return mapStreamError(err);
                };
                return self.ensureStreamWrapper(wt_stream);
            }

            pub fn openBidiStream(self: *Session) errors.WebTransportStreamError!*Stream {
                if (!self.server.wt.enable_streams) return error.InvalidState;
                if (!self.server.wt.enable_bidi) return error.InvalidState;
                const wt_stream = self.server.WT.openWtBidiStream(self.conn, self.state) catch |err| {
                    return mapStreamError(err);
                };
                return self.ensureStreamWrapper(wt_stream);
            }

            pub fn ensureStreamWrapper(self: *Session, wt_stream: *h3.WebTransportSession.WebTransportStream) errors.WebTransportStreamError!*Stream {
                if (wt_stream.user_data) |ptr| {
                    return @ptrCast(@alignCast(ptr));
                }
                const wrapper = try self.server.allocator.create(Stream);
                wrapper.* = .{
                    .server = self.server,
                    .conn = self.conn,
                    .session_state = self.state,
                    .stream = wt_stream,
                };
                wt_stream.user_data = wrapper;
                return wrapper;
            }

            pub fn asAnyOpaque(self: *Session) *anyopaque {
                return @ptrCast(self);
            }

            pub fn accept(self: *Session, options: AcceptOptions) errors.WebTransportError!void {
                const req_state = self.request_state orelse return error.InvalidState;
                if (req_state.wt_handshake_state != .pending) return error.InvalidState;

                req_state.response.finishWebTransportConnect(req_state.wt_flow_id, .{
                    .send_legacy_accept = options.send_legacy_accept,
                    .extra_capsules = options.extra_capsules,
                }) catch |err| return mapSessionError(err);

                req_state.wt_handshake_state = .accepted;
                self.state.last_activity_ms = std.time.milliTimestamp();

                if (options.send_legacy_accept) {
                    self.server.recordLegacySessionAccept();
                }
                for (options.extra_capsules) |cap| {
                    self.server.recordCapsuleSent(cap);
                }
            }

            pub fn reject(self: *Session, options: RejectOptions) errors.WebTransportError!void {
                const req_state = self.request_state orelse return error.InvalidState;
                if (req_state.wt_handshake_state != .pending) return error.InvalidState;

                req_state.response.rejectConnect(options.status) catch |err| return mapSessionError(err);
                req_state.wt_handshake_state = .rejected;
            }

            pub fn sendCapsule(self: *Session, capsule: wt_capsules.Capsule) errors.WebTransportError!void {
                const req_state = self.request_state orelse return error.InvalidState;
                if (req_state.wt_handshake_state != .accepted) return error.InvalidState;

                req_state.response.sendWebTransportCapsule(capsule) catch |err| return mapSessionError(err);
                self.server.recordCapsuleSent(capsule);
                self.state.last_activity_ms = std.time.milliTimestamp();
            }

            pub fn close(self: *Session, options: CloseOptions) errors.WebTransportError!void {
                const req_state = self.request_state orelse return error.InvalidState;
                if (req_state.wt_handshake_state != .accepted) return error.InvalidState;

                const capsule = wt_capsules.Capsule{ .close_session = .{
                    .application_error_code = options.code,
                    .reason = options.reason,
                } };

                req_state.response.sendWebTransportClose(options.code, options.reason) catch |err| return mapSessionError(err);
                self.server.recordCapsuleSent(capsule);
                self.state.last_activity_ms = std.time.milliTimestamp();
            }
        };

        pub const Stream = struct {
            server: *Self,
            conn: *connection.Connection,
            session_state: *h3.WebTransportSessionState,
            stream: *h3.WebTransportSession.WebTransportStream,

            pub fn fromOpaque(ptr: *anyopaque) *Stream {
                return @ptrCast(@alignCast(ptr));
            }

            pub fn id(self: *const Stream) u64 {
                return self.stream.stream_id;
            }

            pub fn send(self: *Stream, data: []const u8, fin: bool) errors.WebTransportStreamError!usize {
                return self.server.WT.sendWtStream(self.conn, self.stream, data, fin) catch |err| {
                    return mapStreamError(err);
                };
            }

            pub fn sendAll(self: *Stream, data: []const u8, fin: bool) errors.WebTransportStreamError!void {
                self.server.WT.sendWtStreamAll(self.conn, self.stream, data, fin) catch |err| {
                    return mapStreamError(err);
                };
            }

            pub fn asAnyOpaque(self: *Stream) *anyopaque {
                return @ptrCast(self);
            }
        };

        pub fn createSession(
            server: *Self,
            conn: *connection.Connection,
            req_state: ?*Self.RequestState,
            state: *h3.WebTransportSessionState,
        ) !*Session {
            if (state.session_ctx) |ptr| {
                return @ptrCast(@alignCast(ptr));
            }
            const alloc = server.allocator;
            const session = try alloc.create(Session);
            session.* = .{ .server = server, .conn = conn, .state = state, .request_state = req_state };
            const opaque_ptr: *anyopaque = session.asAnyOpaque();
            state.session_ctx = opaque_ptr;
            state.session.user_data = opaque_ptr;
            return session;
        }

        pub fn sessionFromOpaque(ptr: *anyopaque) *Session {
            return Session.fromOpaque(ptr);
        }

        pub fn streamFromOpaque(ptr: *anyopaque) *Stream {
            return Stream.fromOpaque(ptr);
        }

        pub fn destroyStreamWrapper(server: *Self, wt_stream: *h3.WebTransportSession.WebTransportStream) void {
            if (wt_stream.user_data) |ptr| {
                const wrapper: *Stream = @ptrCast(@alignCast(ptr));
                wt_stream.user_data = null;
                server.allocator.destroy(wrapper);
            }
        }

        fn mapDatagramError(err: anyerror) errors.WebTransportError {
            switch (err) {
                error.SessionClosed => return error.SessionClosed,
                error.DatagramTooLarge, error.DatagramNotEnabled => return error.InvalidState,
                error.WouldBlock, error.Done => return error.WouldBlock,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidState,
            }
        }

        fn mapStreamError(err: anyerror) errors.WebTransportStreamError {
            switch (err) {
                error.StreamLimit => return error.InvalidState,
                error.FeatureDisabled => return error.InvalidState,
                error.FlowControl => return error.FlowControl,
                error.WouldBlock, error.Done => return error.WouldBlock,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidState,
            }
        }

        fn mapSessionError(err: anyerror) errors.WebTransportError {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.WouldBlock => error.WouldBlock,
                else => error.InvalidState,
            };
        }
    };
}

const TestServer = struct {
    allocator: std.mem.Allocator,
    wt: struct {
        enable_streams: bool = true,
        enable_bidi: bool = true,
        dgrams_sent: usize = 0,
        capsules_sent_total: usize = 0,
        legacy_session_accept_sent: usize = 0,
        capsules_sent: struct {
            close_session: usize = 0,
            drain_session: usize = 0,
            wt_max_streams_bidi: usize = 0,
            wt_max_streams_uni: usize = 0,
            wt_streams_blocked_bidi: usize = 0,
            wt_streams_blocked_uni: usize = 0,
            wt_max_data: usize = 0,
            wt_data_blocked: usize = 0,
        } = .{},
    } = .{},

    const WithWT = true;
    const DummyHandshakeState = enum { pending, accepted, rejected };

    const DummyResponse = struct {
        accept_calls: usize = 0,
        reject_calls: usize = 0,
        capsule_calls: usize = 0,
        close_calls: usize = 0,

        fn finishWebTransportConnect(
            self: *@This(),
            _flow_id: ?u64,
            _options: http.response.Response.WebTransportAcceptOptions,
        ) !void {
            _ = _flow_id;
            _ = _options;
            self.accept_calls += 1;
        }

        fn rejectConnect(self: *@This(), _status: u16) !void {
            _ = _status;
            self.reject_calls += 1;
        }

        fn sendWebTransportCapsule(self: *@This(), _capsule: wt_capsules.Capsule) !void {
            _ = _capsule;
            self.capsule_calls += 1;
        }

        fn sendWebTransportClose(self: *@This(), _code: u32, _reason: []const u8) !void {
            _ = _code;
            _ = _reason;
            self.close_calls += 1;
        }
    };

    pub const RequestState = struct {
        wt_handshake_state: DummyHandshakeState = .pending,
        wt_flow_id: ?u64 = 42,
        response: DummyResponse = .{},
    };

    fn recordLegacySessionAccept(self: *TestServer) void {
        self.wt.capsules_sent_total += 1;
        self.wt.legacy_session_accept_sent += 1;
    }

    fn recordCapsuleSent(self: *TestServer, capsule: wt_capsules.Capsule) void {
        self.wt.capsules_sent_total += 1;
        switch (capsule) {
            .close_session => self.wt.capsules_sent.close_session += 1,
            .drain_session => self.wt.capsules_sent.drain_session += 1,
            .max_streams => |m| {
                if (m.dir == .bidi) {
                    self.wt.capsules_sent.wt_max_streams_bidi += 1;
                } else {
                    self.wt.capsules_sent.wt_max_streams_uni += 1;
                }
            },
            .streams_blocked => |m| {
                if (m.dir == .bidi) {
                    self.wt.capsules_sent.wt_streams_blocked_bidi += 1;
                } else {
                    self.wt.capsules_sent.wt_streams_blocked_uni += 1;
                }
            },
            .max_data => self.wt.capsules_sent.wt_max_data += 1,
            .data_blocked => self.wt.capsules_sent.wt_data_blocked += 1,
        }
    }

    fn recordCapsuleReceived(self: *TestServer, _capsule: wt_capsules.CapsuleType) void {
        _ = self;
        _ = _capsule;
    }
};

const TestApi = Api(TestServer);

test "WT API datagram/stream error mapping" {
    const Dummy = struct {};
    const ApiType = Api(Dummy);

    try std.testing.expectEqual(errors.WebTransportError.SessionClosed, ApiType.mapDatagramError(error.SessionClosed));
    try std.testing.expectEqual(errors.WebTransportError.WouldBlock, ApiType.mapDatagramError(error.WouldBlock));

    try std.testing.expectEqual(errors.WebTransportStreamError.FlowControl, ApiType.mapStreamError(error.FlowControl));
    try std.testing.expectEqual(errors.WebTransportStreamError.WouldBlock, ApiType.mapStreamError(error.WouldBlock));
}

test "WT session handler registration respects toggles and wrappers" {
    const allocator = std.testing.allocator;

    var quic_conn: quiche.Connection = undefined;
    var h3_conn: h3.H3Connection = undefined;
    const headers = [_]quiche.h3.Header{};
    const session = try h3.WebTransportSession.init(allocator, 42, &quic_conn, &h3_conn, "/wt");
    const state = try h3.WebTransportSessionState.init(allocator, session, headers[0..], null);
    defer state.deinit(allocator);
    state.flow_id = 42;

    var conn_obj: connection.Connection = undefined;
    var server = TestServer{ .allocator = allocator };
    const wrapper = try TestApi.createSession(&server, &conn_obj, null, state);

    const Handler = struct {
        fn datagram(sess: *anyopaque, payload: []const u8) errors.WebTransportError!void {
            const session_wrapper = TestApi.sessionFromOpaque(sess);
            try std.testing.expectEqual(@as(u64, 42), session_wrapper.sessionId());
            try std.testing.expectEqualStrings("hi", payload);
        }

        fn uniOpen(sess: *anyopaque, stream: *anyopaque) errors.WebTransportStreamError!void {
            const session_wrapper = TestApi.sessionFromOpaque(sess);
            const stream_wrapper = TestApi.streamFromOpaque(stream);
            try std.testing.expectEqual(session_wrapper.sessionId(), stream_wrapper.session_state.session.session_id);
        }

        fn data(stream: *anyopaque, payload: []const u8, fin: bool) errors.WebTransportStreamError!void {
            const stream_wrapper = TestApi.streamFromOpaque(stream);
            try std.testing.expectEqual(@as(u64, 7), stream_wrapper.id());
            try std.testing.expectEqualStrings("payload", payload);
            try std.testing.expect(fin);
        }

        fn closed(stream: *anyopaque) void {
            const stream_wrapper = TestApi.streamFromOpaque(stream);
            std.testing.expectEqual(@as(u64, 7), stream_wrapper.id()) catch unreachable;
        }
    };

    wrapper.setDatagramHandler(Handler.datagram);
    try std.testing.expect(wrapper.state.on_datagram != null);
    try wrapper.state.on_datagram.?(wrapper.asAnyOpaque(), "hi");

    try wrapper.setUniOpenHandler(Handler.uniOpen);
    try wrapper.setStreamDataHandler(Handler.data);
    try wrapper.setStreamClosedHandler(Handler.closed);

    var stream = h3.WebTransportSession.WebTransportStream{
        .stream_id = 7,
        .dir = .uni,
        .role = .incoming,
        .session_id = 42,
        .allocator = allocator,
    };

    const stream_wrapper = try wrapper.ensureStreamWrapper(&stream);
    try std.testing.expectEqual(stream_wrapper, TestApi.streamFromOpaque(stream.user_data.?));
    const stream_wrapper_again = try wrapper.ensureStreamWrapper(&stream);
    try std.testing.expectEqual(stream_wrapper, stream_wrapper_again);
    try wrapper.state.on_stream_data.?(stream_wrapper.asAnyOpaque(), "payload", true);

    TestApi.destroyStreamWrapper(&server, &stream);
    try std.testing.expect(stream.user_data == null);

    // Streams disabled should yield InvalidState
    var server_no_streams = TestServer{ .allocator = allocator, .wt = .{ .enable_streams = false, .enable_bidi = true, .dgrams_sent = 0 } };
    var quic_conn2: quiche.Connection = undefined;
    var h3_conn2: h3.H3Connection = undefined;
    const session2 = try h3.WebTransportSession.init(allocator, 99, &quic_conn2, &h3_conn2, "/wt");
    const state2 = try h3.WebTransportSessionState.init(allocator, session2, headers[0..], null);
    defer state2.deinit(allocator);
    state2.flow_id = 99;

    var conn_obj2: connection.Connection = undefined;
    const wrapper2 = try TestApi.createSession(&server_no_streams, &conn_obj2, null, state2);
    try std.testing.expectError(error.InvalidState, wrapper2.setUniOpenHandler(Handler.uniOpen));
    try std.testing.expectError(error.InvalidState, wrapper2.setStreamDataHandler(Handler.data));
    try std.testing.expectError(error.InvalidState, wrapper2.setStreamClosedHandler(Handler.closed));
}

test "WT session accept reject and capsule helpers" {
    const allocator = std.testing.allocator;
    var server = TestServer{ .allocator = allocator };
    var conn_obj: connection.Connection = undefined;

    var quic_conn: quiche.Connection = undefined;
    var h3_conn: h3.H3Connection = undefined;
    const headers = [_]quiche.h3.Header{};
    const session2 = try h3.WebTransportSession.init(allocator, 24, &quic_conn, &h3_conn, "/wt");
    const state2 = try h3.WebTransportSessionState.init(allocator, session2, headers[0..], null);
    defer state2.deinit(allocator);
    state2.flow_id = 24;

    var req_state = TestServer.RequestState{};
    const wrapper = try TestApi.createSession(&server, &conn_obj, &req_state, state2);

    try wrapper.accept(.{});
    try std.testing.expectEqual(@as(usize, 1), req_state.response.accept_calls);
    try std.testing.expectEqual(@TypeOf(req_state.wt_handshake_state).accepted, req_state.wt_handshake_state);
    try std.testing.expectError(error.InvalidState, wrapper.accept(.{}));
    try std.testing.expectEqual(@as(usize, 1), server.wt.legacy_session_accept_sent);
    try std.testing.expectEqual(@as(usize, 1), server.wt.capsules_sent_total);

    try wrapper.sendCapsule(.{ .max_data = .{ .maximum = 1 } });
    try std.testing.expectEqual(@as(usize, 1), req_state.response.capsule_calls);
    try std.testing.expectEqual(@as(usize, 2), server.wt.capsules_sent_total);
    try std.testing.expectEqual(@as(usize, 1), server.wt.capsules_sent.wt_max_data);

    try wrapper.close(.{ .code = 7, .reason = "bye" });
    try std.testing.expectEqual(@as(usize, 1), req_state.response.close_calls);
    try std.testing.expectEqual(@as(usize, 3), server.wt.capsules_sent_total);
    try std.testing.expectEqual(@as(usize, 1), server.wt.capsules_sent.close_session);

    var req_state_reject = TestServer.RequestState{};
    req_state_reject.wt_handshake_state = .pending;
    const session3 = try h3.WebTransportSession.init(allocator, 30, &quic_conn, &h3_conn, "/wt");
    const state3 = try h3.WebTransportSessionState.init(allocator, session3, headers[0..], null);
    defer state3.deinit(allocator);
    state3.flow_id = 30;

    const wrapper2 = try TestApi.createSession(&server, &conn_obj, &req_state_reject, state3);
    try wrapper2.reject(.{ .status = 404 });
    try std.testing.expectEqual(@as(usize, 1), req_state_reject.response.reject_calls);
    try std.testing.expectEqual(@TypeOf(req_state_reject.wt_handshake_state).rejected, req_state_reject.wt_handshake_state);

    try std.testing.expectError(error.InvalidState, wrapper2.sendCapsule(.{ .max_data = .{ .maximum = 1 } }));
}
