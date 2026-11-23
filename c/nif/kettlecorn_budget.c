/*
 * The OTP hooks in patch 0108 must charge the budget wherever the
 * scheduler adds to p->reds. Keep exhausted budgets attached after close
 * so descendants are killed the next time they account for reductions.
 */
#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "global.h"
#include "erl_process.h"
#include "erl_proc_sig_queue.h"
#include "kettlecorn_nif.h"

#define EXHAUSTED 1
#define CLOSED 2

typedef struct {
  erts_atomic64_t used;
  Sint64 limit; /* 0: no limit */
  erts_atomic32_t flags;
  Eterm root;
} budget_t;

static ErlNifResourceType *budget_type = NULL;

int kettlecorn_budget_nif_load(ErlNifEnv *env, ErlNifResourceFlags flags) {
  ErlNifResourceTypeInit init = {.members = 0};
  budget_type = enif_open_resource_type_x(env, "kettlecorn_budget", &init, flags, NULL);
  return budget_type != NULL;
}

/* A closed budget that was exceeded still kills the processes it charges. */
static int finished(budget_t *b) {
  return (erts_atomic32_read_nob(&b->flags) & (CLOSED | EXHAUSTED)) == CLOSED;
}

void *kettlecorn_budget_inherit(Process *parent) {
  budget_t *b = parent ? parent->kettlecorn_budget : NULL;
  if (!b || finished(b)) return NULL;
  enif_keep_resource(b);
  return b;
}

void kettlecorn_budget_release(void *budget) {
  if (budget) enif_release_resource(budget);
}

static void kill_process(Process *p, Eterm to) {
  erts_proc_sig_send_exit(&p->common, p->common.id, to, am_kill, NIL, 0, 0);
}

void kettlecorn_budget_charge(Process *p, long reds) {
  budget_t *b = p->kettlecorn_budget;
  if (!b || reds <= 0) return;
  erts_aint32_t flags = erts_atomic32_read_nob(&b->flags);
  if (!(flags & EXHAUSTED)) {
    if (flags & CLOSED) return;
    Sint64 used = erts_atomic64_add_read_nob(&b->used, reds);
    if (!b->limit || used <= b->limit) return;
    erts_aint32_t old = erts_atomic32_read_bor_nob(&b->flags, EXHAUSTED);
    if (!(old & EXHAUSTED) && b->root != p->common.id) kill_process(p, b->root);
  }
  if (!(erts_atomic32_read_nob(&p->state) & ERTS_PSFLG_EXITING)) kill_process(p, p->common.id);
}

ERL_NIF_TERM kettlecorn_budget_new_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifSInt64 limit;
  if (argc != 1) return enif_make_badarg(env);
  if (enif_is_identical(argv[0], enif_make_atom(env, "infinity"))) {
    limit = 0;
  } else if (!enif_get_int64(env, argv[0], &limit) || limit <= 0) {
    return enif_make_badarg(env);
  }
  budget_t *b = enif_alloc_resource(budget_type, sizeof(budget_t));
  erts_atomic64_init_nob(&b->used, 0);
  b->limit = limit;
  erts_atomic32_init_nob(&b->flags, 0);
  b->root = NIL;
  ERL_NIF_TERM term = enif_make_resource(env, b);
  enif_release_resource(b);
  return term;
}

/* Reject reattachment so a process cannot replace its inherited budget. */
ERL_NIF_TERM kettlecorn_budget_attach_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  budget_t *b;
  Process *p = env->proc;
  if (argc != 1 || !enif_get_resource(env, argv[0], budget_type, (void **)&b))
    return enif_make_badarg(env);
  if (p->kettlecorn_budget)
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "attached"));
  enif_keep_resource(b);
  if (b->root == NIL) b->root = p->common.id;
  p->kettlecorn_budget = b;
  return enif_make_atom(env, "ok");
}

ERL_NIF_TERM kettlecorn_budget_close_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  budget_t *b;
  if (argc != 1 || !enif_get_resource(env, argv[0], budget_type, (void **)&b))
    return enif_make_badarg(env);
  erts_aint32_t flags = erts_atomic32_read_bor_nob(&b->flags, CLOSED);
  return enif_make_tuple2(env, enif_make_int64(env, erts_atomic64_read_nob(&b->used)),
                          enif_make_atom(env, (flags & EXHAUSTED) ? "true" : "false"));
}
