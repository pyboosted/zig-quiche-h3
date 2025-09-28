const std = @import("std");
const quiche = @import("quiche");
const client_cfg = @import("config.zig");
const connection = @import("connection");
const event_loop = @import("event_loop");
const udp = @import("udp");
const logging = @import("logging.zig");
const client_errors = @import("errors.zig");
const h3 = @import("h3");
const client_mod = @import("mod.zig");
const webtransport = @import("webtransport.zig");

const EventLoop = event_loop.EventLoop;
const H3Config = h3.H3Config;
const ClientConfig = client_cfg.ClientConfig;
const ServerEndpoint = client_cfg.ServerEndpoint;
const ClientError = client_errors.ClientError;

pub fn Impl(comptime ClientType: type) type {
    return struct {
        const Self = ClientType;
        pub fn init(allocator: std.mem.Allocator, cfg: ClientConfig) !*Self {
            try cfg.validate();
            try cfg.ensureQlogDir();

            var q_cfg = try quiche.Config.new(quiche.PROTOCOL_VERSION);
            errdefer q_cfg.deinit();

            const alpn_wire = try quiche.encodeAlpn(allocator, cfg.alpn_protocols);
            defer allocator.free(alpn_wire);
            try q_cfg.setApplicationProtos(alpn_wire);
            q_cfg.setMaxIdleTimeout(cfg.idle_timeout_ms);
            q_cfg.setInitialMaxData(cfg.initial_max_data);
            q_cfg.setInitialMaxStreamDataBidiLocal(cfg.initial_max_stream_data_bidi_local);
            q_cfg.setInitialMaxStreamDataBidiRemote(cfg.initial_max_stream_data_bidi_remote);
            q_cfg.setInitialMaxStreamDataUni(cfg.initial_max_stream_data_uni);
            q_cfg.setInitialMaxStreamsBidi(cfg.initial_max_streams_bidi);
            q_cfg.setInitialMaxStreamsUni(cfg.initial_max_streams_uni);
            q_cfg.setMaxRecvUdpPayloadSize(cfg.max_recv_udp_payload_size);
            q_cfg.setMaxSendUdpPayloadSize(cfg.max_send_udp_payload_size);
            q_cfg.setDisableActiveMigration(cfg.disable_active_migration);
            q_cfg.enablePacing(cfg.enable_pacing);
            if (cfg.enable_dgram) {
                const recv_len = if (cfg.dgram_recv_queue_len == 0) 128 else cfg.dgram_recv_queue_len;
                const send_len = if (cfg.dgram_send_queue_len == 0) 128 else cfg.dgram_send_queue_len;
                q_cfg.enableDgram(true, recv_len, send_len);
            } else {
                q_cfg.enableDgram(false, cfg.dgram_recv_queue_len, cfg.dgram_send_queue_len);
            }
            q_cfg.grease(cfg.grease);

            const cc_algo = try allocator.dupeZ(u8, cfg.cc_algorithm);
            defer allocator.free(cc_algo);
            if (q_cfg.setCcAlgorithmName(cc_algo)) |_| {
                // OK
            } else |err| {
                std.debug.print("[client] cc={s} unsupported ({any}); falling back to cubic\n", .{ cfg.cc_algorithm, err });
                const fallback = try allocator.dupeZ(u8, "cubic");
                defer allocator.free(fallback);
                _ = q_cfg.setCcAlgorithmName(fallback) catch {};
            }

            q_cfg.verifyPeer(cfg.verify_peer);

            if (cfg.verify_peer) {
                if (cfg.ca_bundle_path) |path| {
                    const ca_path_z = try allocator.dupeZ(u8, path);
                    defer allocator.free(ca_path_z);
                    q_cfg.loadVerifyLocationsFromFile(ca_path_z[0..ca_path_z.len :0]) catch |err| {
                        std.debug.print("[client] Failed to load CA bundle from {s}: {}\n", .{ path, err });
                        return error.LoadCABundleFailed;
                    };
                }

                if (cfg.ca_bundle_dir) |dir| {
                    const ca_dir_z = try allocator.dupeZ(u8, dir);
                    defer allocator.free(ca_dir_z);
                    q_cfg.loadVerifyLocationsFromDirectory(ca_dir_z[0..ca_dir_z.len :0]) catch |err| {
                        std.debug.print("[client] Failed to load CA directory from {s}: {}\n", .{ dir, err });
                        return error.LoadCADirectoryFailed;
                    };
                }
            }

            var log_ctx: ?*logging.LogContext = null;
            if (cfg.enable_debug_logging) {
                log_ctx = try allocator.create(logging.LogContext);
                errdefer if (log_ctx) |ctx| allocator.destroy(ctx);
                log_ctx.?.* = logging.LogContext.init(cfg.debug_log_throttle);
                try quiche.enableDebugLogging(logging.debugLogCallback, log_ctx);
            }

            var h3_cfg = if (cfg.enable_webtransport)
                try H3Config.initWithWebTransport()
            else
                try H3Config.initWithDefaults();
            var h3_cfg_cleanup = true;
            errdefer if (h3_cfg_cleanup) h3_cfg.deinit();

            const loop = try EventLoop.initLibev(allocator);
            errdefer loop.deinit();

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .config = cfg,
                .quiche_config = q_cfg,
                .h3_config = h3_cfg,
                .event_loop = loop,
                .socket = null,
                .conn = null,
                .h3_conn = null,
                .remote_addr = undefined,
                .remote_addr_len = 0,
                .local_addr = undefined,
                .local_addr_len = 0,
                .timeout_timer = null,
                .connect_timer = null,
                .state = .idle,
                .handshake_error = null,
                .send_buf = undefined,
                .recv_buf = undefined,
                .qlog_path = null,
                .keylog_path = null,
                .io_registered = false,
                .current_scid = null,
                .server_host = null,
                .server_authority = null,
                .server_port = null,
                .server_sni = null,
                .log_context = log_ctx,
                .requests = std.AutoHashMap(u64, *client_mod.FetchState).init(allocator),
                .wt_sessions = std.AutoHashMap(u64, *webtransport.WebTransportSession).init(allocator),
                .wt_streams = std.AutoHashMap(u64, *webtransport.WebTransportSession.Stream).init(allocator),
                .next_wt_uni_stream_id = 0,
                .next_wt_bidi_stream_id = 0,
            };

            self.timeout_timer = try loop.createTimer(client_mod.onQuicTimeout, self);
            self.connect_timer = try loop.createTimer(client_mod.onConnectTimeout, self);
            h3_cfg_cleanup = false;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.h3_conn) |*h3_conn_ref| {
                h3_conn_ref.deinit();
                self.h3_conn = null;
            }

            self.h3_config.deinit();

            if (self.conn) |*conn_ref| {
                conn_ref.deinit();
                self.conn = null;
            }

            if (self.qlog_path) |path| {
                const total = path.len + 1;
                self.allocator.free(path.ptr[0..total]);
                self.qlog_path = null;
            }

            if (self.keylog_path) |path| {
                const total = path.len + 1;
                self.allocator.free(path.ptr[0..total]);
                self.keylog_path = null;
            }

            if (self.server_host) |host| {
                self.allocator.free(host);
                self.server_host = null;
            }

            if (self.server_authority) |authority| {
                self.allocator.free(authority);
                self.server_authority = null;
            }

            if (self.server_sni) |sni| {
                self.allocator.free(sni);
                self.server_sni = null;
            }

            var it = self.requests.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.destroy();
            }
            self.requests.deinit();

            var wt_it = self.wt_sessions.iterator();
            while (wt_it.next()) |entry| {
                const session = entry.value_ptr.*;
                for (session.datagram_queue.items) |dgram| {
                    self.allocator.free(dgram);
                }
                session.datagram_queue.deinit(self.allocator);
                for (session.pending_datagrams.items) |buf| {
                    self.allocator.free(buf);
                }
                session.pending_datagrams.deinit(self.allocator);
                session.capsule_buffer.deinit(self.allocator);
                var stream_it = session.streams.iterator();
                while (stream_it.next()) |stream_entry| {
                    _ = self.wt_streams.remove(stream_entry.key_ptr.*);
                }
                session.streams.deinit();
                self.allocator.free(session.path);
                self.allocator.destroy(session);
            }
            self.wt_sessions.deinit();
            self.wt_streams.deinit();

            if (self.socket) |*sock| {
                sock.close();
                self.socket = null;
            }

            if (self.timeout_timer) |handle| {
                self.event_loop.destroyTimer(handle);
                self.timeout_timer = null;
            }

            if (self.connect_timer) |handle| {
                self.event_loop.destroyTimer(handle);
                self.connect_timer = null;
            }

            if (self.log_context) |ctx| {
                quiche.enableDebugLogging(null, null) catch {};
                self.allocator.destroy(ctx);
                self.log_context = null;
            }

            self.event_loop.deinit();
            self.quiche_config.deinit();
            self.allocator.destroy(self);
        }

        pub fn connect(self: *Self, endpoint: ServerEndpoint) ClientError!void {
            switch (self.state) {
                .idle => {},
                .connecting => return ClientError.AlreadyConnecting,
                .established => return ClientError.AlreadyConnected,
                .closed => return ClientError.AlreadyClosed,
            }

            endpoint.validate() catch {
                return ClientError.InvalidRequest;
            };

            const address = resolvePreferredAddress(self.allocator, endpoint.host, endpoint.port) catch {
                return ClientError.DnsResolveFailed;
            };

            const remote = storageFromAddress(address);
            var sock = openSocket(address) catch |err| switch (err) {
                ClientError.UnsupportedAddressFamily => return err,
                else => return ClientError.SocketSetupFailed,
            };
            errdefer sock.close();

            var local_storage: std.posix.sockaddr.storage = undefined;
            var local_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
            std.posix.getsockname(sock.fd, @ptrCast(&local_storage), &local_len) catch {
                return ClientError.SocketSetupFailed;
            };

            self.remote_addr = remote.storage;
            self.remote_addr_len = remote.len;
            self.local_addr = local_storage;
            self.local_addr_len = local_len;

            if (!self.io_registered) {
                self.event_loop.addUdpIo(sock.fd, client_mod.onUdpReadable, self) catch {
                    return ClientError.SocketSetupFailed;
                };
                self.io_registered = true;
            }

            self.socket = sock;
            sock.fd = -1;

            const server_name = endpoint.sniHost();
            const server_name_z = self.allocator.dupeZ(u8, server_name) catch {
                return ClientError.H3Error;
            };
            defer self.allocator.free(server_name_z);

            const scid = connection.generateScid();
            self.current_scid = scid;

            var q_conn = quiche.connect(
                server_name_z[0..server_name_z.len :0],
                scid[0..],
                @ptrCast(&self.local_addr),
                self.local_addr_len,
                @ptrCast(&self.remote_addr),
                self.remote_addr_len,
                &self.quiche_config,
            ) catch {
                return ClientError.SocketSetupFailed;
            };

            self.conn = q_conn;

            if (self.config.qlog_dir != null) {
                self.setupQlog(scid[0..]) catch |err| {
                    self.conn = null;
                    q_conn.deinit();
                    return err;
                };
            }

            if (self.config.keylog_path) |path| {
                const keylog = self.allocator.dupeZ(u8, path) catch {
                    return ClientError.KeylogSetupFailed;
                };
                const keylog_z: [:0]u8 = keylog[0..keylog.len :0];
                if (!q_conn.setKeylogPath(keylog_z)) {
                    self.allocator.free(keylog);
                    self.conn = null;
                    q_conn.deinit();
                    return ClientError.KeylogSetupFailed;
                }
                self.keylog_path = keylog_z;
            }

            self.state = .connecting;
            self.handshake_error = null;

            self.flushSend() catch |err| {
                self.recordFailure(err);
                return err;
            };
            self.afterQuicProgress();

            if (self.connect_timer) |handle| {
                const timeout_s = @as(f64, @floatFromInt(self.config.connect_timeout_ms)) / 1000.0;
                self.event_loop.startTimer(handle, timeout_s, 0);
            }

            self.event_loop.run();
            self.stopConnectTimer();

            switch (self.state) {
                .established => {
                    try self.rememberEndpoint(endpoint);
                    return;
                },
                .closed => {
                    if (self.conn) |*conn_ref| {
                        conn_ref.deinit();
                        self.conn = null;
                    }
                    const err = self.handshake_error orelse ClientError.HandshakeFailed;
                    return err;
                },
                else => return ClientError.HandshakeFailed,
            }
        }

        pub fn isEstablished(self: *const Self) bool {
            return self.state == .established;
        }

        pub fn reconnect(self: *Self) ClientError!void {
            if (self.conn) |*conn| {
                conn.close(true, 0, "reconnecting") catch {};
                conn.deinit();
                self.conn = null;
            }

            if (self.h3_conn) |*h3_conn| {
                h3_conn.deinit();
                self.h3_conn = null;
            }

            if (self.socket) |*sock| {
                sock.close();
                self.socket = null;
            }

            var req_keys = std.ArrayList(u64).init(self.allocator);
            defer req_keys.deinit();
            var req_it = self.requests.iterator();
            while (req_it.next()) |entry| {
                try req_keys.append(entry.key_ptr.*);
            }
            for (req_keys.items) |stream_id| {
                if (self.requests.fetchRemove(stream_id)) |kv| {
                    kv.value.destroy();
                }
            }

            var wt_keys = std.ArrayList(u64).init(self.allocator);
            defer wt_keys.deinit();
            var wt_it = self.wt_sessions.iterator();
            while (wt_it.next()) |entry| {
                try wt_keys.append(entry.key_ptr.*);
            }
            for (wt_keys.items) |stream_id| {
                if (self.wt_sessions.fetchRemove(stream_id)) |kv| {
                    kv.value.close();
                }
            }

            self.state = .idle;

            if (self.server_host != null and self.server_port != null) {
                const endpoint = ServerEndpoint{
                    .host = self.server_host.?,
                    .port = self.server_port.?,
                    .sni = self.server_sni,
                };
                try self.connect(endpoint);
            } else {
                return ClientError.NoConnection;
            }
        }

        pub fn rememberEndpoint(self: *Self, endpoint: ServerEndpoint) ClientError!void {
            const host_copy = self.allocator.dupe(u8, endpoint.host) catch {
                return ClientError.H3Error;
            };
            errdefer self.allocator.free(host_copy);

            const authority = if (endpoint.port == 443)
                self.allocator.dupe(u8, endpoint.host) catch {
                    self.allocator.free(host_copy);
                    return ClientError.H3Error;
                }
            else
                std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ endpoint.host, endpoint.port }) catch {
                    self.allocator.free(host_copy);
                    return ClientError.H3Error;
                };
            errdefer self.allocator.free(authority);

            const sni_copy = if (endpoint.sni) |sni|
                self.allocator.dupe(u8, sni) catch {
                    self.allocator.free(host_copy);
                    self.allocator.free(authority);
                    return ClientError.H3Error;
                }
            else
                null;
            errdefer if (sni_copy) |s| self.allocator.free(s);

            if (self.server_host) |prev| {
                self.allocator.free(prev);
            }
            if (self.server_authority) |prev| {
                self.allocator.free(prev);
            }
            if (self.server_sni) |prev_sni| {
                self.allocator.free(prev_sni);
            }

            self.server_host = host_copy;
            self.server_authority = authority;
            self.server_port = endpoint.port;
            self.server_sni = sni_copy;
        }

        pub fn setupQlog(self: *Self, conn_id: []const u8) ClientError!void {
            const path = self.config.createQlogPath(self.allocator, conn_id) catch |err| switch (err) {
                error.QlogDisabled => return,
                else => return ClientError.QlogSetupFailed,
            };
            errdefer self.allocator.free(path.ptr[0 .. path.len + 1]);

            const title = self.allocator.dupeZ(u8, "quic-client") catch {
                return ClientError.QlogSetupFailed;
            };
            defer self.allocator.free(title);
            const desc = self.allocator.dupeZ(u8, "Zig QUIC Client") catch {
                return ClientError.QlogSetupFailed;
            };
            defer self.allocator.free(desc);

            const conn = try self.requireConn();
            if (!conn.setQlogPath(path, title[0..title.len :0], desc[0..desc.len :0])) {
                return ClientError.QlogSetupFailed;
            }

            self.qlog_path = path;
        }

        pub fn requireConn(self: *Self) ClientError!*quiche.Connection {
            if (self.conn) |*conn_ref| {
                if (conn_ref.isClosed()) {
                    self.state = .closed;
                    return ClientError.ConnectionClosed;
                }
                return conn_ref;
            }
            return ClientError.NoConnection;
        }

        pub fn stopConnectTimer(self: *Self) void {
            if (self.connect_timer) |handle| {
                self.event_loop.stopTimer(handle);
            }
        }

        fn resolvePreferredAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
            if (std.net.Address.parseIp6(host, port)) |addr| {
                return addr;
            } else |_| {}

            if (std.net.Address.parseIp4(host, port)) |addr| {
                return addr;
            } else |_| {}

            var list = try std.net.getAddressList(allocator, host, port);
            defer list.deinit();

            var ipv4: ?std.net.Address = null;
            for (list.addrs) |addr| {
                switch (addr.any.family) {
                    std.posix.AF.INET6 => return addr,
                    std.posix.AF.INET => {
                        if (ipv4 == null) ipv4 = addr;
                    },
                    else => {},
                }
            }

            if (ipv4) |addr| return addr;
            return error.NoUsableAddress;
        }

        const StorageWithLen = struct {
            storage: std.posix.sockaddr.storage,
            len: std.posix.socklen_t,
        };

        fn storageFromAddress(address: std.net.Address) StorageWithLen {
            var storage = std.mem.zeroes(std.posix.sockaddr.storage);
            const os_len = address.getOsSockLen();
            const src = @as([*]const u8, @ptrCast(&address.any))[0..os_len];
            const dst = @as([*]u8, @ptrCast(&storage))[0..os_len];
            @memcpy(dst, src);
            return .{ .storage = storage, .len = os_len };
        }

        fn openSocket(address: std.net.Address) ClientError!udp.UdpSocket {
            const base = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
            const fd = std.posix.socket(address.any.family, base, std.posix.IPPROTO.UDP) catch |err| switch (err) {
                error.AddressFamilyNotSupported, error.ProtocolFamilyNotAvailable => return ClientError.UnsupportedAddressFamily,
                error.ProtocolNotSupported, error.SocketTypeNotSupported => return ClientError.UnsupportedAddressFamily,
                else => return ClientError.SocketSetupFailed,
            };
            errdefer std.posix.close(fd);

            udp.setReuseAddr(fd, true) catch return ClientError.SocketSetupFailed;

            switch (address.any.family) {
                std.posix.AF.INET => {
                    var bind_addr = std.mem.zeroes(std.posix.sockaddr.in);
                    bind_addr.family = std.posix.AF.INET;
                    bind_addr.port = 0;
                    bind_addr.addr = 0;
                    std.posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(std.posix.sockaddr.in)) catch return ClientError.SocketSetupFailed;
                },
                std.posix.AF.INET6 => {
                    var bind_addr = std.mem.zeroes(std.posix.sockaddr.in6);
                    bind_addr.family = std.posix.AF.INET6;
                    bind_addr.port = 0;
                    bind_addr.addr = std.mem.zeroes([16]u8);
                    bind_addr.flowinfo = 0;
                    bind_addr.scope_id = 0;
                    udp.setIpv6Only(fd, false);
                    std.posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(std.posix.sockaddr.in6)) catch return ClientError.SocketSetupFailed;
                },
                else => return ClientError.UnsupportedAddressFamily,
            }

            return udp.UdpSocket{ .fd = fd };
        }
    };
}
