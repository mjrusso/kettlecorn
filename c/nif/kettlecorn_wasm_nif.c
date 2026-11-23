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

#include "kettlecorn_nif.h"

static ERL_NIF_TERM send_raw_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary message;
  if (argc != 1 || !enif_inspect_iolist_as_binary(env, argv[0], &message))
    return enif_make_badarg(env);
#ifdef __wasi__
  return kettlecorn_send_message(env, message.data, message.size);
#else
  return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "unsupported"));
#endif
}

static ErlNifFunc nif_funcs[] = {
  {"send_raw", 1, send_raw_nif},
#ifdef __wasi__
  {"getaddrinfo", 2, kettlecorn_getaddrinfo_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"http_available", 0, kettlecorn_http_available_nif, 0},
  {"http_send", 8, kettlecorn_http_send_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"http_read", 2, kettlecorn_http_read_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"http_close", 1, kettlecorn_http_close_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"reduction_budget", 1, kettlecorn_budget_new_nif, 0},
  {"attach_reduction_budget", 1, kettlecorn_budget_attach_nif, 0},
  {"close_reduction_budget", 1, kettlecorn_budget_close_nif, 0},
#endif
};

#ifdef __wasi__
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)priv_data;
  (void)load_info;
  if (!kettlecorn_http_nif_load(env, ERL_NIF_RT_CREATE)) return -1;
  if (!kettlecorn_budget_nif_load(env, ERL_NIF_RT_CREATE)) return -1;
  kettlecorn_bridge_start();
  return 0;
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data,
                   ERL_NIF_TERM load_info) {
  (void)priv_data;
  (void)old_priv_data;
  (void)load_info;
  return kettlecorn_http_nif_load(env, ERL_NIF_RT_TAKEOVER) &&
                 kettlecorn_budget_nif_load(env, ERL_NIF_RT_TAKEOVER)
             ? 0
             : -1;
}

ERL_NIF_INIT(wasm, nif_funcs, load, NULL, upgrade, NULL)
#else
ERL_NIF_INIT(wasm, nif_funcs, NULL, NULL, NULL, NULL)
#endif
