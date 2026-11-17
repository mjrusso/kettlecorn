%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 1998-2026. All Rights Reserved.
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
-module(inet_gethost_native).
-moduledoc false.

-export([gethostbyname/1, gethostbyname/2, gethostbyaddr/1, control/1]).

-include_lib("kernel/include/inet.hrl").

-define(VALID_V6(Part), is_integer(Part), Part < 65536).
-define(VALID_V4(Part), is_integer(Part), Part < 256).

gethostbyname(Name) ->
    gethostbyname(Name, inet).

%% WASI cannot run inet_gethost; the NIF uses wasi:sockets/ip-name-lookup.
gethostbyname(Name, Family)
  when is_list(Name), (Family =:= inet orelse Family =:= inet6) ->
    case wasm:getaddrinfo(unicode:characters_to_binary(Name), Family) of
        {ok, []} ->
            {error, nxdomain};
        {ok, Addrs} ->
            Length = case Family of inet -> 4; inet6 -> 16 end,
            {ok, #hostent{h_name = Name, h_aliases = [], h_addrtype = Family,
                          h_length = Length, h_addr_list = Addrs}};
        {error, _} = Error ->
            Error
    end;
gethostbyname(Name, Type) when is_atom(Name) ->
    gethostbyname(atom_to_list(Name), Type);
gethostbyname(_, _) ->
    {error, formerr}.

%% WASI has no reverse name lookup.
gethostbyaddr({A,B,C,D})
  when ?VALID_V4(A), ?VALID_V4(B), ?VALID_V4(C), ?VALID_V4(D) ->
    {error, notfound};
gethostbyaddr({A,B,C,D,E,F,G,H})
  when ?VALID_V6(A), ?VALID_V6(B), ?VALID_V6(C), ?VALID_V6(D),
       ?VALID_V6(E), ?VALID_V6(F), ?VALID_V6(G), ?VALID_V6(H) ->
    {error, notfound};
gethostbyaddr(Addr) when is_list(Addr) ->
    case inet_parse:address(Addr) of
        {ok, IP} -> gethostbyaddr(IP);
        _Error -> {error, formerr}
    end;
gethostbyaddr(Addr) when is_atom(Addr) ->
    gethostbyaddr(atom_to_list(Addr));
gethostbyaddr(_) -> {error, formerr}.

control({debug_level, Level}) when is_integer(Level) -> ok;
control(soft_restart) -> ok;
control(_) -> {error, formerr}.
