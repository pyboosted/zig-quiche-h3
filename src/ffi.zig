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

pub export fn zig_h3_wt_event_size() usize {
    return client.wtEventStructSize();
}

pub export fn zig_h3_wt_event_copy(
    src_ptr: ?*const client.ZigWebTransportEvent,
    dst_ptr: ?*client.ZigWebTransportEvent,
) i32 {
    return client.wtEventCopy(src_ptr, dst_ptr);
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

pub export fn zig_h3_client_run_once(client_ptr: ?*client.ZigClient) i32 {
    return client.clientRunOnce(client_ptr);
}

pub export fn zig_h3_client_poll(client_ptr: ?*client.ZigClient) i32 {
    return client.clientPoll(client_ptr);
}

pub export fn zig_h3_client_open_webtransport(
    client_ptr: ?*client.ZigClient,
    path_ptr: ?[*]const u8,
    path_len: usize,
    cb: client.WebTransportEventCallback,
    user: ?*anyopaque,
) ?*client.ZigWebTransportSession {
    return client.clientOpenWebTransport(client_ptr, path_ptr, path_len, cb, user);
}

pub export fn zig_h3_wt_session_close(
    session_ptr: ?*client.ZigWebTransportSession,
    error_code: u32,
    reason_ptr: ?[*]const u8,
    reason_len: usize,
) i32 {
    return client.wtSessionClose(session_ptr, error_code, reason_ptr, reason_len);
}

pub export fn zig_h3_wt_session_send_datagram(
    session_ptr: ?*client.ZigWebTransportSession,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    return client.wtSessionSendDatagram(session_ptr, data_ptr, data_len);
}

pub export fn zig_h3_wt_session_receive_datagram(
    session_ptr: ?*client.ZigWebTransportSession,
    out_ptr: ?*client.ZigBytes,
) i32 {
    return client.wtSessionReceiveDatagram(session_ptr, out_ptr);
}

pub export fn zig_h3_wt_session_free_datagram(
    session_ptr: ?*client.ZigWebTransportSession,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    return client.wtSessionFreeDatagram(session_ptr, data_ptr, data_len);
}

pub export fn zig_h3_wt_session_is_established(session_ptr: ?*client.ZigWebTransportSession) i32 {
    return client.wtSessionIsEstablished(session_ptr);
}

pub export fn zig_h3_wt_session_stream_id(session_ptr: ?*client.ZigWebTransportSession) u64 {
    return client.wtSessionStreamId(session_ptr);
}

pub export fn zig_h3_wt_session_free(session_ptr: ?*client.ZigWebTransportSession) i32 {
    return client.wtSessionFree(session_ptr);
}

pub export fn zig_h3_server_new(cfg_ptr: ?*const server.ZigServerConfig) ?*server.ZigServer {
    return server.zig_h3_server_new(cfg_ptr);
}

pub export fn zig_h3_server_free(server_ptr: ?*server.ZigServer) i32 {
    return server.zig_h3_server_free(server_ptr);
}

pub export fn zig_h3_server_route(
    server_ptr: ?*server.ZigServer,
    method_c: ?[*:0]const u8,
    pattern_c: ?[*:0]const u8,
    cb: server.RequestCallback,
    dgram_cb: server.DatagramCallback,
    wt_cb: server.WTSessionCallback,
    user: ?*anyopaque,
) i32 {
    return server.zig_h3_server_route(server_ptr, method_c, pattern_c, cb, dgram_cb, wt_cb, user);
}

pub export fn zig_h3_server_route_streaming(
    server_ptr: ?*server.ZigServer,
    method_c: ?[*:0]const u8,
    pattern_c: ?[*:0]const u8,
    cb: server.RequestCallback,
    body_chunk_cb: server.BodyChunkCallback,
    body_complete_cb: server.BodyCompleteCallback,
    dgram_cb: server.DatagramCallback,
    wt_cb: server.WTSessionCallback,
    user: ?*anyopaque,
) i32 {
    return server.zig_h3_server_route_streaming(server_ptr, method_c, pattern_c, cb, body_chunk_cb, body_complete_cb, dgram_cb, wt_cb, user);
}

pub export fn zig_h3_server_set_stream_close_cb(
    server_ptr: ?*server.ZigServer,
    cb: server.StreamCloseCallback,
    user: ?*anyopaque,
) i32 {
    return server.zig_h3_server_set_stream_close_cb(server_ptr, cb, user);
}

pub export fn zig_h3_server_set_connection_close_cb(
    server_ptr: ?*server.ZigServer,
    cb: server.ConnectionCloseCallback,
    user: ?*anyopaque,
) i32 {
    return server.zig_h3_server_set_connection_close_cb(server_ptr, cb, user);
}

pub export fn zig_h3_server_start(server_ptr: ?*server.ZigServer) i32 {
    return server.zig_h3_server_start(server_ptr);
}

pub export fn zig_h3_server_stop(server_ptr: ?*server.ZigServer) i32 {
    return server.zig_h3_server_stop(server_ptr);
}

pub export fn zig_h3_server_set_log(server_ptr: ?*server.ZigServer, cb: server.LogCallback, user: ?*anyopaque) i32 {
    return server.zig_h3_server_set_log(server_ptr, cb, user);
}

pub export fn zig_h3_response_status(resp_ptr: ?*server.ZigResponse, status: u16) i32 {
    return server.zig_h3_response_status(resp_ptr, status);
}

pub export fn zig_h3_response_header(
    resp_ptr: ?*server.ZigResponse,
    name_ptr: ?[*]const u8,
    name_len: usize,
    value_ptr: ?[*]const u8,
    value_len: usize,
) i32 {
    return server.zig_h3_response_header(resp_ptr, name_ptr, name_len, value_ptr, value_len);
}

pub export fn zig_h3_response_write(
    resp_ptr: ?*server.ZigResponse,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    return server.zig_h3_response_write(resp_ptr, data_ptr, data_len);
}

pub export fn zig_h3_response_end(
    resp_ptr: ?*server.ZigResponse,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    return server.zig_h3_response_end(resp_ptr, data_ptr, data_len);
}

pub export fn zig_h3_response_send_h3_datagram(
    resp_ptr: ?*server.ZigResponse,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    return server.zig_h3_response_send_h3_datagram(resp_ptr, data_ptr, data_len);
}

pub export fn zig_h3_response_send_trailers(
    resp_ptr: ?*server.ZigResponse,
    trailers_ptr: ?[*]const server.ZigHeader,
    trailers_len: usize,
) i32 {
    return server.zig_h3_response_send_trailers(resp_ptr, trailers_ptr, trailers_len);
}

pub export fn zig_h3_response_defer_end(resp_ptr: ?*server.ZigResponse) i32 {
    return server.zig_h3_response_defer_end(resp_ptr);
}

pub export fn zig_h3_response_set_auto_end(resp_ptr: ?*server.ZigResponse, enable: u8) i32 {
    return server.zig_h3_response_set_auto_end(resp_ptr, enable);
}

pub export fn zig_h3_response_should_auto_end(resp_ptr: ?*server.ZigResponse) i32 {
    return server.zig_h3_response_should_auto_end(resp_ptr);
}

pub export fn zig_h3_response_process_partial(resp_ptr: ?*server.ZigResponse) i32 {
    return server.zig_h3_response_process_partial(resp_ptr);
}

pub export fn zig_h3_wt_accept(session_ptr: ?*server.ZigWebTransportSession) i32 {
    return server.zig_h3_wt_accept(session_ptr);
}

pub export fn zig_h3_wt_reject(session_ptr: ?*server.ZigWebTransportSession, status: u16) i32 {
    return server.zig_h3_wt_reject(session_ptr, status);
}

pub export fn zig_h3_wt_close(
    session_ptr: ?*server.ZigWebTransportSession,
    error_code: u32,
    reason_ptr: ?[*]const u8,
    reason_len: usize,
) i32 {
    return server.zig_h3_wt_close(session_ptr, error_code, reason_ptr, reason_len);
}

pub export fn zig_h3_wt_send_datagram(
    session_ptr: ?*server.ZigWebTransportSession,
    data_ptr: ?[*]const u8,
    data_len: usize,
) i32 {
    return server.zig_h3_wt_send_datagram(session_ptr, data_ptr, data_len);
}

pub export fn zig_h3_wt_release(session_ptr: ?*server.ZigWebTransportSession) i32 {
    return server.zig_h3_wt_release(session_ptr);
}

extern fn quiche_version() [*:0]const u8;

// Exported symbol for Bun FFI smoke tests
pub export fn zig_h3_version() [*:0]const u8 {
    return quiche_version();
}
