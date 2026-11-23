#ifndef KETTLECORN_NIF_H
#define KETTLECORN_NIF_H

#include <stddef.h>
#include "erl_nif.h"

#ifdef __wasi__
int kettlecorn_http_nif_load(ErlNifEnv *env, ErlNifResourceFlags flags);
ERL_NIF_TERM kettlecorn_send_message(ErlNifEnv *env, const unsigned char *data, size_t size);

void kettlecorn_bridge_start(void);

void kettlecorn_stdin_select(ErlNifEnv *env, void *owner, ERL_NIF_TERM ref);
/* A null pid releases the owner unconditionally; otherwise only its reader. */
void kettlecorn_stdin_deselect(void *owner, const ErlNifPid *pid);
/* Reads report EOF only after all queued bytes have been consumed. */
ERL_NIF_TERM kettlecorn_stdin_read(ErlNifEnv *env, size_t n);
ERL_NIF_TERM kettlecorn_tty_window_size(ErlNifEnv *env, int width, int height);

/* kettlecorn_bridge.c: reports a fatal error to the host (called from erl_init.c). */
void js_bridge_on_error(const char *data, int len);

ERL_NIF_TERM kettlecorn_getaddrinfo_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

ERL_NIF_TERM kettlecorn_http_available_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM kettlecorn_http_send_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM kettlecorn_http_read_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM kettlecorn_http_close_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

int kettlecorn_budget_nif_load(ErlNifEnv *env, ErlNifResourceFlags flags);
ERL_NIF_TERM kettlecorn_budget_new_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM kettlecorn_budget_attach_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM kettlecorn_budget_close_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif

#endif
