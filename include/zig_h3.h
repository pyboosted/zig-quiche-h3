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
} zig_h3_request;

/** Request callback signature. */
typedef void (*zig_h3_request_cb)(void *user, const zig_h3_request *req, zig_h3_response *resp);
typedef void (*zig_h3_datagram_cb)(void *user, const zig_h3_request *req, zig_h3_response *resp, const uint8_t *data, size_t data_len);
typedef void (*zig_h3_wt_session_cb)(void *user, const zig_h3_request *req, zig_h3_wt_session *session);

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
int zig_h3_server_start(zig_h3_server *server);
int zig_h3_server_stop(zig_h3_server *server);

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

int zig_h3_wt_accept(zig_h3_wt_session *session);
int zig_h3_wt_reject(zig_h3_wt_session *session, uint16_t status);
int zig_h3_wt_close(zig_h3_wt_session *session, uint32_t code, const uint8_t *reason, size_t reason_len);
int zig_h3_wt_send_datagram(zig_h3_wt_session *session, const uint8_t *data, size_t data_len);
int zig_h3_wt_release(zig_h3_wt_session *session);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // ZIG_H3_H
