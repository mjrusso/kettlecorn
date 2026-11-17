%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2026. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
-module(wasm).
-moduledoc false.

%% on_load/0 is called explicitly from erl_init:start/2; do NOT use the
%% -on_load attribute (a preloaded module with one aborts the VM at boot).
-export([getaddrinfo/2, http_available/0, http_send/8, http_read/2, http_close/1]).
-export([on_load/0, send/1, host_call/3]).
%% Sends an envelope as is, already encoded: the guest's own events to the
%% host (Kettlecorn.Event), apart from send/1's vm_message ones.
-export([send_raw/1]).

-nifs([send_raw/1, getaddrinfo/2,
        http_available/0, http_send/8, http_read/2, http_close/1]).

-define(HOST_CALL_TIMEOUT, 5000).

-spec send(term()) -> ok.
send(Message) ->
    Envelope = #{type => vm_message, data => Message},
    ok = send_raw(term_to_binary(Envelope)).

-spec host_call(binary(), map(), proplists:proplist()) -> {ok, term()} | {error, term()}.
host_call(Name, Args, Opts) when is_binary(Name), is_map(Args), is_list(Opts) ->
    Timeout = proplists:get_value(timeout, Opts, ?HOST_CALL_TIMEOUT),
    Token = erlang:unique_integer(),
    ReplyTo = term_to_binary({self(), Token}),
    Envelope = #{type => host_call, name => Name, args => Args,
                 reply_to => ReplyTo},
    ok = send_raw(term_to_binary(Envelope)),
    receive
        {wasm, {Token, Payload}} -> Payload
    after Timeout ->
        {error, timeout}
    end.

-spec on_load() -> ok.
on_load() ->
    ok = erlang:load_nif("wasm", wasm).

send_raw(_Message) ->
    erlang:nif_error(undef).

-spec getaddrinfo(binary(), inet | inet6) -> {ok, [inet:ip_address()]} | {error, atom()}.
getaddrinfo(_Name, _Family) ->
    erlang:nif_error(undef).

%% WASI only: HTTP over wasi:http/client, available when the emulator was
%% linked with it (beam-http.wasm, selected by the HTTP grant).
-spec http_available() -> boolean().
http_available() ->
    erlang:nif_error(undef).

%% default selects 30s to connect and 15s to receive. Finite values are ms,
%% including zero; infinity returns {error, unsupported_timeout}.
%% ReadTimeoutMs bounds the response head and each part of the body.
-spec http_send(binary(), http | https, binary(), binary(), [{binary(), binary()}],
                binary() | nil, default | non_neg_integer() | infinity,
                default | non_neg_integer() | infinity) ->
          {ok, reference(), non_neg_integer(), [{binary(), binary()}]} | {error, atom()}.
http_send(_Method, _Scheme, _Authority, _Path, _Headers, _Body, _ConnectMs, _ReadMs) ->
    erlang:nif_error(undef).

-spec http_read(reference(), pos_integer()) -> {ok, binary()} | eof | {error, atom()}.
http_read(_Ref, _Max) ->
    erlang:nif_error(undef).

-spec http_close(reference()) -> ok | {error, atom()}.
http_close(_Ref) ->
    erlang:nif_error(undef).
