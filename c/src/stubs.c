/*
 * Inert POSIX and ERTS OS interfaces unavailable on WASI. ERTS references
 * them for signal handling and OS process management, which Popcorn disables
 * on WASI. Signals can never arrive in a WASI sandbox, so registering
 * handlers and masking always succeeds and does nothing.
 */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

_Noreturn void pthread_exit(void *ret) {
    (void)ret;
    fprintf(stderr, "kettlecorn: pthread_exit() is not supported\n");
    abort();
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old) {
    (void)how; (void)set;
    if (old) memset(old, 0, sizeof(*old));
    return 0;
}
int sigprocmask(int how, const sigset_t *set, sigset_t *old) {
    return pthread_sigmask(how, set, old);
}
int pthread_kill(pthread_t t, int sig) { (void)t; (void)sig; return ENOSYS; }
int sigwait(const sigset_t *set, int *sig) {
    (void)set; (void)sig;
    for (;;) sleep(3600); /* no signal will ever arrive */
}
int sigsuspend(const sigset_t *set) { (void)set; for (;;) sleep(3600); }
int sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    (void)sig; (void)act;
    if (old) memset(old, 0, sizeof(*old));
    return 0;
}
int sigemptyset(sigset_t *s) { memset(s, 0, sizeof(*s)); return 0; }
int sigfillset(sigset_t *s) { memset(s, 0xff, sizeof(*s)); return 0; }
int sigaddset(sigset_t *s, int n) { (void)s; (void)n; return 0; }
int sigdelset(sigset_t *s, int n) { (void)s; (void)n; return 0; }
int sigismember(const sigset_t *s, int n) { (void)s; (void)n; return 0; }
int kill(pid_t pid, int sig) {
    if (pid == getpid() || pid == 0) return raise(sig);
    errno = ESRCH;
    return -1;
}

uid_t getuid(void) { return 1000; }
uid_t geteuid(void) { return 1000; }
gid_t getgid(void) { return 1000; }
gid_t getegid(void) { return 1000; }
pid_t getppid(void) { return 1; }
pid_t getpgrp(void) { return getpid(); }
pid_t setsid(void) { errno = EPERM; return -1; }
int setpgid(pid_t a, pid_t b) { (void)a; (void)b; errno = EPERM; return -1; }
pid_t fork(void) { errno = ENOSYS; return -1; }
pid_t vfork(void) { errno = ENOSYS; return -1; }
pid_t waitpid(pid_t p, int *st, int o) { (void)p; (void)st; (void)o; errno = ECHILD; return -1; }
int execv(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
int execve(const char *p, char *const a[], char *const e[]) { (void)p; (void)a; (void)e; errno = ENOSYS; return -1; }
int execvp(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
unsigned alarm(unsigned s) { (void)s; return 0; }
mode_t umask(mode_t m) { (void)m; return 022; }

#include <pwd.h>
struct passwd *getpwuid(uid_t u) { (void)u; errno = ENOENT; return NULL; }
struct passwd *getpwnam(const char *n) { (void)n; errno = ENOENT; return NULL; }
int getpwuid_r(uid_t u, struct passwd *p, char *b, size_t l, struct passwd **r) {
    (void)u; (void)p; (void)b; (void)l; *r = NULL; return ENOENT;
}
int getpwnam_r(const char *n, struct passwd *p, char *b, size_t l, struct passwd **r) {
    (void)n; (void)p; (void)b; (void)l; *r = NULL; return ENOENT;
}

#include <termios.h>
int tcgetattr(int fd, struct termios *t) { (void)fd; memset(t, 0, sizeof(*t)); errno = ENOTTY; return -1; }
int tcsetattr(int fd, int a, const struct termios *t) { (void)fd; (void)a; (void)t; errno = ENOTTY; return -1; }

char *ttyname(int fd) { (void)fd; errno = ENOTTY; return NULL; }
int nice(int inc) { (void)inc; return 0; }
int socketpair(int d, int t, int p, int sv[2]) { (void)d; (void)t; (void)p; (void)sv; errno = ENOSYS; return -1; }

/* sys_drivers.o references OTP's sys_uds.h API even with the forker disabled. */
int sys_uds_readv(int fd, struct iovec *iov, size_t iov_len,
                  int *fds, int fd_count, int flags) {
    (void)fd; (void)iov; (void)iov_len; (void)fds; (void)fd_count; (void)flags;
    errno = ENOSYS; return -1;
}
int sys_uds_read(int fd, char *buff, size_t len,
                 int *fds, int fd_count, int flags) {
    (void)fd; (void)buff; (void)len; (void)fds; (void)fd_count; (void)flags;
    errno = ENOSYS; return -1;
}
int sys_uds_writev(int fd, struct iovec *iov, size_t iov_len,
                   int *fds, int fd_count, int flags) {
    (void)fd; (void)iov; (void)iov_len; (void)fds; (void)fd_count; (void)flags;
    errno = ENOSYS; return -1;
}
int sys_uds_write(int fd, char *buff, size_t len,
                  int *fds, int fd_count, int flags) {
    (void)fd; (void)buff; (void)len; (void)fds; (void)fd_count; (void)flags;
    errno = ENOSYS; return -1;
}

/* WASI has no file ownership or permission bits. */
int chown(const char *p, uid_t u, gid_t g) { (void)p; (void)u; (void)g; errno = ENOTSUP; return -1; }
int fchown(int f, uid_t u, gid_t g) { (void)f; (void)u; (void)g; errno = ENOTSUP; return -1; }
int lchown(const char *p, uid_t u, gid_t g) { (void)p; (void)u; (void)g; errno = ENOTSUP; return -1; }

#include <pthread.h>
/* All threads are system-scope. */
int pthread_attr_setscope(pthread_attr_t *a, int scope) { (void)a; (void)scope; return 0; }

/* WASI has no time zone database; local time is UTC. */
void tzset(void) {}

#include <net/if.h>
unsigned int if_nametoindex(const char *n) { (void)n; errno = ENXIO; return 0; }
char *if_indextoname(unsigned int i, char *b) { (void)i; (void)b; errno = ENXIO; return NULL; }
struct if_nameindex *if_nameindex(void) { errno = ENOSYS; return NULL; }
void if_freenameindex(struct if_nameindex *p) { (void)p; }
