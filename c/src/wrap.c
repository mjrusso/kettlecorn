/* Linked with --wrap=gethostname (nix/toolchain.nix). */
#include <errno.h>
#include <string.h>
#include <unistd.h>

/* The guest mustn't learn the host's name. Keep this in sync with
 * inet:gethostname/0 in patches/otp/0104-sockets-dns.patch. */
int __wrap_gethostname(char *name, size_t len) {
    static const char fixed[] = "localhost";
    if (len < sizeof(fixed)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(name, fixed, sizeof(fixed));
    return 0;
}
