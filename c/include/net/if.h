/* Minimal <net/if.h>: WASI has no network interface enumeration. */
#ifndef KETTLECORN_NET_IF_H
#define KETTLECORN_NET_IF_H
#include <sys/socket.h>
#define IFNAMSIZ 16
#define IF_NAMESIZE IFNAMSIZ
#define IFF_UP 0x1
#define IFF_BROADCAST 0x2
#define IFF_LOOPBACK 0x8
#define IFF_POINTOPOINT 0x10
#define IFF_RUNNING 0x40
#define IFF_MULTICAST 0x1000
struct if_nameindex { unsigned int if_index; char *if_name; };
unsigned int if_nametoindex(const char *);
char *if_indextoname(unsigned int, char *);
struct if_nameindex *if_nameindex(void);
void if_freenameindex(struct if_nameindex *);
#endif
