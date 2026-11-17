/*
 * HTTP over wasi:http/client (WASIp3) for Kettlecorn.HTTP.
 * Link c/http's client only into beam-http.wasm: unconditional linking
 * would make every VM require wasi:http interfaces, including without a grant.
 * Without the client, these weak symbols are null.
 */
#include <stdint.h>
#include <string.h>
#include <sys/types.h>

#include "kettlecorn_http.h"
#include "kettlecorn_nif.h"

static ErlNifResourceType *wasm_http_type = NULL;

static ERL_NIF_TERM error(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, reason));
}

extern int kettlecorn_http_send(const kettlecorn_http_request_t *, kettlecorn_http_t **, uint16_t *,
                             kettlecorn_http_receive_header_t, void *, const char **)
    __attribute__((weak));
extern ssize_t kettlecorn_http_read(kettlecorn_http_t *, uint8_t *, size_t, const char **)
    __attribute__((weak));
extern void kettlecorn_http_close(kettlecorn_http_t *) __attribute__((weak));
#define HTTP_LINKED (kettlecorn_http_send != NULL)

typedef struct {
  ErlNifMutex *lock;
  kettlecorn_http_t *h;
} wasm_http_t;

static void wasm_http_dtor(ErlNifEnv *env, void *obj) {
  wasm_http_t *r = obj;
  (void)env;
  if (r->h) kettlecorn_http_close(r->h);
  r->h = NULL;
  if (r->lock) enif_mutex_destroy(r->lock);
}

int kettlecorn_http_nif_load(ErlNifEnv *env, ErlNifResourceFlags flags) {
  ErlNifResourceTypeInit init = {wasm_http_dtor, NULL, NULL};
  wasm_http_type = enif_open_resource_type_x(env, "wasm_http", &init, flags, NULL);
  return wasm_http_type != NULL;
}

ERL_NIF_TERM kettlecorn_http_available_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc; (void)argv;
  return enif_make_atom(env, HTTP_LINKED ? "true" : "false");
}

typedef struct {
  ErlNifEnv *env;
  ERL_NIF_TERM list;
} response_headers_t;

typedef struct {
  ErlNifEnv *env;
  ERL_NIF_TERM rest;
} request_headers_t;

static int next_request_header(void *context, kettlecorn_http_header_t *header) {
  request_headers_t *headers = context;
  ERL_NIF_TERM head, tail;
  int arity;
  const ERL_NIF_TERM *kv;
  ErlNifBinary name, value;
  if (!enif_get_list_cell(headers->env, headers->rest, &head, &tail) ||
      !enif_get_tuple(headers->env, head, &arity, &kv) || arity != 2 ||
      !enif_inspect_binary(headers->env, kv[0], &name) ||
      !enif_inspect_binary(headers->env, kv[1], &value)) {
    return 0;
  }
  header->name = name.data; header->name_len = name.size;
  header->value = value.data; header->value_len = value.size;
  headers->rest = tail;
  return 1;
}

static int binary_term(ErlNifEnv *env, const uint8_t *p, size_t n, ERL_NIF_TERM *term) {
  unsigned char *d = enif_make_new_binary(env, n, term);
  if (n) {
    if (d == NULL) return 0;
    memcpy(d, p, n);
  }
  return 1;
}

static int receive_header(void *context, const kettlecorn_http_header_t *header) {
  response_headers_t *headers = context;
  ERL_NIF_TERM name, value;
  if (!binary_term(headers->env, header->name, header->name_len, &name) ||
      !binary_term(headers->env, header->value, header->value_len, &value)) return 0;
  headers->list = enif_make_list_cell(
      headers->env, enif_make_tuple2(headers->env, name, value), headers->list);
  return 1;
}

static int get_timeout(ErlNifEnv *env, ERL_NIF_TERM term, kettlecorn_http_timeout_t *timeout) {
  ErlNifUInt64 ms;
  if (enif_is_identical(term, enif_make_atom(env, "default"))) {
    timeout->kind = KETTLECORN_HTTP_TIMEOUT_DEFAULT;
  } else if (enif_is_identical(term, enif_make_atom(env, "infinity"))) {
    timeout->kind = KETTLECORN_HTTP_TIMEOUT_INFINITE;
  } else if (enif_get_uint64(env, term, &ms) && ms <= UINT64_MAX / 1000000ull) {
    timeout->kind = KETTLECORN_HTTP_TIMEOUT_FINITE;
    timeout->ns = ms * 1000000ull;
  } else {
    return 0;
  }
  return 1;
}

ERL_NIF_TERM kettlecorn_http_send_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary method, authority, path, body;
  ERL_NIF_TERM list, result;
  kettlecorn_http_request_t req;
  request_headers_t headers;
  response_headers_t response;
  unsigned list_len;
  uint16_t status;
  kettlecorn_http_t *h = NULL;
  const char *err = NULL;
  wasm_http_t *res;

  if (!HTTP_LINKED) return error(env, "unsupported");
  memset(&req, 0, sizeof(req));
  if (argc != 8 || !enif_inspect_binary(env, argv[0], &method) ||
      !enif_inspect_binary(env, argv[2], &authority) ||
      !enif_inspect_binary(env, argv[3], &path) ||
      !enif_get_list_length(env, argv[4], &list_len) ||
      !get_timeout(env, argv[6], &req.connect_timeout) ||
      !get_timeout(env, argv[7], &req.first_byte_timeout)) {
    return enif_make_badarg(env);
  }
  req.method = (const char *)method.data; req.method_len = method.size;
  req.https = enif_is_identical(argv[1], enif_make_atom(env, "https"));
  req.authority = (const char *)authority.data; req.authority_len = authority.size;
  req.path = (const char *)path.data; req.path_len = path.size;
  if (enif_inspect_binary(env, argv[5], &body)) {
    req.body = body.data ? body.data : (const uint8_t *)"";
    req.body_len = body.size;
  }
  req.between_bytes_timeout = req.first_byte_timeout;

  headers.env = env;
  headers.rest = argv[4];
  req.next_header = next_request_header;
  req.header_context = &headers;
  req.n_headers = list_len;

  response.env = env;
  response.list = enif_make_list(env, 0);
  int rc = kettlecorn_http_send(&req, &h, &status, receive_header, &response, &err);
  if (rc == KETTLECORN_HTTP_BAD_HEADER_ENTRY) return enif_make_badarg(env);
  if (rc != 0) return error(env, err);

  enif_make_reverse_list(env, response.list, &list);

  res = enif_alloc_resource(wasm_http_type, sizeof(wasm_http_t));
  if (res == NULL) {
    kettlecorn_http_close(h);
    return error(env, "out_of_memory");
  }
  res->h = h;
  res->lock = enif_mutex_create("wasm_http");
  if (res->lock == NULL) {
    enif_release_resource(res); /* the destructor closes h */
    return error(env, "out_of_memory");
  }
  result = enif_make_resource(env, res);
  enif_release_resource(res);
  return enif_make_tuple4(env, enif_make_atom(env, "ok"), result, enif_make_uint(env, status), list);
}

/* http_read(Ref, Max) -> {ok, Bin} | eof | {error, Reason} */
ERL_NIF_TERM kettlecorn_http_read_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  wasm_http_t *res;
  unsigned int max;
  ErlNifBinary bin;
  const char *err = NULL;
  ssize_t n;

  if (!HTTP_LINKED) return error(env, "unsupported");
  if (argc != 2 || !enif_get_resource(env, argv[0], wasm_http_type, (void **)&res) ||
      !enif_get_uint(env, argv[1], &max) || max == 0) {
    return enif_make_badarg(env);
  }
  enif_mutex_lock(res->lock);
  if (res->h == NULL) {
    enif_mutex_unlock(res->lock);
    return error(env, "closed");
  }
  if (!enif_alloc_binary(max, &bin)) {
    enif_mutex_unlock(res->lock);
    return error(env, "out_of_memory");
  }
  n = kettlecorn_http_read(res->h, bin.data, max, &err);
  enif_mutex_unlock(res->lock);
  if (n < 0) {
    enif_release_binary(&bin);
    return error(env, err);
  }
  if (n == 0) {
    enif_release_binary(&bin);
    return enif_make_atom(env, "eof");
  }
  if (!enif_realloc_binary(&bin, (size_t)n)) {
    enif_release_binary(&bin);
    return error(env, "out_of_memory");
  }
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_binary(env, &bin));
}

ERL_NIF_TERM kettlecorn_http_close_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  wasm_http_t *res;
  if (!HTTP_LINKED) return error(env, "unsupported");
  if (argc != 1 || !enif_get_resource(env, argv[0], wasm_http_type, (void **)&res))
    return enif_make_badarg(env);
  enif_mutex_lock(res->lock);
  if (res->h) kettlecorn_http_close(res->h);
  res->h = NULL;
  enif_mutex_unlock(res->lock);
  return enif_make_atom(env, "ok");
}
