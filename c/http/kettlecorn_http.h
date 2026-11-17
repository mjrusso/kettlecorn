/*
 * A blocking HTTP client over wasi:http/client@0.3.0 (WASIp3), used by
 * the `wasm` NIF (wasm:http_send/8, http_read/2, http_close/1).
 *
 * "Blocking" means the calling thread waits on a component-model waitable
 * set; with cooperative threads the other BEAM threads keep running.
 */
#ifndef KETTLECORN_HTTP_H
#define KETTLECORN_HTTP_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    const uint8_t *name;
    size_t name_len;
    const uint8_t *value;
    size_t value_len;
} kettlecorn_http_header_t;

/* Called up to n_headers times. Header bytes must remain valid until send returns.
 * Return 0 if the next header cannot be decoded. */
typedef int (*kettlecorn_http_next_header_t)(void *context, kettlecorn_http_header_t *header);

/* Header bytes are borrowed for the duration of the callback. Return 0 on
 * allocation failure; the client releases the response and reports it. */
typedef int (*kettlecorn_http_receive_header_t)(void *context,
                                               const kettlecorn_http_header_t *header);

typedef struct kettlecorn_http kettlecorn_http_t;

typedef struct {
    enum {
        KETTLECORN_HTTP_TIMEOUT_DEFAULT,
        KETTLECORN_HTTP_TIMEOUT_FINITE,
        KETTLECORN_HTTP_TIMEOUT_INFINITE
    } kind;
    uint64_t ns;
} kettlecorn_http_timeout_t;

typedef struct {
    const char *method;      /* "GET", "POST", ... */
    size_t method_len;
    int https;               /* 1 = https, 0 = http */
    const char *authority;   /* host[:port] */
    size_t authority_len;
    const char *path;        /* path with query, starting with "/" */
    size_t path_len;
    kettlecorn_http_next_header_t next_header;
    void *header_context;
    size_t n_headers;
    const uint8_t *body;     /* NULL = no body */
    size_t body_len;
    kettlecorn_http_timeout_t connect_timeout;
    kettlecorn_http_timeout_t first_byte_timeout;     /* until the response head */
    kettlecorn_http_timeout_t between_bytes_timeout;  /* between parts of the body */
} kettlecorn_http_request_t;

enum { KETTLECORN_HTTP_BAD_HEADER_ENTRY = -2 };

/* Returns 0 with the status and body handle after visiting response headers.
 * KETTLECORN_HTTP_BAD_HEADER_ENTRY means next_header failed; other failures
 * return -1 and point *error at a static error name. */
int kettlecorn_http_send(const kettlecorn_http_request_t *req, kettlecorn_http_t **out,
                      uint16_t *status, kettlecorn_http_receive_header_t receive_header,
                      void *context, const char **error);

/* Reads up to max body bytes. Returns the count, 0 at the end of the body, or
 * -1 with *error set (for instance when the body was cut short:
 * "http_response_incomplete", "connection_read_timeout"). */
ssize_t kettlecorn_http_read(kettlecorn_http_t *h, uint8_t *buf, size_t max, const char **error);

/* Releases the body stream and the handle. */
void kettlecorn_http_close(kettlecorn_http_t *h);

#endif
