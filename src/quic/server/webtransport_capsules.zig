const std = @import("std");
const h3 = @import("h3");
const wt_capsules = h3.webtransport.capsules;

pub fn CapsuleRecorder(comptime Alloc: type) type {
    return struct {
        allocator: Alloc,
        close_count: usize = 0,
        last_code: u32 = 0,
        last_reason: []const u8 = &.{},

        pub fn record(self: *Self, capsule: wt_capsules.Capsule) void {
            switch (capsule) {
                .close_session => |info| {
                    self.close_count += 1;
                    self.last_code = info.application_error_code;
                    const copy = self.allocator.dupe(u8, info.reason) catch return;
                    self.last_reason = copy;
                },
                else => {},
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.last_reason.len > 0) {
                self.allocator.free(self.last_reason);
                self.last_reason = &.{};
            }
        }
    };
}

pub const SessionCapsuleInfo = struct {
    close_count: usize = 0,
    last_code: u32 = 0,
    last_reason: []const u8 = &.{},
};

pub fn attachRecorder(
    allocator: std.mem.Allocator,
    session_wrapper: anytype,
) !*CapsuleRecorder(std.mem.Allocator) {
    const recorder = try allocator.create(CapsuleRecorder(std.mem.Allocator));
    recorder.* = .{ .allocator = allocator };
    session_wrapper.setCapsuleHandler(recordCapsule, recorder);
    return recorder;
}

fn recordCapsule(sess: *anyopaque, capsule: wt_capsules.Capsule, ctx: ?*anyopaque) h3.Errors.WebTransportError!void {
    _ = sess;
    const recorder = @ptrCast(*CapsuleRecorder(std.mem.Allocator), ctx.?);
    recorder.record(capsule);
}
