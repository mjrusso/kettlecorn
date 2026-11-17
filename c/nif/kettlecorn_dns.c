/*
 * Name lookup for the guest (wasm:getaddrinfo/2): getaddrinfo over wasi:sockets, in
 * place of OTP's inet_gethost helper program, which WASI can't run.
 */
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>

#include "kettlecorn_nif.h"

static ERL_NIF_TERM error(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, reason));
}


ERL_NIF_TERM kettlecorn_getaddrinfo_nif(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
  ErlNifBinary name;
  char host[256];
  struct addrinfo hints, *res = NULL, *ai;
  ERL_NIF_TERM list;
  int family, rc;

  if (argc != 2 || !enif_inspect_binary(env, argv[0], &name)) {
    return enif_make_badarg(env);
  }
  /* Invalid host strings return lookup errors, as inet_gethost does. */
  if (name.size == 0 || name.size >= sizeof(host) ||
      memchr(name.data, '\0', name.size) != NULL) {
    return error(env, "einval");
  }
  if (enif_is_identical(argv[1], enif_make_atom(env, "inet"))) {
    family = AF_INET;
  } else if (enif_is_identical(argv[1], enif_make_atom(env, "inet6"))) {
    family = AF_INET6;
  } else {
    return enif_make_badarg(env);
  }
  memcpy(host, name.data, name.size);
  host[name.size] = '\0';

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = family;
  hints.ai_socktype = SOCK_STREAM;
  rc = getaddrinfo(host, NULL, &hints, &res);
  if (rc != 0) {
    const char *reason = rc == EAI_NONAME ? "nxdomain"
                       : rc == EAI_AGAIN  ? "timeout"
                       : rc == EAI_SYSTEM && errno == EACCES ? "eacces"
                       : "einval";
    return error(env, reason);
  }

  list = enif_make_list(env, 0);
  for (ai = res; ai != NULL; ai = ai->ai_next) {
    ERL_NIF_TERM addr;
    if (ai->ai_family == AF_INET && family == AF_INET) {
      const unsigned char *b =
          (const unsigned char *)&((struct sockaddr_in *)ai->ai_addr)->sin_addr;
      addr = enif_make_tuple4(env, enif_make_int(env, b[0]), enif_make_int(env, b[1]),
                              enif_make_int(env, b[2]), enif_make_int(env, b[3]));
    } else if (ai->ai_family == AF_INET6 && family == AF_INET6) {
      const unsigned char *b =
          ((struct sockaddr_in6 *)ai->ai_addr)->sin6_addr.s6_addr;
      ERL_NIF_TERM w[8];
      for (int i = 0; i < 8; i++) w[i] = enif_make_int(env, (b[2 * i] << 8) | b[2 * i + 1]);
      addr = enif_make_tuple_from_array(env, w, 8);
    } else {
      continue;
    }
    {
      ERL_NIF_TERM rest = list, head, found = 0;
      while (enif_get_list_cell(env, rest, &head, &rest))
        if (enif_is_identical(head, addr)) { found = 1; break; }
      if (!found) list = enif_make_list_cell(env, addr, list);
    }
  }
  freeaddrinfo(res);
  enif_make_reverse_list(env, list, &list);
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), list);
}
