/*
 * Blocking HTTP client over wasi:http/client@0.3.0, see kettlecorn_http.h.
 * Uses the C bindings wit-bindgen generates from world.wit (see README.md).
 */
#include <stdlib.h>
#include <string.h>

#include "gen/http_nif.h"
#include "kettlecorn_http.h"

struct kettlecorn_http {
    wasi_http_types_stream_u8_t body;
    wasi_http_types_future_result_option_own_trailers_error_code_t trailers;
    wasi_http_types_future_result_void_error_code_writer_t result_writer;
    int done;            /* the body stream ended */
    const char *error;   /* how it ended, if not cleanly */
};

static const char *error_names[] = {
    [WASI_HTTP_TYPES_ERROR_CODE_DNS_TIMEOUT] = "dns_timeout",
    [WASI_HTTP_TYPES_ERROR_CODE_DNS_ERROR] = "dns_error",
    [WASI_HTTP_TYPES_ERROR_CODE_DESTINATION_NOT_FOUND] = "destination_not_found",
    [WASI_HTTP_TYPES_ERROR_CODE_DESTINATION_UNAVAILABLE] = "destination_unavailable",
    [WASI_HTTP_TYPES_ERROR_CODE_DESTINATION_IP_PROHIBITED] = "destination_ip_prohibited",
    [WASI_HTTP_TYPES_ERROR_CODE_DESTINATION_IP_UNROUTABLE] = "destination_ip_unroutable",
    [WASI_HTTP_TYPES_ERROR_CODE_CONNECTION_REFUSED] = "connection_refused",
    [WASI_HTTP_TYPES_ERROR_CODE_CONNECTION_TERMINATED] = "connection_terminated",
    [WASI_HTTP_TYPES_ERROR_CODE_CONNECTION_TIMEOUT] = "connection_timeout",
    [WASI_HTTP_TYPES_ERROR_CODE_CONNECTION_READ_TIMEOUT] = "connection_read_timeout",
    [WASI_HTTP_TYPES_ERROR_CODE_CONNECTION_WRITE_TIMEOUT] = "connection_write_timeout",
    [WASI_HTTP_TYPES_ERROR_CODE_CONNECTION_LIMIT_REACHED] = "connection_limit_reached",
    [WASI_HTTP_TYPES_ERROR_CODE_TLS_PROTOCOL_ERROR] = "tls_protocol_error",
    [WASI_HTTP_TYPES_ERROR_CODE_TLS_CERTIFICATE_ERROR] = "tls_certificate_error",
    [WASI_HTTP_TYPES_ERROR_CODE_TLS_ALERT_RECEIVED] = "tls_alert_received",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_DENIED] = "http_request_denied",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_LENGTH_REQUIRED] = "http_request_length_required",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_BODY_SIZE] = "http_request_body_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_METHOD_INVALID] = "http_request_method_invalid",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_URI_INVALID] = "http_request_uri_invalid",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_URI_TOO_LONG] = "http_request_uri_too_long",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_HEADER_SECTION_SIZE] = "http_request_header_section_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_HEADER_SIZE] = "http_request_header_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_TRAILER_SECTION_SIZE] = "http_request_trailer_section_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_REQUEST_TRAILER_SIZE] = "http_request_trailer_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_INCOMPLETE] = "http_response_incomplete",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_HEADER_SECTION_SIZE] = "http_response_header_section_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_HEADER_SIZE] = "http_response_header_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_BODY_SIZE] = "http_response_body_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_TRAILER_SECTION_SIZE] = "http_response_trailer_section_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_TRAILER_SIZE] = "http_response_trailer_size",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_TRANSFER_CODING] = "http_response_transfer_coding",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_CONTENT_CODING] = "http_response_content_coding",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_RESPONSE_TIMEOUT] = "http_response_timeout",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_UPGRADE_FAILED] = "http_upgrade_failed",
    [WASI_HTTP_TYPES_ERROR_CODE_HTTP_PROTOCOL_ERROR] = "http_protocol_error",
    [WASI_HTTP_TYPES_ERROR_CODE_LOOP_DETECTED] = "loop_detected",
    [WASI_HTTP_TYPES_ERROR_CODE_CONFIGURATION_ERROR] = "configuration_error",
    [WASI_HTTP_TYPES_ERROR_CODE_INTERNAL_ERROR] = "internal_error",
};

static const char *error_name(const wasi_http_types_error_code_t *e) {
    if (e->tag < sizeof(error_names) / sizeof(error_names[0]) && error_names[e->tag])
        return error_names[e->tag];
    return "internal_error";
}

static void wait_on(uint32_t waitable, http_nif_event_t *ev) {
    http_nif_waitable_set_t set = http_nif_waitable_set_new();
    http_nif_waitable_join(waitable, set);
    http_nif_waitable_set_wait(set, ev);
    http_nif_waitable_join(waitable, 0);
    http_nif_waitable_set_drop(set);
}

/* Completes a stream/future operation that may have returned BLOCKED;
 * returns the final status (state | count << 4). */
static http_nif_waitable_status_t finish(uint32_t handle, http_nif_waitable_status_t st) {
    if (st != HTTP_NIF_WAITABLE_STATUS_BLOCKED) return st;
    http_nif_event_t ev;
    wait_on(handle, &ev);
    return ev.code;
}

static bool set_method(wasi_http_types_borrow_request_t r, const char *m, size_t n) {
    static const struct { const char *name; uint8_t tag; } known[] = {
        {"GET", WASI_HTTP_TYPES_METHOD_GET},         {"HEAD", WASI_HTTP_TYPES_METHOD_HEAD},
        {"POST", WASI_HTTP_TYPES_METHOD_POST},       {"PUT", WASI_HTTP_TYPES_METHOD_PUT},
        {"DELETE", WASI_HTTP_TYPES_METHOD_DELETE},   {"CONNECT", WASI_HTTP_TYPES_METHOD_CONNECT},
        {"OPTIONS", WASI_HTTP_TYPES_METHOD_OPTIONS}, {"TRACE", WASI_HTTP_TYPES_METHOD_TRACE},
        {"PATCH", WASI_HTTP_TYPES_METHOD_PATCH},
    };
    wasi_http_types_method_t method;
    memset(&method, 0, sizeof(method));
    method.tag = WASI_HTTP_TYPES_METHOD_OTHER;
    for (size_t i = 0; i < sizeof(known) / sizeof(known[0]); i++) {
        if (strlen(known[i].name) == n && memcmp(known[i].name, m, n) == 0) {
            method.tag = known[i].tag;
            break;
        }
    }
    if (method.tag == WASI_HTTP_TYPES_METHOD_OTHER) {
        method.val.other.ptr = (uint8_t *)m;
        method.val.other.len = n;
    }
    return wasi_http_types_method_request_set_method(r, &method);
}

static bool set_timeout(wasi_http_types_borrow_request_options_t o,
                        kettlecorn_http_timeout_t timeout, uint64_t default_ns,
                        bool (*set)(wasi_http_types_borrow_request_options_t,
                                    wasi_http_types_duration_t *,
                                    wasi_http_types_request_options_error_t *)) {
    wasi_http_types_duration_t d = timeout.kind == KETTLECORN_HTTP_TIMEOUT_DEFAULT
        ? default_ns : timeout.ns;
    wasi_http_types_request_options_error_t err;
    return set(o, &d, &err);
}

int kettlecorn_http_send(const kettlecorn_http_request_t *req, kettlecorn_http_t **out,
                      uint16_t *status, kettlecorn_http_receive_header_t receive_header,
                      void *context, const char **error) {
    /* wasi:http has finite durations and embedder defaults, but no infinity. */
    if (req->connect_timeout.kind == KETTLECORN_HTTP_TIMEOUT_INFINITE ||
        req->first_byte_timeout.kind == KETTLECORN_HTTP_TIMEOUT_INFINITE ||
        req->between_bytes_timeout.kind == KETTLECORN_HTTP_TIMEOUT_INFINITE) {
        *error = "unsupported_timeout";
        return -1;
    }
    wasi_http_types_tuple2_field_name_field_value_t *entries =
        calloc(req->n_headers ? req->n_headers : 1, sizeof(*entries));
    if (!entries) { *error = "out_of_memory"; return -1; }
    for (size_t i = 0; i < req->n_headers; i++) {
        kettlecorn_http_header_t header;
        if (!req->next_header(req->header_context, &header)) {
            free(entries);
            return KETTLECORN_HTTP_BAD_HEADER_ENTRY;
        }
        entries[i].f0.ptr = (uint8_t *)header.name;
        entries[i].f0.len = header.name_len;
        entries[i].f1.ptr = (uint8_t *)header.value;
        entries[i].f1.len = header.value_len;
    }
    wasi_http_types_list_tuple2_field_name_field_value_t list = {entries, req->n_headers};
    wasi_http_types_own_fields_t fields;
    wasi_http_types_header_error_t herr;
    bool ok = wasi_http_types_static_fields_from_list(&list, &fields, &herr);
    free(entries);
    if (!ok) { *error = "invalid_header"; return -1; }

    /* Body stream and trailers future; the request keeps their read ends. */
    wasi_http_types_stream_u8_writer_t body_writer = 0;
    wasi_http_types_stream_u8_t body_reader = 0;
    if (req->body != NULL)
        body_reader = wasi_http_types_stream_u8_new(&body_writer);
    wasi_http_types_future_result_option_own_trailers_error_code_writer_t trailers_writer;
    wasi_http_types_future_result_option_own_trailers_error_code_t trailers_reader =
        wasi_http_types_future_result_option_own_trailers_error_code_new(&trailers_writer);

    wasi_http_types_own_request_options_t options = wasi_http_types_constructor_request_options();
    wasi_http_types_borrow_request_options_t bo = wasi_http_types_borrow_request_options(options);
    bool options_ok =
        set_timeout(bo, req->connect_timeout, 30000000000ull,
                    wasi_http_types_method_request_options_set_connect_timeout) &&
        set_timeout(bo, req->first_byte_timeout, 15000000000ull,
                    wasi_http_types_method_request_options_set_first_byte_timeout) &&
        set_timeout(bo, req->between_bytes_timeout, 15000000000ull,
                    wasi_http_types_method_request_options_set_between_bytes_timeout);

    wasi_http_types_tuple2_own_request_future_result_void_error_code_t created;
    wasi_http_types_static_request_new(fields, req->body ? &body_reader : NULL,
                                       trailers_reader, &options, &created);
    wasi_http_types_own_request_t request = created.f0;
    /* How the transmission ended; the response (or its error) is enough. */
    wasi_http_types_future_result_void_error_code_drop_readable(created.f1);

    wasi_http_types_borrow_request_t br = wasi_http_types_borrow_request(request);
    wasi_http_types_scheme_t scheme;
    memset(&scheme, 0, sizeof(scheme));
    scheme.tag = req->https ? WASI_HTTP_TYPES_SCHEME_HTTPS : WASI_HTTP_TYPES_SCHEME_HTTP;
    http_nif_string_t authority = {(uint8_t *)req->authority, req->authority_len};
    http_nif_string_t path = {(uint8_t *)req->path, req->path_len};
    const char *invalid = NULL;
    if (!options_ok)
        invalid = "configuration_error";
    else if (!set_method(br, req->method, req->method_len))
        invalid = "http_request_method_invalid";
    else if (!wasi_http_types_method_request_set_scheme(br, &scheme) ||
             !wasi_http_types_method_request_set_authority(br, &authority) ||
             !wasi_http_types_method_request_set_path_with_query(br, &path))
        invalid = "http_request_uri_invalid";
    if (invalid) {
        wasi_http_types_request_drop_own(request);
        if (body_writer) wasi_http_types_stream_u8_drop_writable(body_writer);
        wasi_http_types_future_result_option_own_trailers_error_code_drop_writable(trailers_writer);
        *error = invalid;
        return -1;
    }

    /* send() takes ownership of the request. */
    wasi_http_client_result_own_response_error_code_t result;
    memset(&result, 0, sizeof(result));
    http_nif_subtask_status_t sst = wasi_http_client_send(request, &result);

    if (body_writer) {
        size_t off = 0;
        while (off < req->body_len) {
            http_nif_waitable_status_t st = finish(body_writer,
                wasi_http_types_stream_u8_write(body_writer, req->body + off, req->body_len - off));
            off += HTTP_NIF_WAITABLE_COUNT(st);
            if (HTTP_NIF_WAITABLE_STATE(st) != HTTP_NIF_WAITABLE_COMPLETED) break;
        }
        wasi_http_types_stream_u8_drop_writable(body_writer);
    }
    {
        /* No trailers. */
        wasi_http_types_result_option_own_trailers_error_code_t none;
        memset(&none, 0, sizeof(none));
        finish(trailers_writer,
               wasi_http_types_future_result_option_own_trailers_error_code_write(trailers_writer, &none));
        wasi_http_types_future_result_option_own_trailers_error_code_drop_writable(trailers_writer);
    }

    if (HTTP_NIF_SUBTASK_STATE(sst) != HTTP_NIF_SUBTASK_RETURNED) {
        http_nif_subtask_t task = HTTP_NIF_SUBTASK_HANDLE(sst);
        for (;;) {
            http_nif_event_t ev;
            wait_on(task, &ev);
            if (ev.event == HTTP_NIF_EVENT_SUBTASK && ev.code == HTTP_NIF_SUBTASK_RETURNED) break;
        }
        http_nif_subtask_drop(task);
    }

    if (result.is_err) {
        *error = error_name(&result.val.err);
        wasi_http_client_result_own_response_error_code_free(&result);
        return -1;
    }

    wasi_http_types_own_response_t response = result.val.ok;
    wasi_http_types_borrow_response_t brsp = wasi_http_types_borrow_response(response);
    *status = wasi_http_types_method_response_get_status_code(brsp);
    wasi_http_types_own_headers_t rh = wasi_http_types_method_response_get_headers(brsp);
    wasi_http_types_list_tuple2_field_name_field_value_t all;
    wasi_http_types_method_fields_copy_all(wasi_http_types_borrow_fields(rh), &all);
    wasi_http_types_fields_drop_own(rh);
    bool headers_ok = true;
    for (size_t i = 0; i < all.len; i++) {
        kettlecorn_http_header_t header = {
            all.ptr[i].f0.ptr, all.ptr[i].f0.len,
            all.ptr[i].f1.ptr, all.ptr[i].f1.len
        };
        if (!receive_header(context, &header)) { headers_ok = false; break; }
    }
    wasi_http_types_list_tuple2_field_name_field_value_free(&all);
    kettlecorn_http_t *h = headers_ok ? calloc(1, sizeof(*h)) : NULL;
    if (!h) {
        wasi_http_types_response_drop_own(response);
        *error = "out_of_memory";
        return -1;
    }

    wasi_http_types_future_result_void_error_code_t result_reader =
        wasi_http_types_future_result_void_error_code_new(&h->result_writer);
    wasi_http_types_tuple2_stream_u8_future_result_option_own_trailers_error_code_t body;
    wasi_http_types_static_response_consume_body(response, result_reader, &body);
    h->body = body.f0;
    h->trailers = body.f1;
    *out = h;
    return 0;
}

/* The body stream ended: its trailers future says whether the whole body
 * arrived (a timeout or a lost connection ends the stream too). */
static const char *body_error(kettlecorn_http_t *h) {
    wasi_http_types_result_option_own_trailers_error_code_t r;
    memset(&r, 0, sizeof(r));
    http_nif_waitable_status_t st = finish(
        h->trailers, wasi_http_types_future_result_option_own_trailers_error_code_read(h->trailers, &r));
    if (HTTP_NIF_WAITABLE_STATE(st) != HTTP_NIF_WAITABLE_COMPLETED) return "http_response_incomplete";
    const char *error = r.is_err ? error_name(&r.val.err) : NULL;
    wasi_http_types_result_option_own_trailers_error_code_free(&r);
    return error;
}

ssize_t kettlecorn_http_read(kettlecorn_http_t *h, uint8_t *buf, size_t max, const char **error) {
    if (h->done) {
        if (!h->error) return 0;
        *error = h->error;
        return -1;
    }
    /* Reads are never cancelled; after waiting, their state is COMPLETED or DROPPED. */
    http_nif_waitable_status_t st = finish(h->body, wasi_http_types_stream_u8_read(h->body, buf, max));
    ssize_t count = (ssize_t)HTTP_NIF_WAITABLE_COUNT(st);
    if (HTTP_NIF_WAITABLE_STATE(st) == HTTP_NIF_WAITABLE_DROPPED) {
        h->done = 1;
        h->error = body_error(h);
        /* Defer errors until the next read when this read returned body bytes. */
        if (count == 0 && h->error) {
            *error = h->error;
            return -1;
        }
    }
    return count;
}

void kettlecorn_http_close(kettlecorn_http_t *h) {
    if (!h) return;
    wasi_http_types_stream_u8_drop_readable(h->body);
    wasi_http_types_future_result_option_own_trailers_error_code_drop_readable(h->trailers);
    /* Report that the response was handled. */
    wasi_http_types_result_void_error_code_t okv;
    memset(&okv, 0, sizeof(okv));
    http_nif_waitable_status_t st =
        wasi_http_types_future_result_void_error_code_write(h->result_writer, &okv);
    if (st == HTTP_NIF_WAITABLE_STATUS_BLOCKED)
        wasi_http_types_future_result_void_error_code_cancel_write(h->result_writer);
    wasi_http_types_future_result_void_error_code_drop_writable(h->result_writer);
    free(h);
}
