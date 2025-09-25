const std = @import("std");

// libev bindings
const c = @cImport({
    @cInclude("ev.h");
});

pub const EventBackend = enum {
    libev,
};

pub const IoCallback = *const fn (fd: std.posix.socket_t, revents: u32, user_data: *anyopaque) void;
pub const TimerCallback = *const fn (user_data: *anyopaque) void;
pub const SignalCallback = *const fn (signum: c_int, user_data: *anyopaque) void;

const IoWatcher = struct {
    io: c.ev_io = undefined,
    fd: std.posix.socket_t,
    cb: IoCallback,
    user_data: *anyopaque,
};

const TimerWatcher = struct {
    timer: c.ev_timer = undefined,
    cb: TimerCallback,
    user_data: *anyopaque,
};

pub const TimerHandle = struct {
    watcher: *TimerWatcher,
};

const SignalWatcher = struct {
    sig: c.ev_signal = undefined,
    cb: SignalCallback,
    user_data: *anyopaque,
};

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    backend: EventBackend = .libev,

    // libev state
    loop: *c.struct_ev_loop,

    // Keep watcher allocations stable; libev stores pointers to these.
    io_watchers: std.ArrayList(*IoWatcher),
    timer_watchers: std.ArrayList(*TimerWatcher),
    sig_watchers: std.ArrayList(*SignalWatcher),

    pub fn initLibev(allocator: std.mem.Allocator) !*EventLoop {
        const self = try allocator.create(EventLoop);
        const loop = c.ev_default_loop(0) orelse return error.LibevInitFailed;
        self.* = .{
            .allocator = allocator,
            .backend = .libev,
            .loop = loop,
            .io_watchers = .{},
            .timer_watchers = .{},
            .sig_watchers = .{},
        };
        return self;
    }

    pub fn deinit(self: *EventLoop) void {
        // Stop and free watchers (libev automatically stops them on destroy, but be explicit).
        for (self.io_watchers.items) |w| {
            // ev_io_stop is safe to call even on inactive watchers
            c.ev_io_stop(self.loop, &w.io);
            self.allocator.destroy(w);
        }
        self.io_watchers.deinit(self.allocator);

        for (self.timer_watchers.items) |w| {
            // ev_timer_stop is safe to call even on inactive watchers
            c.ev_timer_stop(self.loop, &w.timer);
            self.allocator.destroy(w);
        }
        self.timer_watchers.deinit(self.allocator);

        for (self.sig_watchers.items) |w| {
            // ev_signal_stop is safe to call even on inactive watchers
            c.ev_signal_stop(self.loop, &w.sig);
            self.allocator.destroy(w);
        }
        self.sig_watchers.deinit(self.allocator);

        // For the default loop, libev provides ev_default_destroy (not always present via headers);
        // breaking and letting process exit is sufficient for our demos.
        self.allocator.destroy(self);
    }

    pub fn run(self: *EventLoop) void {
        // 0 == EVRUN_DEFAULT
        _ = c.ev_run(self.loop, 0);
    }

    pub fn runOnce(self: *EventLoop) void {
        _ = c.ev_run(self.loop, c.EVRUN_ONCE);
    }

    pub fn poll(self: *EventLoop) void {
        _ = c.ev_run(self.loop, c.EVRUN_NOWAIT);
    }

    pub fn stop(self: *EventLoop) void {
        c.ev_break(self.loop, c.EVBREAK_ALL);
    }

    pub fn addUdpIo(self: *EventLoop, fd: std.posix.socket_t, cb: IoCallback, user_data: *anyopaque) !void {
        const w = try self.allocator.create(IoWatcher);
        w.* = .{ .fd = fd, .cb = cb, .user_data = user_data };
        // Zero-initialize the ev_io structure first
        w.io = std.mem.zeroes(@TypeOf(w.io));
        // Manual init since ev_io_init macro can't be imported
        w.io.cb = io_dispatch;
        w.io.fd = @intCast(fd);
        w.io.events = c.EV_READ;
        c.ev_io_start(self.loop, &w.io);
        errdefer {
            c.ev_io_stop(self.loop, &w.io);
            self.allocator.destroy(w);
        }
        try self.io_watchers.append(self.allocator, w);
    }

    pub fn addTimer(self: *EventLoop, after_s: f64, repeat_s: f64, cb: TimerCallback, user_data: *anyopaque) !void {
        const handle = try self.createTimer(cb, user_data);
        self.startTimer(handle, after_s, repeat_s);
    }

    pub fn createTimer(self: *EventLoop, cb: TimerCallback, user_data: *anyopaque) !TimerHandle {
        const w = try self.allocator.create(TimerWatcher);
        w.* = .{ .cb = cb, .user_data = user_data };
        w.timer = std.mem.zeroes(@TypeOf(w.timer));
        w.timer.cb = timer_dispatch;
        try self.timer_watchers.append(self.allocator, w);
        return .{ .watcher = w };
    }

    pub fn startTimer(self: *EventLoop, handle: TimerHandle, after_s: f64, repeat_s: f64) void {
        const w = handle.watcher;
        if (w.timer.active != 0) {
            c.ev_timer_stop(self.loop, &w.timer);
        }
        w.timer.at = after_s;
        w.timer.repeat = repeat_s;
        c.ev_timer_start(self.loop, &w.timer);
    }

    pub fn stopTimer(self: *EventLoop, handle: TimerHandle) void {
        const w = handle.watcher;
        if (w.timer.active != 0) {
            c.ev_timer_stop(self.loop, &w.timer);
        }
    }

    pub fn destroyTimer(self: *EventLoop, handle: TimerHandle) void {
        const w = handle.watcher;
        if (w.timer.active != 0) {
            c.ev_timer_stop(self.loop, &w.timer);
        }
        self.removeTimerWatcher(w);
        self.allocator.destroy(w);
    }

    pub fn addSigint(self: *EventLoop, cb: SignalCallback, user_data: *anyopaque) !void {
        try self.addSignal(std.posix.SIG.INT, cb, user_data);
    }

    pub fn addSigterm(self: *EventLoop, cb: SignalCallback, user_data: *anyopaque) !void {
        try self.addSignal(std.posix.SIG.TERM, cb, user_data);
    }

    pub fn addSignal(self: *EventLoop, signum: c_int, cb: SignalCallback, user_data: *anyopaque) !void {
        const w = try self.allocator.create(SignalWatcher);
        w.* = .{ .cb = cb, .user_data = user_data };
        // Zero-initialize the ev_signal structure first
        w.sig = std.mem.zeroes(@TypeOf(w.sig));
        // Manual init since ev_signal_init macro can't be imported
        w.sig.cb = signal_dispatch;
        w.sig.signum = signum;
        c.ev_signal_start(self.loop, &w.sig);
        errdefer {
            c.ev_signal_stop(self.loop, &w.sig);
            self.allocator.destroy(w);
        }
        try self.sig_watchers.append(self.allocator, w);
    }

    fn removeTimerWatcher(self: *EventLoop, target: *TimerWatcher) void {
        var i: usize = 0;
        while (i < self.timer_watchers.items.len) : (i += 1) {
            if (self.timer_watchers.items[i] == target) {
                _ = self.timer_watchers.swapRemove(i);
                return;
            }
        }
    }
};

fn io_dispatch(loop: ?*c.struct_ev_loop, w: ?*c.ev_io, revents: c_int) callconv(.c) void {
    _ = loop;
    const parent: *IoWatcher = @fieldParentPtr("io", w.?);
    parent.cb(parent.fd, @intCast(revents), parent.user_data);
}

fn timer_dispatch(loop: ?*c.struct_ev_loop, w: ?*c.ev_timer, _revents: c_int) callconv(.c) void {
    _ = loop;
    _ = _revents;
    const parent: *TimerWatcher = @fieldParentPtr("timer", w.?);
    parent.cb(parent.user_data);
}

fn signal_dispatch(loop: ?*c.struct_ev_loop, w: ?*c.ev_signal, _revents: c_int) callconv(.c) void {
    _ = loop;
    _ = _revents;
    const parent: *SignalWatcher = @fieldParentPtr("sig", w.?);
    // Pass the actual signal number from the watcher
    parent.cb(w.?.signum, parent.user_data);
}
