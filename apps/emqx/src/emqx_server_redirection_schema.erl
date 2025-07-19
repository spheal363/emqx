%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(emqx_server_redirection_schema).

-include_lib("hocon/include/hoconsc.hrl").

-export([
    namespace/0,
    roots/0,
    fields/1,
    desc/1
]).

namespace() -> "server_redirection".

roots() -> ["server_redirection"].

fields("server_redirection") ->
    [
        {enable,
            ?HOCON(boolean(), #{
                default => false,
                desc => ?DESC("enable")
            })},
        {redirect_servers,
            ?HOCON(?ARRAY(?R_REF(server)), #{
                default => [],
                desc => ?DESC("redirect_servers")
            })},
        {redirect_strategy,
            ?HOCON(hoconsc:enum([random, round_robin]), #{
                default => random,
                desc => ?DESC("redirect_strategy")
            })},
        {max_connections,
            ?HOCON(integer(), #{
                default => 1000,
                desc => ?DESC("max_connections")
            })}
    ];
fields(server) ->
    [
        {host,
            ?HOCON(binary(), #{
                required => true,
                desc => ?DESC("host")
            })},
        {port,
            ?HOCON(integer(), #{
                default => 1883,
                desc => ?DESC("port")
            })},
        {description,
            ?HOCON(binary(), #{
                default => <<>>,
                desc => ?DESC("description")
            })}
    ].

desc("enable") ->
    "Enable MQTT v5 server redirection functionality";
desc("redirect_servers") ->
    "List of servers to redirect clients to";
desc("redirect_strategy") ->
    "Strategy for selecting redirect server (random or round_robin)";
desc("max_connections") ->
    "Maximum number of connections before triggering redirection";
desc("host") ->
    "Hostname or IP address of the redirect server";
desc("port") ->
    "Port number of the redirect server (default: 1883)";
desc("description") ->
    "Optional description for the redirect server";
desc(_) ->
    undefined.
