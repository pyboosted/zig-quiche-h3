const std = @import("std");
const client = @import("ffi/client.zig");
const server = @import("ffi/server.zig");

pub export fn zig_h3_client_new(cfg_ptr: ?*const client.ZigClientConfig) ?*client.ZigClient {
    return client.clientNew(cfg_ptr);
}

pub export fn zig_h3_client_free(client_ptr: ?*client.ZigClient) i32 {
    return client.clientFree(client_ptr);
}

pub export fn zig_h3_client_connect(
    client_ptr: ?*client.ZigClient,
    host_ptr: ?[*:0]const u8,
    port: u16,
    sni_ptr: ?[*:0]const u8,
) i32 {
    return client.clientConnect(client_ptr, host_ptr, port, sni_ptr);
}

pub export fn zig_h3_client_set_datagram_callback(
    client_ptr: ?*client.ZigClient,
    cb: client.DatagramCallback,
    user: ?*anyopaque,
) i32 {
    return client.clientSetDatagramCallback(client_ptr, cb, user);
}

pub export fn zig_h3_client_fetch(
    client_ptr: ?*client.ZigClient,
    opts_ptr: ?*const client.ZigFetchOptions,
    stream_id_out: ?*u64,
    cb: client.FetchCallback,
    user: ?*anyopaque,
) i32 {
    return client.clientFetch(client_ptr, opts_ptr, stream_id_out, cb, user);
}

pub export fn zig_h3_client_fetch_simple(
    client_ptr: ?*client.ZigClient,
    method_ptr: ?[*:0]const u8,
    path_ptr: ?[*:0]const u8,
    collect_body: u8,
    stream_body: u8,
    request_timeout_ms: u32,
    event_cb: client.FetchEventCallback,
    event_user: ?*anyopaque,
    cb: client.FetchCallback,
    user: ?*anyopaque,
    stream_id_out: ?*u64,
) i32 {
    return client.clientFetchSimple(
        client_ptr,
        method_ptr,
        path_ptr,
        collect_body,
        stream_body,
        request_timeout_ms,
        event_cb,
        event_user,
        cb,
        user,
        stream_id_out,
    );
}

pub export fn zig_h3_client_cancel_fetch(
    client_ptr: ?*client.ZigClient,
    stream_id: u64,
    error_code: i32,
) i32 {
    return client.clientCancelFetch(client_ptr, stream_id, error_code);
}

pub export fn zig_h3_fetch_event_size() usize {
    return client.fetchEventStructSize();
}

pub export fn zig_h3_header_size() usize {
    return client.headerStructSize();
}

pub export fn zig_h3_fetch_event_copy(
    src_ptr: ?*const client.ZigFetchEvent,
    dst_ptr: ?*client.ZigFetchEvent,
) i32 {
    return client.fetchEventCopy(src_ptr, dst_ptr);
}

pub export fn zig_h3_header_copy(
    src_ptr: ?*const client.ZigHeader,
    dst_ptr: ?*client.ZigHeader,
) i32 {
    return client.headerCopy(src_ptr, dst_ptr);
}

pub export fn zig_h3_header_copy_at(
    base_ptr: ?*const client.ZigHeader,
    len: usize,
    index: usize,
    dst_ptr: ?*client.ZigHeader,
) i32 {
    return client.headerCopyAt(base_ptr, len, index, dst_ptr);
}

pub export fn zig_h3_headers_copy(
    base_ptr: ?*const client.ZigHeader,
    len: usize,
    dst_ptr: ?*client.ZigHeader,
    dst_len: usize,
) i32 {
    return client.headersCopy(base_ptr, len, dst_ptr, dst_len);
}

pub export fn zig_h3_copy_bytes(
    src_ptr: ?[*]const u8,
    len: usize,
    dst_ptr: ?*u8,
) i32 {
    return client.copyBytes(src_ptr, len, dst_ptr);
}

pub export fn zig_h3_client_send_h3_datagram(
    client_ptr: ?*client.ZigClient,
    stream_id: u64,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    return client.clientSendH3Datagram(client_ptr, stream_id, data_ptr, data_len);
}

pub export fn zig_h3_client_send_datagram(
    client_ptr: ?*client.ZigClient,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    return client.clientSendDatagram(client_ptr, data_ptr, data_len);
}

extern fn quiche_version() [*:0]const u8;

// Exported symbol for Bun FFI smoke tests
pub export fn zig_h3_version() [*:0]const u8 {
    return quiche_version();
}
