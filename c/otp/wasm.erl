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
-export([send_raw/1, send_envelope/1]).

-nifs([send_raw/1, getaddrinfo/2,
        http_available/0, http_send/8, http_read/2, http_close/1]).

-define(HOST_CALL_TIMEOUT, 5000).

-spec send(term()) -> ok | {error, frame_too_large}.
send(Message) ->
    send_envelope(#{type => vm_message, data => Message}).

-spec host_call(binary(), map(), proplists:proplist()) -> {ok, term()} | {error, term()}.
host_call(Name, Args, Opts) when is_binary(Name), is_map(Args), is_list(Opts) ->
    Timeout = proplists:get_value(timeout, Opts, ?HOST_CALL_TIMEOUT),
    Token = erlang:unique_integer(),
    ReplyTo = term_to_binary({self(), Token}),
    Envelope = #{type => host_call, name => Name, args => Args,
                 reply_to => ReplyTo},
    case send_envelope(Envelope) of
        ok ->
            receive
                {wasm, {Token, Payload}} -> Payload
            after Timeout ->
                {error, timeout}
            end;
        {error, frame_too_large} = Error -> Error
    end.

-spec send_envelope(map()) -> ok | {error, frame_too_large}.
send_envelope(Envelope) ->
    case guest_frame_limit() of
        infinity -> send_raw(term_to_binary(Envelope));
        Limit ->
            %% external_size is an upper bound. The frame also needs a type byte.
            try frame_budget([Envelope], Limit - 1) of
                Remaining when Remaining >= 0 -> send_raw(term_to_binary(Envelope));
                _ -> {error, frame_too_large}
            catch
                error:system_limit -> {error, frame_too_large}
            end
    end.

%% Charge each scalar's version byte too, so the estimate stays conservative.
%% Subtract per node to avoid external_size's 32-bit aggregate overflow.
frame_budget(_, Remaining) when Remaining < 0 -> Remaining;
frame_budget([], Remaining) -> Remaining;
frame_budget([Term | Rest], Remaining) when is_binary(Term) ->
    frame_budget(Rest, Remaining - 6 - byte_size(Term));
frame_budget([Term | Rest], Remaining) when is_integer(Term), Term >= 0, Term =< 255 ->
    frame_budget(Rest, Remaining - 3);
frame_budget([Term | Rest], Remaining)
  when is_integer(Term), Term >= -2147483648, Term =< 2147483647 ->
    frame_budget(Rest, Remaining - 6);
frame_budget([Term | Rest], Remaining) when is_float(Term) ->
    frame_budget(Rest, Remaining - 10);
frame_budget([[] | Rest], Remaining) ->
    frame_budget(Rest, Remaining - 2);
frame_budget([Term | Rest], Remaining) when is_tuple(Term) ->
    frame_tuple_budget(Term, 1, Rest, Remaining - 5);
frame_budget([Term | Rest], Remaining) when is_map(Term) ->
    frame_map_budget(maps:iterator(Term), Rest, Remaining - 5);
frame_budget([[Head | Tail] | Rest], Remaining) ->
    frame_budget([Head, Tail | Rest], Remaining - 5);
frame_budget([Term | _], _) when is_function(Term); is_record(Term) -> -1;
frame_budget([Term | Rest], Remaining) ->
    frame_budget(Rest, Remaining - erlang:external_size(Term)).

frame_tuple_budget(_, _, _, Remaining) when Remaining < 0 -> Remaining;
frame_tuple_budget(Term, Index, Rest, Remaining) when Index > tuple_size(Term) ->
    frame_budget(Rest, Remaining);
frame_tuple_budget(Term, Index, Rest, Remaining) ->
    Budget = frame_budget([element(Index, Term)], Remaining),
    frame_tuple_budget(Term, Index + 1, Rest, Budget).

frame_map_budget(_, _, Remaining) when Remaining < 0 -> Remaining;
frame_map_budget(Iterator, Rest, Remaining) ->
    case maps:next(Iterator) of
        none -> frame_budget(Rest, Remaining);
        {Key, Value, Next} ->
            Budget = frame_budget([Key, Value], Remaining),
            frame_map_budget(Next, Rest, Budget)
    end.

guest_frame_limit() ->
    Key = {?MODULE, guest_frame_limit},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Limit = case os:getenv("KETTLECORN_MAX_GUEST_FRAME_BYTES") of
                false -> infinity;
                Value -> list_to_integer(Value)
            end,
            persistent_term:put(Key, Limit),
            Limit;
        Limit -> Limit
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
