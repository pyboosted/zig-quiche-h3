const std = @import("std");
const connection = @import("connection");
const utils = @import("utils");

pub const StreamKey = struct { conn: *connection.Connection, stream_id: u64 };
pub const StreamKeyContext = utils.AutoContext(StreamKey);

pub const FlowKey = struct { conn: *connection.Connection, flow_id: u64 };
pub const FlowKeyContext = utils.AutoContext(FlowKey);

pub const SessionKey = struct { conn: *connection.Connection, session_id: u64 };
pub const SessionKeyContext = utils.AutoContext(SessionKey);

pub const DatagramStats = struct {
    received: usize = 0,
    sent: usize = 0,
    dropped_send: usize = 0,
};

pub const CapsuleCounters = struct {
    close_session: usize = 0,
    drain_session: usize = 0,
    wt_max_streams_bidi: usize = 0,
    wt_max_streams_uni: usize = 0,
    wt_streams_blocked_bidi: usize = 0,
    wt_streams_blocked_uni: usize = 0,
    wt_max_data: usize = 0,
    wt_data_blocked: usize = 0,
};

pub fn H3State(comptime RequestStatePtr: type) type {
    return struct {
        dgram_flows: std.hash_map.HashMap(FlowKey, RequestStatePtr, FlowKeyContext, 80),
        dgrams_received: usize = 0,
        dgrams_sent: usize = 0,
        unknown_flow: usize = 0,
        would_block: usize = 0,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{ .dgram_flows = std.hash_map.HashMap(FlowKey, RequestStatePtr, FlowKeyContext, 80).init(allocator) };
        }
    };
}

pub fn WTState(
    comptime SessionStatePtr: type,
    comptime StreamStatePtr: type,
    comptime UniPrefaceT: type,
) type {
    return struct {
        sessions: std.hash_map.HashMap(SessionKey, SessionStatePtr, SessionKeyContext, 80),
        dgram_map: std.hash_map.HashMap(FlowKey, SessionStatePtr, FlowKeyContext, 80),
        sessions_created: usize = 0,
        sessions_closed: usize = 0,
        dgrams_received: usize = 0,
        dgrams_sent: usize = 0,
        dgrams_would_block: usize = 0,
        capsules_sent_total: usize = 0,
        capsules_received_total: usize = 0,
        capsules_sent: CapsuleCounters = .{},
        capsules_received: CapsuleCounters = .{},
        legacy_session_accept_sent: usize = 0,
        legacy_session_accept_received: usize = 0,
        enabled: bool = false, // WebTransport enabled at runtime
        enable_streams: bool = false,
        enable_bidi: bool = false,
        streams: std.hash_map.HashMap(StreamKey, StreamStatePtr, StreamKeyContext, 80),
        uni_preface: std.hash_map.HashMap(StreamKey, UniPrefaceT, StreamKeyContext, 80),

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{
                .sessions = std.hash_map.HashMap(SessionKey, SessionStatePtr, SessionKeyContext, 80).init(allocator),
                .dgram_map = std.hash_map.HashMap(FlowKey, SessionStatePtr, FlowKeyContext, 80).init(allocator),
                .streams = std.hash_map.HashMap(StreamKey, StreamStatePtr, StreamKeyContext, 80).init(allocator),
                .uni_preface = std.hash_map.HashMap(StreamKey, UniPrefaceT, StreamKeyContext, 80).init(allocator),
            };
        }
    };
}

comptime {
    const ptr_size = @sizeOf(*connection.Connection);
    const u64_size = @sizeOf(u64);
    const expected_key_size = ptr_size + u64_size;

    std.debug.assert(@sizeOf(StreamKey) == expected_key_size);
    std.debug.assert(@alignOf(StreamKey) == @max(@alignOf(*connection.Connection), @alignOf(u64)));

    std.debug.assert(@sizeOf(FlowKey) == expected_key_size);
    std.debug.assert(@alignOf(FlowKey) == @max(@alignOf(*connection.Connection), @alignOf(u64)));

    std.debug.assert(@sizeOf(SessionKey) == expected_key_size);
    std.debug.assert(@alignOf(SessionKey) == @max(@alignOf(*connection.Connection), @alignOf(u64)));

    std.debug.assert(@sizeOf(DatagramStats) == 3 * @sizeOf(usize));
    std.debug.assert(@alignOf(DatagramStats) == @alignOf(usize));
}
