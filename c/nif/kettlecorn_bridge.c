/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2026. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "kettlecorn.h"
#include "kettlecorn_nif.h"

ERL_NIF_TERM kettlecorn_send_message(ErlNifEnv *env, const unsigned char *data, size_t size) {
  if (kettlecorn_frame_write(KETTLECORN_FRAME_MESSAGE, data, size) != 0) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "closed"));
  }
  return enif_make_atom(env, "ok");
}

void js_bridge_on_error(const char *data, int len) {
  kettlecorn_frame_write(KETTLECORN_FRAME_FATAL, data, (size_t)len);
}

static bool decode_pid_target(ErlNifEnv *env, const char *name, size_t name_len,
                              ErlNifPid *pid, bool *has_token, ERL_NIF_TERM *token) {
  ERL_NIF_TERM target;
  int arity;
  const ERL_NIF_TERM *elems;

  *has_token = false;
  if (enif_binary_to_term(env, (const unsigned char *)name, name_len,
                          &target, ERL_NIF_BIN2TERM_SAFE) == 0) return false;
  if (enif_get_local_pid(env, target, pid)) return true;
  if (enif_get_tuple(env, target, &arity, &elems) && arity == 2 &&
      enif_get_local_pid(env, elems[0], pid)) {
    *has_token = true;
    *token = elems[1];
    return true;
  }
  return false;
}

static int send_vm_message(uint32_t id, int target_kind, const char *name, size_t name_len,
                           const unsigned char *etf, size_t etf_len) {
  ErlNifEnv *env = enif_alloc_env();
  ErlNifPid pid;
  ERL_NIF_TERM payload, token, atom;
  bool has_token = false;
  int status = KETTLECORN_SEND_BAD_TARGET;
  if (env == NULL) kettlecorn_fatal("kettlecorn: out of memory delivering a message");

  if (enif_binary_to_term(env, etf, etf_len, &payload,
                          ERL_NIF_BIN2TERM_SAFE) != etf_len) {
    status = KETTLECORN_SEND_BAD_TERM;
  } else if (target_kind == KETTLECORN_TARGET_PID) {
    status = decode_pid_target(env, name, name_len, &pid, &has_token, &token)
               ? KETTLECORN_SEND_DELIVERED : KETTLECORN_SEND_NO_PROCESS;
  } else if (target_kind == KETTLECORN_TARGET_NAME || target_kind == KETTLECORN_TARGET_PROXY) {
    status = enif_make_existing_atom_len(env, name, name_len, &atom, ERL_NIF_UTF8) &&
             enif_whereis_pid(env, atom, &pid)
               ? KETTLECORN_SEND_DELIVERED : KETTLECORN_SEND_NO_PROCESS;
  }

  if (status == KETTLECORN_SEND_DELIVERED) {
    ERL_NIF_TERM body = has_token ? enif_make_tuple2(env, token, payload) : payload;
    if (target_kind == KETTLECORN_TARGET_PROXY)
      body = enif_make_tuple2(env, enif_make_uint(env, id), payload);
    ERL_NIF_TERM message = enif_make_tuple2(env, enif_make_atom(env, "wasm"), body);
    if (!enif_send(NULL, &pid, env, message)) status = KETTLECORN_SEND_NO_PROCESS;
  }
  enif_free_env(env);
  return status;
}

/* The queue is unbounded so unread stdin cannot block other host frames. */
typedef struct stdin_chunk {
  struct stdin_chunk *next;
  size_t size;
  size_t offset;
  unsigned char data[];
} stdin_chunk;

/* Input can arrive before prim_tty loads. A pthread mutex has a static
 * initializer; unlike ErlNifMutex it needs no NIF load-time setup. Contention
 * yields on wasi-libc's cooperative threads. */
static pthread_mutex_t stdin_lock = PTHREAD_MUTEX_INITIALIZER;
static stdin_chunk *stdin_head, *stdin_tail;
static int stdin_eof;

static struct {
  void *owner;
  ErlNifEnv *env;
  ERL_NIF_TERM ref;
  ErlNifPid pid;
  int notified;
} stdin_reader;

static void notify_stdin_locked(void) {
  ErlNifEnv *env;
  ERL_NIF_TERM message;
  if (stdin_reader.owner == NULL || stdin_reader.notified ||
      (stdin_head == NULL && !stdin_eof)) return;
  env = enif_alloc_env();
  if (env == NULL) kettlecorn_fatal("kettlecorn: out of memory notifying stdin reader");
  message = enif_make_tuple4(
      env, enif_make_atom(env, "select"), enif_make_resource(env, stdin_reader.owner),
      enif_make_copy(env, stdin_reader.ref), enif_make_atom(env, "ready_input"));
  enif_send(NULL, &stdin_reader.pid, env, message);
  enif_free_env(env);
  stdin_reader.notified = 1;
}

/* Release registration references outside stdin_lock: the TTY destructor
 * calls back into deselect. */
void kettlecorn_stdin_select(ErlNifEnv *env, void *owner, ERL_NIF_TERM ref) {
  void *previous;
  enif_keep_resource(owner);
  pthread_mutex_lock(&stdin_lock);
  previous = stdin_reader.owner;
  if (stdin_reader.env == NULL) {
    stdin_reader.env = enif_alloc_env();
    if (stdin_reader.env == NULL)
      kettlecorn_fatal("kettlecorn: out of memory registering stdin reader");
  }
  enif_clear_env(stdin_reader.env);
  stdin_reader.ref = enif_make_copy(stdin_reader.env, ref);
  enif_self(env, &stdin_reader.pid);
  stdin_reader.owner = owner;
  /* An outstanding notification to the previous reader cannot wake this one. */
  stdin_reader.notified = 0;
  notify_stdin_locked();
  pthread_mutex_unlock(&stdin_lock);
  if (previous != NULL) enif_release_resource(previous);
}

void kettlecorn_stdin_deselect(void *owner, const ErlNifPid *pid) {
  void *previous = NULL;
  pthread_mutex_lock(&stdin_lock);
  if (stdin_reader.owner == owner &&
      (pid == NULL || enif_compare_pids(pid, &stdin_reader.pid) == 0)) {
    previous = stdin_reader.owner;
    stdin_reader.owner = NULL;
    stdin_reader.notified = 0;
    enif_free_env(stdin_reader.env);
    stdin_reader.env = NULL;
  }
  pthread_mutex_unlock(&stdin_lock);
  if (previous != NULL) enif_release_resource(previous);
}

static size_t read_stdin_bytes(unsigned char *buf, size_t n, int *eof) {
  size_t consumed = 0;
  pthread_mutex_lock(&stdin_lock);
  stdin_reader.notified = 0;
  while (consumed < n && stdin_head != NULL) {
    stdin_chunk *c = stdin_head;
    size_t size = c->size - c->offset;
    if (size > n - consumed) size = n - consumed;
    memcpy(buf + consumed, c->data + c->offset, size);
    consumed += size;
    c->offset += size;
    if (c->offset == c->size) {
      stdin_head = c->next;
      if (stdin_head == NULL) stdin_tail = NULL;
      free(c);
    }
  }
  *eof = stdin_head == NULL && stdin_eof;
  if (consumed > 0) notify_stdin_locked();
  pthread_mutex_unlock(&stdin_lock);
  return consumed;
}

ERL_NIF_TERM kettlecorn_stdin_read(ErlNifEnv *env, size_t n) {
  ErlNifBinary bin;
  ERL_NIF_TERM data;
  size_t size;
  int eof;
  if (!enif_alloc_binary(n, &bin))
    return enif_raise_exception(env, enif_make_atom(env, "out_of_memory"));
  size = read_stdin_bytes(bin.data, n, &eof);
  if (size == 0) {
    enif_release_binary(&bin);
    if (eof)
      return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "closed"));
    enif_make_new_binary(env, 0, &data);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), data);
  }
  if (size != n && !enif_realloc_binary(&bin, size)) {
    enif_release_binary(&bin);
    return enif_raise_exception(env, enif_make_atom(env, "out_of_memory"));
  }
  data = enif_make_binary(env, &bin);
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), data);
}

/* Queues data (size 0: end of input). 0 when out of memory. */
static int queue_stdin(const unsigned char *data, size_t size) {
  stdin_chunk *c = NULL;
  if (size > 0) {
    c = malloc(sizeof(*c) + size);
    if (c == NULL) return 0;
    c->next = NULL;
    c->size = size;
    c->offset = 0;
    memcpy(c->data, data, size);
  }
  pthread_mutex_lock(&stdin_lock);
  if (stdin_eof) {
    free(c);
  } else if (c != NULL) {
    if (stdin_tail) stdin_tail->next = c; else stdin_head = c;
    stdin_tail = c;
  } else {
    stdin_eof = 1;
  }
  notify_stdin_locked();
  pthread_mutex_unlock(&stdin_lock);
  return 1;
}

/* SEND payload: id:u32 kind:u8 name_len:u32 name etf */
static void handle_send(const unsigned char *p, size_t n) {
  unsigned char reply[5];
  int status = KETTLECORN_SEND_MALFORMED;
  if (n >= 9) {
    uint32_t name_len = kettlecorn_read_u32(p + 5);
    /* name_len < n - 9, not name_len + 9 < n: size_t is 32-bit here. */
    if (name_len > 0 && name_len < n - 9) {
      status = send_vm_message(kettlecorn_read_u32(p), p[4], (const char *)p + 9, name_len,
                               p + 9 + name_len, n - 9 - name_len);
    }
  }
  if (n >= 4) {
    memcpy(reply, p, 4);
    reply[4] = (unsigned char)status;
    kettlecorn_frame_write(KETTLECORN_FRAME_SEND_RESULT, reply, sizeof(reply));
  }
}

static void read_raw_stdin(void) {
  unsigned char buf[4096];
  for (;;) {
    ssize_t n = read(0, buf, sizeof(buf));
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN) {
        struct pollfd input = {0, POLLIN, 0};
        poll(&input, 1, 10);
        continue;
      }
      kettlecorn_fatal("kettlecorn: reading stdin failed");
    }
    if (n == 0) {
      queue_stdin(NULL, 0);
      return;
    }
    if (!queue_stdin(buf, (size_t)n))
      kettlecorn_fatal("kettlecorn: out of memory queueing stdin");
  }
}

static void read_host_frames(void) {
  for (;;) {
    unsigned char *body;
    size_t len;
    const char *error;
    int got = kettlecorn_frame_read(0, &body, &len, &error);
    if (got == 0) exit(0);
    if (got < 0) kettlecorn_fatal(error);
    switch (body[0]) {
    case KETTLECORN_FRAME_SEND:
      handle_send(body + 1, len - 1);
      break;
    case KETTLECORN_FRAME_STDIN:
      if (len > 1 && !queue_stdin(body + 1, len - 1))
        kettlecorn_fatal("kettlecorn: out of memory queueing stdin");
      break;
    case KETTLECORN_FRAME_STDIN_EOF:
      queue_stdin(NULL, 0);
      break;
    default:
      break;
    }
    free(body);
  }
}

static void *wasi_bridge_reader(void *arg) {
  (void)arg;
  if (kettlecorn_framed()) read_host_frames(); else read_raw_stdin();
  return NULL;
}

void kettlecorn_bridge_start(void) {
  static int started = 0;
  ErlNifTid tid;
  if (started) return;
  started = 1;
  if (enif_thread_create("kettlecorn_bridge", &tid, wasi_bridge_reader, NULL, NULL) != 0)
    kettlecorn_fatal("kettlecorn: can't start the stdio bridge");
}
