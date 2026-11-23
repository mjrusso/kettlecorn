#ifndef KETTLECORN_PLATFORM_H
#define KETTLECORN_PLATFORM_H

#if defined(__EMSCRIPTEN__) || defined(ERTS_EMSCRIPTEN) || defined(__wasi__)
#define KETTLECORN_WASM 1
#endif

#if defined(__wasi__) && !defined(__ASSEMBLER__)
void kettlecorn_scheduler_yield(void);
void kettlecorn_scheduler_wait(void);
_Noreturn void kettlecorn_wait_for_halt(const volatile int *exit_code);

/* Reduction budgets (c/nif/kettlecorn_budget.c), called from erl_process.c. */
struct process;
void *kettlecorn_budget_inherit(struct process *parent);
void kettlecorn_budget_charge(struct process *p, long reds);
void kettlecorn_budget_release(void *budget);
#endif

#endif
