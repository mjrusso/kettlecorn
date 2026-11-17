/* wasm32-wasip3: wasi-libc has sockets (over wasi:sockets) but no ancillary
 * data, so struct cmsghdr, CMSG_* and sendmsg/recvmsg are missing. OTP's
 * inet driver uses them for UDP; src/sockets.c implements sendmsg/recvmsg on
 * top of sendto/recvfrom without ancillary data (recvmsg sets msg_controllen
 * to 0). */
#ifndef KETTLECORN_SYS_SOCKET_COMPAT_H
#define KETTLECORN_SYS_SOCKET_COMPAT_H
#if defined(__wasi__) && !defined(__ASSEMBLER__)
#include <sys/socket.h>

#ifndef CMSG_DATA
struct cmsghdr {
    socklen_t cmsg_len;
    int cmsg_level;
    int cmsg_type;
};
#define __KETTLECORN_CMSG_ALIGN(len) (((len) + sizeof(size_t) - 1) & (size_t) ~(sizeof(size_t) - 1))
#define CMSG_ALIGN(len) __KETTLECORN_CMSG_ALIGN(len)
#define CMSG_DATA(cmsg) ((unsigned char *) (((struct cmsghdr *)(cmsg)) + 1))
#define CMSG_SPACE(len) (CMSG_ALIGN(len) + CMSG_ALIGN(sizeof(struct cmsghdr)))
#define CMSG_LEN(len) (CMSG_ALIGN(sizeof(struct cmsghdr)) + (len))
#define CMSG_FIRSTHDR(mhdr) ((size_t) (mhdr)->msg_controllen >= sizeof(struct cmsghdr) ? \
    (struct cmsghdr *) (mhdr)->msg_control : (struct cmsghdr *) 0)
#define CMSG_NXTHDR(mhdr, cmsg) ((struct cmsghdr *) 0)
#define SCM_RIGHTS 0x01
#endif

/* Options WASI doesn't implement; setsockopt() fails with ENOPROTOOPT. */
#ifndef SO_DONTROUTE
#define SO_DONTROUTE 5
#endif
#ifndef SO_BROADCAST
#define SO_BROADCAST 6
#endif
#ifndef SO_OOBINLINE
#define SO_OOBINLINE 10
#endif
#ifndef SO_LINGER
#define SO_LINGER 13

#endif

ssize_t sendmsg(int, const struct msghdr *, int);
ssize_t recvmsg(int, struct msghdr *, int);
#endif
#endif
