const std = @import("std");
const h3 = @import("h3");
const h3_datagram = h3.datagram;

pub fn sendH3Datagram(comptime Response: type, self: *Response, payload: []const u8) !void {
    if (!self.h3_conn.dgramEnabledByPeer(self.quic_conn)) {
        return error.H3DatagramNotEnabled;
    }

    const flow_id = self.h3_flow_id orelse h3_datagram.flowIdForStream(self.stream_id);
    const max_dgram_size = self.quic_conn.dgramMaxWritableLen();
    const varint_overhead = h3_datagram.varintLen(flow_id);
    if (max_dgram_size) |maxw| {
        if (payload.len + varint_overhead > maxw) return error.DatagramTooLarge;
    }

    var small_buf: [2048]u8 = undefined;
    const total_len: usize = varint_overhead + payload.len;
    var use_heap = false;
    var dgram_buf: []u8 = small_buf[0..];
    if (total_len <= small_buf.len) {
        dgram_buf = small_buf[0..total_len];
    } else {
        dgram_buf = try self.allocator.alloc(u8, total_len);
        use_heap = true;
    }
    defer if (use_heap) self.allocator.free(dgram_buf);

    const varint_len = try h3_datagram.encodeVarint(dgram_buf, flow_id);
    std.debug.assert(varint_len == varint_overhead);
    @memcpy(dgram_buf[varint_len..], payload);

    const sent = self.quic_conn.dgramSend(dgram_buf) catch |err| {
        return switch (err) {
            error.Done => error.WouldBlock,
            else => err,
        };
    };

    if (sent != dgram_buf.len) return error.PartialSend;

    if (H3_DEBUG_LOG) {
        std.debug.print("H3 DGRAM sent flow={d} len={d}\n", .{ flow_id, payload.len });
    }
}

const H3_DEBUG_LOG = false;
