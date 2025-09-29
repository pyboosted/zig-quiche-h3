const std = @import("std");
const builtin = @import("builtin");
const quiche = @import("quiche");
const client_cfg = @import("config.zig");
const EventLoop = @import("event_loop").EventLoop;
const TimerHandle = @import("event_loop").TimerHandle;
const udp = @import("udp");
const connection = @import("connection");
const server_pkg = if (builtin.is_test) @import("server") else struct {};
const ServerConfig = @import("config").ServerConfig;
const routing_api = @import("routing");
const logging = @import("logging.zig");
const http = @import("http");
const wt_capsules = http.webtransport_capsules;

const client_state = @import("state.zig");
const client_errors = @import("errors.zig");

const AutoHashMap = std.AutoHashMap;

const h3 = @import("h3");

const posix = std.posix;
const QuicheError = quiche.QuicheError;
const QuicServer = if (builtin.is_test) server_pkg.QuicServer else struct {};
const H3Connection = h3.H3Connection;
const H3Config = h3.H3Config;
const h3_datagram = h3.datagram;
const webtransport = @import("webtransport.zig");
const lifecycle = @import("lifecycle.zig");
const h3_core = @import("h3_core.zig");
const datagram = @import("datagram.zig");
const webtransport_core = @import("webtransport_core.zig");
const event_loop_core = @import("event_loop_core.zig");

pub const ClientError = client_errors.ClientError;
pub const HeaderPair = client_state.HeaderPair;
pub const ResponseEvent = client_state.ResponseEvent;
pub const DatagramEvent = client_state.DatagramEvent;
pub const ResponseCallback = client_state.ResponseCallback;
pub const BodyChunkResult = client_state.BodyChunkResult;
pub const RequestBodyProvider = client_state.RequestBodyProvider;
pub const FetchOptions = client_state.FetchOptions;
pub const FetchResponse = client_state.FetchResponse;

pub const ClientConfig = client_cfg.ClientConfig;
pub const ServerEndpoint = client_cfg.ServerEndpoint;

const State = enum { idle, connecting, established, closed };

pub const FetchState = struct {
    allocator: std.mem.Allocator,
    stream_id: u64 = 0,
    timeout_override_ms: ?u32 = null,
    status: ?u16 = null,
    body_chunks: std.array_list.Managed(u8),
    finished: bool = false,
    err: ?ClientError = null,
    awaiting: bool = false,
    collect_body: bool = true,
    response_callback: ?ResponseCallback = null,
    response_ctx: ?*anyopaque = null,
    body_buffer: []const u8 = &.{},
    body_sent: usize = 0,
    content_length: ?usize = null,
    bytes_received: usize = 0,
    body_owned: bool = false,
    body_finished: bool = true,
    body_provider: ?RequestBodyProvider = null,
    provider_done: bool = true,
    headers: std.array_list.Managed(HeaderPair),
    trailers: std.array_list.Managed(HeaderPair),
    have_headers: bool = false,

    // WebTransport extensions - reusing existing state machine
    is_webtransport: bool = false,
    wt_session: ?*webtransport.WebTransportSession = null,
    wt_datagrams_received: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !*FetchState {
        const self = try allocator.create(FetchState);
        self.* = .{
            .allocator = allocator,
            .stream_id = 0,
            .timeout_override_ms = null,
            .status = null,
            .body_chunks = std.array_list.Managed(u8).init(allocator),
            .finished = false,
            .err = null,
            .awaiting = false,
            .collect_body = true,
            .response_callback = null,
            .response_ctx = null,
            .body_buffer = &.{},
            .body_sent = 0,
            .body_owned = false,
            .body_finished = true,
            .body_provider = null,
            .provider_done = true,
            .headers = std.array_list.Managed(HeaderPair).init(allocator),
            .trailers = std.array_list.Managed(HeaderPair).init(allocator),
            .have_headers = false,
            .content_length = null,
            .bytes_received = 0,
        };
        return self;
    }

    pub fn hasPendingBody(self: *FetchState) bool {
        const pending_buffer = self.body_buffer.len > self.body_sent;
        return pending_buffer or !self.provider_done;
    }

    pub fn takeBody(self: *FetchState) ![]u8 {
        if (!self.collect_body) {
            return try self.allocator.alloc(u8, 0);
        }
        return self.body_chunks.toOwnedSlice();
    }

    pub fn destroy(self: *FetchState) void {
        self.body_chunks.deinit();
        if (self.body_owned and self.body_buffer.len > 0) {
            self.allocator.free(@constCast(self.body_buffer));
        }
        self.destroyHeaderList(&self.headers);
        self.destroyHeaderList(&self.trailers);
        self.allocator.destroy(self);
    }

    fn destroyHeaderList(self: *FetchState, list: *std.array_list.Managed(HeaderPair)) void {
        for (list.items) |pair| {
            self.allocator.free(pair.name);
            self.allocator.free(pair.value);
        }
        list.deinit();
    }
};

pub const FetchHandle = struct {
    client: *QuicClient,
    stream_id: u64,

    pub fn isFinished(self: FetchHandle) bool {
        const state = self.client.requests.get(self.stream_id) orelse return true;
        return state.finished;
    }

    pub fn await(self: FetchHandle) ClientError!FetchResponse {
        const client = self.client;
        const state = client.requests.get(self.stream_id) orelse return ClientError.ResponseIncomplete;

        // Add timeout tracking
        const start_time = std.time.milliTimestamp();
        const timeout_ms = client.config.request_timeout_ms;
        const effective_timeout = state.timeout_override_ms orelse timeout_ms;

        const debug_enabled = client.config.enable_debug_logging;

        while (!state.finished and state.err == null) {
            if (debug_enabled) {
                if (state.err) |e| {
                    std.debug.print("[await] state err={s}\n", .{@errorName(e)});
                }
            }
            // Check timeout
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > effective_timeout) {
                if (debug_enabled) {
                    std.debug.print("[await] timeout hit (elapsed={d}ms, timeout={d}ms)\n", .{ elapsed, effective_timeout });
                }
                client.cancelFetch(self.stream_id, ClientError.RequestTimeout);
                return ClientError.RequestTimeout;
            }

            state.awaiting = true;
            defer state.awaiting = false;

            // Run event loop once with a short internal timeout to check conditions
            client.event_loop.runOnce();

            if (debug_enabled) {
                std.debug.print(
                    "[await] loop stream={d} finished={s} have_headers={s} err={s} bytes={d}\n",
                    .{
                        self.stream_id,
                        if (state.finished) "true" else "false",
                        if (state.have_headers) "true" else "false",
                        if (state.err) |e| @errorName(e) else "null",
                        state.bytes_received,
                    },
                );
            }
        }

        return client.finalizeFetch(self.stream_id);
    }

    pub fn finalizeReady(self: FetchHandle) ClientError!FetchResponse {
        if (!self.isFinished()) return ClientError.ResponseIncomplete;
        return self.client.finalizeFetch(self.stream_id);
    }
};

pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    quiche_config: quiche.Config,
    h3_config: H3Config,
    event_loop: *EventLoop,

    socket: ?udp.UdpSocket = null,
    conn: ?quiche.Connection = null,
    h3_conn: ?H3Connection = null,

    remote_addr: posix.sockaddr.storage = undefined,
    remote_addr_len: posix.socklen_t = 0,
    local_addr: posix.sockaddr.storage = undefined,
    local_addr_len: posix.socklen_t = 0,

    timeout_timer: ?TimerHandle = null,
    connect_timer: ?TimerHandle = null,

    state: State = .idle,
    handshake_error: ?ClientError = null,

    send_buf: [2048]u8 = undefined,
    recv_buf: [2048]u8 = undefined,
    datagram_buf: [2048]u8 = undefined,

    qlog_path: ?[:0]u8 = null,
    keylog_path: ?[:0]u8 = null,

    io_registered: bool = false,
    current_scid: ?[16]u8 = null,

    server_host: ?[]u8 = null,
    server_authority: ?[]u8 = null,
    server_port: ?u16 = null,
    server_sni: ?[]u8 = null, // Store SNI for reconnection

    log_context: ?*logging.LogContext = null,

    requests: AutoHashMap(u64, *FetchState),

    // WebTransport sessions (stream_id -> session)
    wt_sessions: AutoHashMap(u64, *webtransport.WebTransportSession),
    // Active WebTransport streams (stream_id -> stream wrapper)
    wt_streams: AutoHashMap(u64, *webtransport.WebTransportSession.Stream),

    // Plain QUIC datagram callback
    on_quic_datagram: ?*const fn (client: *QuicClient, payload: []const u8, user: ?*anyopaque) void = null,
    on_quic_datagram_user: ?*anyopaque = null,

    // Datagram metrics (matching server)
    datagram_stats: struct {
        sent: u64 = 0,
        received: u64 = 0,
        dropped_send: u64 = 0,
    } = .{},

    wt_capsules_sent_total: usize = 0,
    wt_capsules_received_total: usize = 0,
    wt_legacy_session_accept_received: usize = 0,
    wt_capsules_sent: struct {
        close_session: usize = 0,
        drain_session: usize = 0,
        wt_max_streams_bidi: usize = 0,
        wt_max_streams_uni: usize = 0,
        wt_streams_blocked_bidi: usize = 0,
        wt_streams_blocked_uni: usize = 0,
        wt_max_data: usize = 0,
        wt_data_blocked: usize = 0,
    } = .{},
    wt_capsules_received: struct {
        close_session: usize = 0,
        drain_session: usize = 0,
        wt_max_streams_bidi: usize = 0,
        wt_max_streams_uni: usize = 0,
        wt_streams_blocked_bidi: usize = 0,
        wt_streams_blocked_uni: usize = 0,
        wt_max_data: usize = 0,
        wt_data_blocked: usize = 0,
    } = .{},

    // GOAWAY state tracking
    goaway_received: bool = false,
    goaway_stream_id: ?u64 = null, // Last accepted request stream ID from server

    // GOAWAY callback (runs on event loop thread)
    on_goaway: ?*const fn (client: *QuicClient, last_stream_id: u64, user: ?*anyopaque) void = null,
    on_goaway_user: ?*anyopaque = null,

    // Track most recent request stream ID for comparison
    last_request_stream_id: ?u64 = null,
    next_wt_uni_stream_id: u64 = 0,
    next_wt_bidi_stream_id: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: ClientConfig) !*QuicClient {
        return Lifecycle.init(allocator, cfg);
    }

    pub fn deinit(self: *QuicClient) void {
        Lifecycle.deinit(self);
    }

    pub fn connect(self: *QuicClient, endpoint: ServerEndpoint) ClientError!void {
        return Lifecycle.connect(self, endpoint);
    }

    pub fn isEstablished(self: *const QuicClient) bool {
        return Lifecycle.isEstablished(self);
    }

    pub fn reconnect(self: *QuicClient) ClientError!void {
        return Lifecycle.reconnect(self);
    }

    pub fn stopConnectTimer(self: *QuicClient) void {
        Lifecycle.stopConnectTimer(self);
    }

    pub fn requireConn(self: *QuicClient) ClientError!*quiche.Connection {
        return Lifecycle.requireConn(self);
    }

    pub fn ensureH3(self: *QuicClient) !void {
        return H3Core.ensureH3(self);
    }

    pub fn ensureH3DatagramNegotiated(self: *QuicClient) ClientError!void {
        return H3Core.ensureH3DatagramNegotiated(self);
    }

    pub fn loadNextBodyChunk(self: *QuicClient, state: *FetchState) !void {
        return H3Core.loadNextBodyChunk(self, state);
    }

    pub fn trySendBody(self: *QuicClient, stream_id: u64, state: *FetchState) ClientError!bool {
        return H3Core.trySendBody(self, stream_id, state);
    }

    pub fn emitEvent(self: *QuicClient, state: *FetchState, event: ResponseEvent) bool {
        return H3Core.emitEvent(self, state, event);
    }

    pub fn sendPendingBodies(self: *QuicClient) void {
        H3Core.sendPendingBodies(self);
    }

    fn finalizeFetch(self: *QuicClient, stream_id: u64) ClientError!FetchResponse {
        return H3Core.finalizeFetch(self, stream_id);
    }

    pub fn prepareRequestHeaders(self: *QuicClient, options: FetchOptions) ClientError![]quiche.h3.Header {
        return H3Core.prepareRequestHeaders(self, options);
    }

    pub fn startRequest(self: *QuicClient, allocator: std.mem.Allocator, options: FetchOptions) ClientError!FetchHandle {
        return H3Core.startRequest(self, allocator, options);
    }

    pub fn setupQlog(self: *QuicClient, conn_id: []const u8) ClientError!void {
        return Lifecycle.setupQlog(self, conn_id);
    }

    pub fn rememberEndpoint(self: *QuicClient, endpoint: ServerEndpoint) ClientError!void {
        return Lifecycle.rememberEndpoint(self, endpoint);
    }

    pub fn sendH3Datagram(self: *QuicClient, stream_id: u64, payload: []const u8) ClientError!void {
        return Datagram.sendH3Datagram(self, stream_id, payload);
    }

    pub fn onQuicDatagram(
        self: *QuicClient,
        cb: *const fn (client: *QuicClient, payload: []const u8, user: ?*anyopaque) void,
        user: ?*anyopaque,
    ) void {
        Datagram.onQuicDatagram(self, cb, user);
    }

    pub fn sendQuicDatagram(self: *QuicClient, payload: []const u8) ClientError!void {
        return Datagram.sendQuicDatagram(self, payload);
    }

    pub fn processDatagrams(self: *QuicClient) void {
        Datagram.processDatagrams(self);
    }

    fn processH3Datagram(self: *QuicClient, payload: []const u8) !bool {
        return Datagram.processH3Datagram(self, payload);
    }

    pub fn onGoaway(
        self: *QuicClient,
        cb: *const fn (client: *QuicClient, last_stream_id: u64, user: ?*anyopaque) void,
        user: ?*anyopaque,
    ) void {
        self.on_goaway = cb;
        self.on_goaway_user = user;
    }

    pub fn openWebTransport(self: *QuicClient, path: []const u8) ClientError!*webtransport.WebTransportSession {
        return WebTransportCore.openWebTransport(self, path);
    }

    pub fn recordLegacySessionAcceptReceived(self: *QuicClient) void {
        WebTransportCore.recordLegacySessionAcceptReceived(self);
    }

    pub fn recordCapsuleReceived(self: *QuicClient, capsule: wt_capsules.CapsuleType) void {
        WebTransportCore.recordCapsuleReceived(self, capsule);
    }

    pub fn recordCapsuleSent(self: *QuicClient, capsule: wt_capsules.Capsule) void {
        WebTransportCore.recordCapsuleSent(self, capsule);
    }

    pub fn processReadableWtStreams(self: *QuicClient) void {
        WebTransportCore.processReadableWtStreams(self);
    }

    pub fn processWritableWtStreams(self: *QuicClient) void {
        WebTransportCore.processWritableWtStreams(self);
    }

    pub fn markWebTransportSessionClosed(self: *QuicClient, stream_id: u64) void {
        WebTransportCore.markWebTransportSessionClosed(self, stream_id);
    }

    pub fn cleanupWebTransportSession(self: *QuicClient, stream_id: u64) void {
        WebTransportCore.cleanupWebTransportSession(self, stream_id);
    }

    pub fn ensureStreamWritable(self: *QuicClient, stream_id: u64, hint: usize) void {
        WebTransportCore.ensureStreamWritable(self, stream_id, hint);
    }

    pub fn allocLocalStreamId(
        self: *QuicClient,
        dir: h3.WebTransportSession.StreamDir,
    ) ClientError!u64 {
        return WebTransportCore.allocLocalStreamId(self, dir);
    }

    pub fn updateStreamIndicesFor(self: *QuicClient, stream_id: u64) void {
        WebTransportCore.updateStreamIndicesFor(self, stream_id);
    }

    pub fn fetch(self: *QuicClient, allocator: std.mem.Allocator, path: []const u8) ClientError!FetchResponse {
        return self.fetchWithOptions(allocator, .{ .path = path });
    }

    pub fn fetchWithOptions(self: *QuicClient, allocator: std.mem.Allocator, options: FetchOptions) ClientError!FetchResponse {
        const handle = try self.startRequest(allocator, options);
        return handle.await();
    }

    pub fn startGet(self: *QuicClient, allocator: std.mem.Allocator, path: []const u8) ClientError!FetchHandle {
        return self.startRequest(allocator, .{ .path = path });
    }

    /// Check if client is idle (no active requests or WebTransport sessions)
    /// Note: This only checks active request/session maps, not pending body providers or timers.
    pub fn isIdle(self: *QuicClient) bool {
        return self.requests.count() == 0 and self.wt_sessions.count() == 0;
    }

    /// Fetch with automatic retry on transient failures
    /// Note: Requests with streaming body_provider are NOT supported as the
    /// provider will be exhausted after the first attempt. This method will
    /// return an error if a body_provider is specified.
    pub fn fetchWithRetry(
        self: *QuicClient,
        allocator: std.mem.Allocator,
        options: FetchOptions,
        max_retries: u32,
    ) ClientError!FetchResponse {
        // Reject if body_provider is present (can't retry streaming bodies)
        if (options.body_provider != null) {
            return ClientError.InvalidRequest;
        }

        var attempt: u32 = 0;
        while (attempt < max_retries) : (attempt += 1) {
            const result = self.fetchWithOptions(allocator, options) catch |err| {
                // On last attempt, return the error
                if (attempt == max_retries - 1) return err;

                // Retry on specific transient errors
                switch (err) {
                    ClientError.ConnectionClosed, ClientError.StreamReset, ClientError.HandshakeTimeout, ClientError.QuicSendFailed, ClientError.QuicRecvFailed => {
                        // Try to reconnect and retry
                        self.reconnect() catch |reconnect_err| {
                            // If reconnect fails on last retry attempt, return that error
                            if (attempt == max_retries - 2) return reconnect_err;
                            // Otherwise continue to next retry
                            continue;
                        };
                        continue;
                    },
                    else => return err, // Non-transient error, fail immediately
                }
            };
            return result;
        }
        unreachable;
    }

    fn handleReadable(self: *QuicClient, fd: posix.socket_t) ClientError!void {
        return EventLoopCore.handleReadable(self, fd);
    }

    pub fn flushSend(self: *QuicClient) ClientError!void {
        return EventLoopCore.flushSend(self);
    }

    fn handleTimeout(self: *QuicClient) ClientError!void {
        return EventLoopCore.handleTimeout(self);
    }

    pub fn afterQuicProgress(self: *QuicClient) void {
        EventLoopCore.afterQuicProgress(self);
    }

    fn updateTimeout(self: *QuicClient) void {
        EventLoopCore.updateTimeout(self);
    }

    fn checkHandshakeState(self: *QuicClient) void {
        EventLoopCore.checkHandshakeState(self);
    }

    fn stopTimeoutTimer(self: *QuicClient) void {
        EventLoopCore.stopTimeoutTimer(self);
    }

    fn processH3Events(self: *QuicClient) void {
        EventLoopCore.processH3Events(self);
    }

    pub fn onH3Headers(self: *QuicClient, stream_id: u64, event: *quiche.c.quiche_h3_event) void {
        const state = self.requests.get(stream_id) orelse return;

        const headers = h3.collectHeaders(state.allocator, event) catch {
            self.failFetch(stream_id, ClientError.H3Error);
            return;
        };
        defer state.allocator.free(headers);

        const is_trailer = state.have_headers;
        if (self.config.enable_debug_logging) {
            std.debug.print(
                "[client] headers stream={d} trailer={s} count={d}\n",
                .{ stream_id, if (is_trailer) "true" else "false", headers.len },
            );
        }
        var dest = if (is_trailer) &state.trailers else &state.headers;
        for (headers) |header| {
            if (!is_trailer and std.mem.eql(u8, header.name, ":status")) {
                const parsed = std.fmt.parseUnsigned(u16, header.value, 10) catch {
                    self.failFetch(stream_id, ClientError.H3Error);
                    return;
                };
                state.status = parsed;

                if (self.config.enable_debug_logging) {
                    std.debug.print("[client] status stream={d} value={d}\n", .{ stream_id, parsed });
                }

                // Handle WebTransport CONNECT response
                if (state.is_webtransport and state.wt_session != null) {
                    state.wt_session.?.handleConnectResponse(parsed);

                    if (parsed == 200) {
                        // Success: Keep FetchState alive for datagram routing
                        // The FetchState will be cleaned up when the session closes
                        // or when the client deinits
                        state.finished = true;
                    } else {
                        // Failure: trigger failFetch to clean up properly
                        // This will mark session as closed and remove FetchState
                        self.failFetch(stream_id, ClientError.H3Error);
                        return;
                    }
                }
            } else if (!is_trailer and std.mem.eql(u8, header.name, "content-length")) {
                const len = std.fmt.parseUnsigned(usize, header.value, 10) catch {
                    // Invalid content-length, ignore
                    continue;
                };
                state.content_length = len;
            }
            dest.append(.{ .name = header.name, .value = header.value }) catch {
                self.failFetch(stream_id, ClientError.H3Error);
                return;
            };
        }

        if (!is_trailer) {
            state.have_headers = true;
            if (self.config.enable_debug_logging) {
                std.debug.print("[client] emit headers stream={d} total={d}\n", .{ stream_id, state.headers.items.len });
            }
            _ = self.emitEvent(state, ResponseEvent{ .headers = state.headers.items });
            if (!quiche.h3.eventHeadersHasMoreFrames(event)) {
                if (self.conn) |*conn_ref| {
                    if (conn_ref.streamFinished(stream_id)) {
                        if (!state.finished) {
                            self.onH3Finished(stream_id);
                        }
                    }
                }
            }
        } else {
            if (self.config.enable_debug_logging) {
                std.debug.print("[client] emit trailers stream={d} total={d}\n", .{ stream_id, state.trailers.items.len });
            }
            _ = self.emitEvent(state, ResponseEvent{ .trailers = state.trailers.items });
        }
    }

    pub fn onH3Data(self: *QuicClient, stream_id: u64) void {
        const state = self.requests.get(stream_id) orelse return;

        const conn = if (self.conn) |*conn_ref| conn_ref else return;
        const h3_conn_ptr = blk: {
            if (self.h3_conn) |*ptr| break :blk ptr;
            return;
        };
        var chunk: [2048]u8 = undefined;
        var total_received: usize = 0;

        while (true) {
            const read = h3_conn_ptr.recvBody(conn, stream_id, chunk[0..]) catch |err| switch (err) {
                quiche.h3.Error.Done => {
                    // No more data available right now, but stream might not be finished
                    break;
                },
                else => {
                    self.failFetch(stream_id, ClientError.H3Error);
                    return;
                },
            };
            if (read == 0) {
                break;
            }
            total_received += read;
            state.bytes_received += read;

            if (self.config.enable_debug_logging) {
                std.debug.print(
                    "[client] data stream={d} read={d} total={d}\n",
                    .{ stream_id, read, state.bytes_received },
                );
            }
            const slice = chunk[0..read];
            if (state.is_webtransport) {
                if (state.wt_session) |session| {
                    session.processCapsuleBytes(slice) catch |err| {
                        self.failFetch(stream_id, err);
                        return;
                    };
                }
            } else if (state.collect_body) {
                state.body_chunks.appendSlice(slice) catch {
                    self.failFetch(stream_id, ClientError.H3Error);
                    return;
                };
            }

            if (!self.emitEvent(state, ResponseEvent{ .data = slice })) {
                return;
            }
        }

        // Check if we've received all expected data based on content-length
        if (state.content_length) |expected_len| {
            if (state.bytes_received >= expected_len) {
                if (!state.finished) {
                    // We've received all expected bytes, mark as finished
                    self.onH3Finished(stream_id);
                    return;
                }
            }
        }

        // Check if stream is finished after receiving all available data
        // This is a fallback for when Finished event is not received
        if (!state.is_webtransport and conn.streamFinished(stream_id)) {
            if (self.config.enable_debug_logging) {
                std.debug.print("DEBUG: Stream {} is finished (via streamFinished check)\n", .{stream_id});
            }
            if (!state.finished) {
                // Stream is finished but we didn't get a Finished event
                // Trigger completion manually
                self.onH3Finished(stream_id);
            }
        }
    }

    pub fn onH3Finished(self: *QuicClient, stream_id: u64) void {
        const state = self.requests.get(stream_id) orelse return;
        state.finished = true;
        if (self.config.enable_debug_logging) {
            std.debug.print("[client] finished stream={d}\n", .{stream_id});
        }
        _ = self.emitEvent(state, ResponseEvent.finished);
        if (state.awaiting) self.event_loop.stop();

        // For WebTransport, we keep the FetchState alive for datagram routing
        // It will be cleaned up when the user calls close() on the session
        if (state.is_webtransport) {
            if (state.wt_session) |session| {
                if (session.state != .closed) {
                    session.state = .closed;
                    self.markWebTransportSessionClosed(stream_id);
                }
            }
        }
    }

    pub fn onH3Reset(self: *QuicClient, stream_id: u64) void {
        self.failFetch(stream_id, ClientError.H3Error);
    }

    pub fn onH3GoAway(self: *QuicClient, last_accepted_id: u64) void {
        // Note: The stream_id from poll might be the GOAWAY stream ID,
        // but for HTTP/3 GOAWAY, it represents the last accepted request ID

        // Ignore duplicate GOAWAYs with higher IDs
        if (self.goaway_received) {
            if (self.goaway_stream_id) |existing_id| {
                if (last_accepted_id >= existing_id) return;
            }
        }

        self.goaway_received = true;
        self.goaway_stream_id = last_accepted_id;

        // Notify application callback if registered
        if (self.on_goaway) |cb| {
            cb(self, last_accepted_id, self.on_goaway_user);
        }

        // Cancel all requests with stream_id > last_accepted_id
        // Collect IDs first to avoid iterator invalidation
        var to_cancel = std.ArrayList(u64).initCapacity(self.allocator, self.requests.count()) catch {
            // If we can't allocate, at least mark the state
            return;
        };
        defer to_cancel.deinit(self.allocator);

        var it = self.requests.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* > last_accepted_id) {
                to_cancel.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        // Use failFetch for proper cleanup and event emission
        for (to_cancel.items) |stream_id| {
            self.failFetch(stream_id, ClientError.GoAwayReceived);
        }
    }

    pub fn failFetch(self: *QuicClient, stream_id: u64, err: ClientError) void {
        if (self.requests.get(stream_id)) |state| {
            if (state.err == null) state.err = err;
            state.finished = true;
            _ = self.emitEvent(state, ResponseEvent.finished);
            if (state.awaiting) {
                self.event_loop.stop();
            }

            // Handle WebTransport session cleanup
            if (state.is_webtransport) {
                if (self.wt_sessions.get(stream_id)) |session| {
                    // Mark session as closed so users can observe the failure
                    session.state = .closed;
                    // Note: We keep the session in wt_sessions so that when the user
                    // calls close() on their reference, it will properly free memory
                }

                // Remove and destroy the FetchState for WebTransport
                // WebTransport doesn't use finalizeFetch, so we must clean up here
                _ = self.requests.remove(stream_id);
                state.destroy();
            }
        }
    }

    pub fn cancelFetch(self: *QuicClient, stream_id: u64, err: ClientError) void {
        self.failFetch(stream_id, err);
    }

    pub fn failAll(self: *QuicClient, err: ClientError) void {
        var it = self.requests.iterator();
        while (it.next()) |entry| {
            self.failFetch(entry.key_ptr.*, err);
        }
    }

    pub fn recordFailure(self: *QuicClient, err: ClientError) void {
        if (self.handshake_error == null) {
            self.handshake_error = err;
        }
        self.state = .closed;
        self.stopTimeoutTimer();
        self.stopConnectTimer();
        self.event_loop.stop();
        self.failAll(err);
    }
};

const Lifecycle = lifecycle.Impl(QuicClient);
const H3Core = h3_core.Impl(QuicClient);
const Datagram = datagram.Impl(QuicClient);
const WebTransportCore = webtransport_core.Impl(QuicClient);
const EventLoopCore = event_loop_core.Impl(QuicClient);

const ServerThreadCtx = struct {
    server: *QuicServer,
    err: ?anyerror = null,
};

fn serverThreadMain(ctx: *ServerThreadCtx) void {
    ctx.server.run() catch |err| {
        ctx.err = err;
    };
}

fn chooseTestPort() u16 {
    return 45443;
}

pub fn onUdpReadable(fd: posix.socket_t, _revents: u32, user_data: *anyopaque) void {
    _ = _revents;
    const self: *QuicClient = @ptrCast(@alignCast(user_data));
    if (self.state == .closed) return;
    if (self.config.enable_debug_logging) {
        std.debug.print("[client] readable fd={d} state={s}\n", .{ fd, @tagName(self.state) });
    }
    self.handleReadable(fd) catch |err| self.recordFailure(err);
}

pub fn onQuicTimeout(user_data: *anyopaque) void {
    const self: *QuicClient = @ptrCast(@alignCast(user_data));
    if (self.state == .closed) return;
    self.handleTimeout() catch |err| self.recordFailure(err);
}

pub fn onConnectTimeout(user_data: *anyopaque) void {
    const self: *QuicClient = @ptrCast(@alignCast(user_data));
    if (self.state == .connecting) {
        self.recordFailure(ClientError.HandshakeTimeout);
    }
}
