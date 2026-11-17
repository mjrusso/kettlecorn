/*
 * sendmsg()/recvmsg() for wasm32-wasip3 on top of sendto()/recvfrom().
 * WASI sockets carry no ancillary data, so msg_control is ignored on send and
 * msg_controllen is set to 0 on receive. Scatter/gather goes through a
 * temporary buffer.
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include "sys_socket_compat.h"

static size_t iov_total(const struct iovec *iov, int n) {
    size_t t = 0;
    for (int i = 0; i < n; i++) t += iov[i].iov_len;
    return t;
}

ssize_t sendmsg(int fd, const struct msghdr *m, int flags) {
    size_t total = iov_total(m->msg_iov, m->msg_iovlen);
    if (m->msg_iovlen == 1)
        return sendto(fd, m->msg_iov[0].iov_base, total, flags,
                      m->msg_name, m->msg_namelen);
    unsigned char *buf = malloc(total ? total : 1);
    if (!buf) { errno = ENOMEM; return -1; }
    size_t off = 0;
    for (int i = 0; i < m->msg_iovlen; i++) {
        memcpy(buf + off, m->msg_iov[i].iov_base, m->msg_iov[i].iov_len);
        off += m->msg_iov[i].iov_len;
    }
    ssize_t r = sendto(fd, buf, total, flags, m->msg_name, m->msg_namelen);
    free(buf);
    return r;
}

ssize_t recvmsg(int fd, struct msghdr *m, int flags) {
    size_t total = iov_total(m->msg_iov, m->msg_iovlen);
    socklen_t namelen = m->msg_namelen;
    ssize_t r;
    m->msg_controllen = 0;
    m->msg_flags = 0;
    if (m->msg_iovlen == 1) {
        r = recvfrom(fd, m->msg_iov[0].iov_base, total, flags,
                     m->msg_name, m->msg_name ? &namelen : NULL);
    } else {
        unsigned char *buf = malloc(total ? total : 1);
        if (!buf) { errno = ENOMEM; return -1; }
        r = recvfrom(fd, buf, total, flags, m->msg_name, m->msg_name ? &namelen : NULL);
        if (r > 0) {
            size_t off = 0;
            for (int i = 0; i < m->msg_iovlen && off < (size_t)r; i++) {
                size_t n = m->msg_iov[i].iov_len;
                if (n > (size_t)r - off) n = (size_t)r - off;
                memcpy(m->msg_iov[i].iov_base, buf + off, n);
                off += n;
            }
        }
        free(buf);
    }
    if (r >= 0 && m->msg_name) m->msg_namelen = namelen;
    return r;
}
