#include <limits.h>
#include <sched.h>
#include <stdlib.h>
#include <unistd.h>

#include "kettlecorn_platform.h"

void kettlecorn_scheduler_yield(void) {
    /* WASI threads share one OS thread, including the scheduler counter. */
    static unsigned int switches;
    if ((++switches & 7) == 0) sched_yield();
}

/* Idle waits can spin with the run queue locked; other threads must run
 * before that wait can finish. */
void kettlecorn_scheduler_wait(void) {
    sched_yield();
}

_Noreturn void kettlecorn_wait_for_halt(const volatile int *exit_code) {
    while (*exit_code == INT_MIN) usleep(100000);
    exit(*exit_code);
}
