/*
 * Force-included (-include) into every C file of the WASI build of OTP.
 *
 * ERTS references POSIX APIs missing from wasi-libc in code paths disabled
 * by Popcorn: thread signals, processes, users, and resource limits.
 * This header declares them; src/stubs.c supplies the stubs.
 */
#ifndef KETTLECORN_COMPAT_H
#define KETTLECORN_COMPAT_H

#if defined(__wasi__) && !defined(__ASSEMBLER__)
#include <sys/types.h>
#include <signal.h>
#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Types wasi-libc's <signal.h> hides because WASI has no sigaction. */
#ifndef KETTLECORN_SIGINFO
#define KETTLECORN_SIGINFO
typedef struct {
    int si_signo, si_errno, si_code;
    pid_t si_pid;
    uid_t si_uid;
    void *si_addr;
    int si_status;
    union sigval { int sival_int; void *sival_ptr; } si_value;
} siginfo_t;

struct sigaction {
    union {
        void (*sa_handler)(int);
        void (*sa_sigaction)(int, siginfo_t *, void *);
    } __sa_handler;
    sigset_t sa_mask;
    int sa_flags;
    void (*sa_restorer)(void);
};
#define sa_handler   __sa_handler.sa_handler
#define sa_sigaction __sa_handler.sa_sigaction

typedef struct { void *ss_sp; int ss_flags; size_t ss_size; } stack_t;
#endif

_Noreturn void pthread_exit(void *);
int pthread_sigmask(int, const sigset_t *, sigset_t *);
int pthread_kill(pthread_t, int);
int pthread_attr_setscope(pthread_attr_t *, int);
#ifndef PTHREAD_SCOPE_SYSTEM
#define PTHREAD_SCOPE_SYSTEM 0
#define PTHREAD_SCOPE_PROCESS 1
#endif
int sigwait(const sigset_t *, int *);
int sigaction(int, const struct sigaction *, struct sigaction *);
int sigprocmask(int, const sigset_t *, sigset_t *);
int sigemptyset(sigset_t *);
int sigfillset(sigset_t *);
int sigaddset(sigset_t *, int);
int sigdelset(sigset_t *, int);
int sigismember(const sigset_t *, int);
int sigsuspend(const sigset_t *);
int kill(pid_t, int);

uid_t getuid(void);
uid_t geteuid(void);
gid_t getgid(void);
gid_t getegid(void);
pid_t getppid(void);
pid_t getpgrp(void);
pid_t setsid(void);
int setpgid(pid_t, pid_t);
pid_t fork(void);
pid_t vfork(void);
int execv(const char *, char *const[]);
int execve(const char *, char *const[], char *const[]);
int execvp(const char *, char *const[]);
unsigned alarm(unsigned);
mode_t umask(mode_t);
char *ttyname(int);
int nice(int);
void tzset(void);
int chown(const char *, uid_t, gid_t);
int fchown(int, uid_t, gid_t);
int lchown(const char *, uid_t, gid_t);
int socketpair(int, int, int, int[2]);

#ifndef SA_RESTART
#define SA_RESTART 0x10000000
#endif
#ifndef SA_NOCLDSTOP
#define SA_NOCLDSTOP 1
#endif
#ifndef SA_SIGINFO
#define SA_SIGINFO 4
#endif
#ifndef SA_ONSTACK
#define SA_ONSTACK 0x08000000
#endif
#ifndef SIG_BLOCK
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2
#endif

#ifdef __cplusplus
}
#endif
#include "sys_socket_compat.h"
#endif /* __wasi__ */
#endif
