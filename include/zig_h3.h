#ifndef ZIG_H3_H
#define ZIG_H3_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Returns the quiche version string compiled into the library.
 * The pointer is owned by the library and remains valid for the
 * lifetime of the process. Do not free it.
 */
const char *zig_h3_version(void);

/** Opaque server handle returned by zig_h3_server_new. */
typedef struct zig_h3_server zig_h3_server;

/** Opaque response handle passed to request callbacks. */
typedef struct zig_h3_response zig_h3_response;
typedef struct zig_h3_wt_session zig_h3_wt_session;
/** Opaque client handle returned by zig_h3_client_new. */
typedef struct zig_h3_client zig_h3_client;

/**
 * Server configuration. All string pointers may be NULL to use defaults and
 * must remain valid until zig_h3_server_free is called.
 */
typedef struct zig_h3_server_config {
    const char *cert_path;       /* defaults to example cert */
    const char *key_path;        /* defaults to example key */
    const char *bind_addr;       /* default: "0.0.0.0" */
    uint16_t bind_port;          /* default: 4433 when 0 */
    uint8_t enable_dgram;        /* non-zero enables QUIC DATAGRAM */
    uint8_t enable_webtransport; /* implies DATAGRAM */
    const char *qlog_dir;        /* default: "qlogs" */
    uint8_t log_level;           /* 0=warn, 1=info, etc (optional) */
} zig_h3_server_config;

/** Borrowed header view (no ownership). */
typedef struct zig_h3_header {
    const char *name;
    size_t name_len;
    const char *value;
    size_t value_len;
} zig_h3_header;

/** Borrowed request view passed to callbacks (no ownership of memory). */
typedef struct zig_h3_request {
    const char *method;
    size_t method_len;
    const char *path;
    size_t path_len;
    const char *authority;
    size_t authority_len;
    const zig_h3_header *headers;
    size_t headers_len;
    uint64_t stream_id;
    const uint8_t *conn_id;
    size_t conn_id_len;
    const uint8_t *body;
    size_t body_len;
} zig_h3_request;

/** Request callback signature. */
typedef void (*zig_h3_request_cb)(void *user, const zig_h3_request *req, zig_h3_response *resp);
typedef void (*zig_h3_datagram_cb)(void *user, const zig_h3_request *req, zig_h3_response *resp, const uint8_t *data, size_t data_len);
typedef void (*zig_h3_wt_session_cb)(void *user, const zig_h3_request *req, zig_h3_wt_session *session);
typedef void (*zig_h3_log_cb)(void *user, const char *line);

// QUIC datagram callback: connection-scoped, arrives before HTTP exchange
// conn_ptr: opaque connection pointer (use with zig_h3_server_send_quic_datagram)
// conn_id: binary connection ID for logging/discrimination
typedef void (*zig_h3_quic_datagram_cb)(
    void *user,
    void *conn_ptr,
    const uint8_t *conn_id,
    size_t conn_id_len,
    const uint8_t *data,
    size_t data_len);

typedef struct zig_h3_server_stats {
    uint64_t connections_total;
    uint64_t connections_active;
    uint64_t requests_total;
    int64_t uptime_ms;
} zig_h3_server_stats;

typedef struct zig_h3_client_config {
    uint8_t verify_peer;
    uint8_t enable_dgram;
    uint8_t enable_webtransport;
    uint8_t enable_debug_logging;
    uint32_t idle_timeout_ms;
    uint32_t request_timeout_ms;
    uint32_t connect_timeout_ms;
} zig_h3_client_config;

typedef void (*zig_h3_fetch_cb)(
    void *user,
    uint16_t status,
    const zig_h3_header *headers,
    size_t headers_len,
    const uint8_t *body,
    size_t body_len,
    const zig_h3_header *trailers,
    size_t trailers_len);

typedef enum zig_h3_fetch_event_type {
    ZIG_H3_FETCH_EVENT_HEADERS = 0,
    ZIG_H3_FETCH_EVENT_DATA = 1,
    ZIG_H3_FETCH_EVENT_TRAILERS = 2,
    ZIG_H3_FETCH_EVENT_FINISHED = 3,
    ZIG_H3_FETCH_EVENT_DATAGRAM = 4,
    ZIG_H3_FETCH_EVENT_STARTED = 5,
} zig_h3_fetch_event_type;

typedef struct zig_h3_fetch_event {
    zig_h3_fetch_event_type type;
    uint16_t status;
    uint16_t reserved;
    const zig_h3_header *headers;
    size_t headers_len;
    const uint8_t *data;
    size_t data_len;
    uint64_t flow_id;
    uint64_t stream_id;
} zig_h3_fetch_event;

typedef void (*zig_h3_fetch_event_cb)(void *user, const zig_h3_fetch_event *event);

typedef struct zig_h3_bytes {
    const uint8_t *ptr;
    size_t len;
} zig_h3_bytes;

typedef enum zig_h3_wt_event_type {
    ZIG_H3_WT_EVENT_CONNECTED = 0,
    ZIG_H3_WT_EVENT_CONNECT_FAILED = 1,
    ZIG_H3_WT_EVENT_CLOSED = 2,
    ZIG_H3_WT_EVENT_DATAGRAM = 3,
} zig_h3_wt_event_type;

#define ZIG_H3_WT_EVENT_FLAG_REMOTE_CLOSE 0x1u

typedef struct zig_h3_wt_event {
    zig_h3_wt_event_type event_type;
    uint32_t status;
    int32_t error_code;
    uint32_t flags;
    uint64_t stream_id;
    const uint8_t *reason;
    size_t reason_len;
    const uint8_t *datagram;
    size_t datagram_len;
} zig_h3_wt_event;

typedef void (*zig_h3_wt_event_cb)(
    void *user,
    zig_h3_wt_session *session,
    const zig_h3_wt_event *event);

typedef struct zig_h3_fetch_options {
    const char *method;
    size_t method_len;
    const char *path;
    size_t path_len;
    const zig_h3_header *headers;
    size_t headers_len;
    const uint8_t *body;
    size_t body_len;
    uint8_t stream_body;
    uint8_t collect_body;
    zig_h3_fetch_event_cb event_cb;
    void *event_user;
    uint32_t request_timeout_ms;
    uint32_t reserved2;
} zig_h3_fetch_options;

typedef void (*zig_h3_client_datagram_cb)(void *user, uint64_t flow_id, const uint8_t *data, size_t data_len);

zig_h3_server *zig_h3_server_new(const zig_h3_server_config *config);
int zig_h3_server_free(zig_h3_server *server);
int zig_h3_server_route(
    zig_h3_server *server,
    const char *method,
    const char *pattern,
    zig_h3_request_cb request_cb,
    zig_h3_datagram_cb datagram_cb,
    zig_h3_wt_session_cb wt_session_cb,
    void *user_data);

// Streaming request body callback (NO finished flag - Zig uses separate on_body_complete)
typedef void (*zig_h3_body_chunk_cb)(
    void *user,
    const uint8_t *conn_id,
    size_t conn_id_len,
    uint64_t stream_id,
    const uint8_t *chunk,
    size_t len);

// Body complete callback (signals end of request body stream)
typedef void (*zig_h3_body_complete_cb)(
    void *user,
    const uint8_t *conn_id,
    size_t conn_id_len,
    uint64_t stream_id);

// Cleanup hooks for resource management (conn_id required for composite key discrimination)
typedef void (*zig_h3_stream_close_cb)(void *user, const uint8_t *conn_id, size_t conn_id_len, uint64_t stream_id, uint8_t aborted);
typedef void (*zig_h3_connection_close_cb)(void *user, const uint8_t *conn_id, size_t conn_id_len);

// Register streaming route with body chunk callback
int zig_h3_server_route_streaming(
    zig_h3_server *server,
    const char *method,
    const char *pattern,
    zig_h3_request_cb request_cb,
    zig_h3_body_chunk_cb body_chunk_cb,
    zig_h3_body_complete_cb body_complete_cb,
    zig_h3_datagram_cb datagram_cb,
    zig_h3_wt_session_cb wt_session_cb,
    void *user_data);

// Register cleanup hooks
int zig_h3_server_set_stream_close_cb(zig_h3_server *server, zig_h3_stream_close_cb callback, void *user_data);
int zig_h3_server_set_connection_close_cb(zig_h3_server *server, zig_h3_connection_close_cb callback, void *user_data);

// QUIC datagram handlers (connection-scoped, not route-specific)
int zig_h3_server_set_quic_datagram_cb(zig_h3_server *server, zig_h3_quic_datagram_cb callback, void *user_data);
int zig_h3_server_send_quic_datagram(zig_h3_server *server, void *conn_ptr, const uint8_t *data, size_t data_len);

int zig_h3_server_start(zig_h3_server *server);
/**
 * Stop the server. If force is non-zero, all active connections are immediately
 * closed before stopping. If force is zero, performs graceful shutdown allowing
 * in-flight requests to complete.
 */
int zig_h3_server_stop(zig_h3_server *server, uint8_t force);
int zig_h3_server_set_log(zig_h3_server *server, zig_h3_log_cb callback, void *user_data);
int zig_h3_server_stats(zig_h3_server *server, zig_h3_server_stats *out);

int zig_h3_response_status(zig_h3_response *response, uint16_t status);
int zig_h3_response_header(
    zig_h3_response *response,
    const char *name,
    size_t name_len,
    const char *value,
    size_t value_len);
int zig_h3_response_write(
    zig_h3_response *response,
    const uint8_t *data,
    size_t data_len);
int zig_h3_response_end(
    zig_h3_response *response,
    const uint8_t *data,
    size_t data_len);
int zig_h3_response_send_h3_datagram(
    zig_h3_response *response,
    const uint8_t *data,
    size_t data_len);
int zig_h3_response_send_trailers(
    zig_h3_response *response,
    const zig_h3_header *trailers,
    size_t trailers_len);
int zig_h3_response_defer_end(zig_h3_response *response);
int zig_h3_response_set_auto_end(zig_h3_response *response, uint8_t enable);
int zig_h3_response_should_auto_end(zig_h3_response *response);
int zig_h3_response_process_partial(zig_h3_response *response);

int zig_h3_wt_accept(zig_h3_wt_session *session);
int zig_h3_wt_reject(zig_h3_wt_session *session, uint16_t status);
int zig_h3_wt_close(zig_h3_wt_session *session, uint32_t code, const uint8_t *reason, size_t reason_len);
int zig_h3_wt_send_datagram(zig_h3_wt_session *session, const uint8_t *data, size_t data_len);
int zig_h3_wt_release(zig_h3_wt_session *session);

zig_h3_client *zig_h3_client_new(const zig_h3_client_config *config);
int zig_h3_client_free(zig_h3_client *client);
int zig_h3_client_connect(zig_h3_client *client, const char *host, uint16_t port, const char *sni);
int zig_h3_client_set_datagram_callback(zig_h3_client *client, zig_h3_client_datagram_cb callback, void *user_data);
int zig_h3_client_fetch(
    zig_h3_client *client,
    const zig_h3_fetch_options *options,
    uint64_t *stream_id_out,
    zig_h3_fetch_cb callback,
    void *user_data);
int zig_h3_client_fetch_simple(
    zig_h3_client *client,
    const char *method,
    const char *path,
    uint8_t collect_body,
    uint8_t stream_body,
    uint32_t request_timeout_ms,
    zig_h3_fetch_event_cb event_cb,
    void *event_user,
    zig_h3_fetch_cb callback,
    void *user_data,
    uint64_t *stream_id_out);
int zig_h3_client_cancel_fetch(zig_h3_client *client, uint64_t stream_id, int32_t error_code);
size_t zig_h3_fetch_event_size(void);
size_t zig_h3_wt_event_size(void);
int zig_h3_wt_event_copy(const zig_h3_wt_event *src, zig_h3_wt_event *dst);
size_t zig_h3_header_size(void);
int zig_h3_fetch_event_copy(const zig_h3_fetch_event *src, zig_h3_fetch_event *dst);
int zig_h3_header_copy(const zig_h3_header *src, zig_h3_header *dst);
int zig_h3_header_copy_at(const zig_h3_header *base, size_t len, size_t index, zig_h3_header *dst);
int zig_h3_headers_copy(const zig_h3_header *base, size_t len, zig_h3_header *dst, size_t dst_len);
int zig_h3_copy_bytes(const unsigned char *src, size_t len, unsigned char *dst);
int zig_h3_client_send_h3_datagram(zig_h3_client *client, uint64_t stream_id, const uint8_t *data, size_t data_len);
int zig_h3_client_send_datagram(zig_h3_client *client, const uint8_t *data, size_t data_len);
int zig_h3_client_run_once(zig_h3_client *client);
int zig_h3_client_poll(zig_h3_client *client);
zig_h3_wt_session *zig_h3_client_open_webtransport(
    zig_h3_client *client,
    const char *path,
    size_t path_len,
    zig_h3_wt_event_cb callback,
    void *user_data);
int zig_h3_wt_session_close(
    zig_h3_wt_session *session,
    uint32_t error_code,
    const uint8_t *reason,
    size_t reason_len);
int zig_h3_wt_session_send_datagram(
    zig_h3_wt_session *session,
    const uint8_t *data,
    size_t data_len);
int zig_h3_wt_session_receive_datagram(
    zig_h3_wt_session *session,
    zig_h3_bytes *out_datagram);
int zig_h3_wt_session_free_datagram(
    zig_h3_wt_session *session,
    const uint8_t *data,
    size_t data_len);
int zig_h3_wt_session_is_established(zig_h3_wt_session *session);
uint64_t zig_h3_wt_session_stream_id(zig_h3_wt_session *session);
int zig_h3_wt_session_free(zig_h3_wt_session *session);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // ZIG_H3_H
