/*
 * Stdio framing (see PROTOCOL.md).
 *
 * In framed mode (KETTLECORN_FRAMED=1 in the environment) everything the
 * guest writes to fd 1 and fd 2 is wrapped into protocol frames, so that the
 * host can tell console output apart from bridge messages. The linker
 * routes writes here with --wrap=write and --wrap=writev.
 */
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

#include "kettlecorn.h"

static pthread_mutex_t frame_lock = PTHREAD_MUTEX_INITIALIZER;
static int framed_mode = -1;

/* wasi-libc's writev() calls write(), which --wrap would route back into
 * the framing lock. Write directly through the unwrapped write(). */
ssize_t __real_write(int fd, const void *buf, size_t n);
ssize_t __real_writev(int fd, const struct iovec *iov, int cnt);

int kettlecorn_framed(void) {
    if (framed_mode < 0) {
        const char *v = getenv("KETTLECORN_FRAMED");
        framed_mode = (v != NULL && v[0] == '1') ? 1 : 0;
    }
    return framed_mode;
}

uint32_t kettlecorn_read_u32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int raw_write_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n > 0) {
        ssize_t w = __real_write(fd, p, n);
        if (w == 0) { errno = EIO; return -1; }
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) {
                /* ERTS may have made fd 1 non-blocking. Wait until it's
                 * writable; with cooperative threads a busy retry
                 * would never let the pending write complete. */
                struct pollfd p = {fd, POLLOUT, 0};
                poll(&p, 1, 10);
                continue;
            }
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

/* Writes one frame whose payload is the concatenation of iov[0..cnt). */
static int frame_writev(int type, const struct iovec *iov, int cnt, size_t size) {
    unsigned char hdr[5];
    uint32_t len = (uint32_t)size + 1;
    int rc;
    hdr[0] = len >> 24; hdr[1] = len >> 16; hdr[2] = len >> 8; hdr[3] = len;
    hdr[4] = (unsigned char)type;
    pthread_mutex_lock(&frame_lock);
    rc = raw_write_all(1, hdr, 5);
    for (int i = 0; rc == 0 && i < cnt; i++)
        if (iov[i].iov_len > 0) rc = raw_write_all(1, iov[i].iov_base, iov[i].iov_len);
    pthread_mutex_unlock(&frame_lock);
    return rc;
}

int kettlecorn_frame_write(int type, const void *data, size_t size) {
    struct iovec iov = {(void *)data, size};
    if (!kettlecorn_framed()) return 0;
    if (size >= UINT32_MAX) { errno = EMSGSIZE; return -1; }
    return frame_writev(type, &iov, 1, size);
}

_Noreturn void kettlecorn_fatal(const char *reason) {
    size_t size = strlen(reason);
    if (kettlecorn_framed()) {
        kettlecorn_frame_write(KETTLECORN_FRAME_FATAL, reason, size);
    } else {
        pthread_mutex_lock(&frame_lock);
        raw_write_all(2, reason, size);
        if (size == 0 || reason[size - 1] != '\n') raw_write_all(2, "\n", 1);
        pthread_mutex_unlock(&frame_lock);
    }
    exit(1);
}

/* 1: complete; 0: EOF before any bytes; -1: read error; -2: partial EOF. */
static int read_full(int fd, unsigned char *buf, size_t size) {
    size_t remaining = size;
    while (remaining > 0) {
        ssize_t n = read(fd, buf, remaining);
        if (n == 0) return remaining == size ? 0 : -2;
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) {
                struct pollfd input = {fd, POLLIN, 0};
                poll(&input, 1, 10);
                continue;
            }
            return -1;
        }
        buf += n;
        remaining -= (size_t)n;
    }
    return 1;
}

int kettlecorn_frame_read(int fd, unsigned char **body, size_t *size, const char **error) {
    unsigned char header[4];
    int got = read_full(fd, header, sizeof(header));
    *body = NULL;
    *size = 0;
    if (got == 0) return 0;
    if (got < 0) {
        *error = got == -1 ? "kettlecorn: reading stdin failed"
                          : "kettlecorn: truncated frame from the host";
        return -1;
    }
    uint32_t len = kettlecorn_read_u32(header);
    if (len == 0 || len > KETTLECORN_MAX_IN_FRAME) {
        *error = "kettlecorn: invalid frame length from the host";
        return -1;
    }
    unsigned char *data = malloc(len);
    if (data == NULL) {
        *error = "kettlecorn: out of memory reading a frame";
        return -1;
    }
    got = read_full(fd, data, len);
    if (got != 1) {
        free(data);
        *error = got == -1 ? "kettlecorn: reading stdin failed"
                          : "kettlecorn: truncated frame from the host";
        return -1;
    }
    *body = data;
    *size = len;
    return 1;
}

static ssize_t framed_writev(int fd, const struct iovec *iov, int cnt) {
    size_t total = 0;
    for (int i = 0; i < cnt; i++) {
        if (iov[i].iov_len >= UINT32_MAX - total) { errno = EMSGSIZE; return -1; }
        total += iov[i].iov_len;
    }
    if (total == 0) return 0;
    int type = fd == 1 ? KETTLECORN_FRAME_STDOUT : KETTLECORN_FRAME_STDERR;
    return frame_writev(type, iov, cnt, total) < 0 ? -1 : (ssize_t)total;
}

ssize_t __wrap_writev(int fd, const struct iovec *iov, int cnt) {
    if ((fd == 1 || fd == 2) && kettlecorn_framed())
        return framed_writev(fd, iov, cnt);
    return __real_writev(fd, iov, cnt);
}

ssize_t __wrap_write(int fd, const void *buf, size_t n) {
    if ((fd == 1 || fd == 2) && kettlecorn_framed()) {
        struct iovec iov = {(void *)buf, n};
        return framed_writev(fd, &iov, 1);
    }
    return __real_write(fd, buf, n);
}
