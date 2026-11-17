#include <errno.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

#include "erl_nif.h"
#include "kettlecorn_http.h"

static char operation[64];
static ErlNifResourceType *reader_type;
static _Atomic int destroyed;
static int allocations;

static int running(const char *name) { return strcmp(operation, name) == 0; }

static void *bridge_malloc(size_t size) {
    if (running("allocation_failure") || (running("queue_allocation_failure") && allocations++ > 0)) return NULL;
    return malloc(size);
}

static ssize_t bridge_read(int fd, void *buf, size_t size) {
    if (running("read_failure")) { errno = EIO; return -1; }
    return read(fd, buf, size);
}

static int bridge_alloc_binary(size_t size, ErlNifBinary *bin) {
    return running("binary_allocation_failure") ? 0 : enif_alloc_binary(size, bin);
}

static int bridge_realloc_binary(ErlNifBinary *bin, size_t size) {
    return (running("binary_resize_failure") || running("http_binary_resize_failure")) ? 0 : enif_realloc_binary(bin, size);
}

#define enif_thread_create(...) EAGAIN
#define enif_alloc_binary bridge_alloc_binary
#define enif_realloc_binary bridge_realloc_binary
#define malloc bridge_malloc
#define read bridge_read
#include "../src/framing.c"
#include "../nif/kettlecorn_bridge.c"
#include "../nif/kettlecorn_tty.c"
#undef read
#undef malloc

int kettlecorn_http_send(const kettlecorn_http_request_t *request, kettlecorn_http_t **out,
                        uint16_t *status, kettlecorn_http_receive_header_t receive,
                        void *context, const char **error) {
    (void)request; (void)out; (void)status; (void)receive; (void)context;
    *error = "unsupported";
    return -1;
}

ssize_t kettlecorn_http_read(kettlecorn_http_t *handle, uint8_t *buf, size_t max, const char **error) {
    (void)handle; (void)max; (void)error;
    buf[0] = 'x';
    return 1;
}

void kettlecorn_http_close(kettlecorn_http_t *handle) { (void)handle; }

#include "../nif/kettlecorn_http_nif.c"


static void reader_dtor(ErlNifEnv *env, void *owner) {
    (void)env;
    kettlecorn_stdin_deselect(owner, NULL);
    destroyed++;
}

static int load(ErlNifEnv *env, void **data, ERL_NIF_TERM info) {
    (void)data; (void)info;
    reader_type = enif_open_resource_type(env, NULL, "stdin_reader_test", reader_dtor,
                                         ERL_NIF_RT_CREATE, NULL);
    return reader_type == NULL || !kettlecorn_http_nif_load(env, ERL_NIF_RT_CREATE);
}

static ERL_NIF_TERM run(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1 || !enif_get_atom(env, argv[0], operation, sizeof(operation), ERL_NIF_LATIN1)) return enif_make_badarg(env);
    if (running("startup_failure")) {
        kettlecorn_bridge_start();
    } else if (running("output")) {
        struct iovec parts[] = {{"err", 3}, {"or", 2}};
        __wrap_write(1, "out", 3);
        __wrap_writev(2, parts, 2);
        kettlecorn_send_message(env, (const unsigned char *)"message", 7);
    } else if (running("otp_fatal")) {
        js_bridge_on_error("fatal", 5);
    } else if (running("drain_stdin")) {
        queue_stdin((const unsigned char *)"abc", 3);
        queue_stdin(NULL, 0);
        ERL_NIF_TERM first = kettlecorn_stdin_read(env, 2);
        ERL_NIF_TERM rest = kettlecorn_stdin_read(env, 1024);
        ERL_NIF_TERM eof = kettlecorn_stdin_read(env, 1);
        return enif_make_tuple3(env, first, rest, eof);
    } else if (running("empty_stdin")) {
        ERL_NIF_TERM empty = kettlecorn_stdin_read(env, 1);
        queue_stdin((const unsigned char *)"x", 1);
        return enif_make_tuple2(env, empty, kettlecorn_stdin_read(env, 2));
    } else if (running("binary_allocation_failure") || running("binary_resize_failure")) {
        queue_stdin((const unsigned char *)"x", 1);
        return kettlecorn_stdin_read(env, 2);
    } else if (running("http_binary_resize_failure")) {
        wasm_http_t *resource = enif_alloc_resource(wasm_http_type, sizeof(*resource));
        resource->h = (kettlecorn_http_t *)1;
        resource->lock = enif_mutex_create("http_resize_test");
        ERL_NIF_TERM args[] = {enif_make_resource(env, resource), enif_make_uint(env, 1024)};
        enif_release_resource(resource);
        return kettlecorn_http_read_nif(env, 2, args);
    } else if (running("window_size")) {
        return kettlecorn_tty_window_size(env, 80, 24);
    } else if (running("reader_register")) {
        void *owner = enif_alloc_resource(reader_type, 1);
        kettlecorn_stdin_select(env, owner, enif_make_ref(env));
        enif_release_resource(owner);
    } else if (running("reader_unregister")) {
        kettlecorn_stdin_deselect(stdin_reader.owner, NULL);
    } else if (running("reader_destroyed")) {
        return enif_make_int(env, destroyed);
    } else if (running("read_input") || running("allocation_failure") ||
               running("queue_allocation_failure") || running("read_failure")) {
        wasi_bridge_reader(NULL);
    } else {
        return enif_make_badarg(env);
    }
    return enif_make_atom(env, "ok");
}

static ErlNifFunc functions[] = {{"operation", 1, run}};
ERL_NIF_INIT(bridge_test, functions, load, NULL, NULL, NULL)
