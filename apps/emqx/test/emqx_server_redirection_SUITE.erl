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

-module(emqx_server_redirection_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(APP, emqx).

all() ->
    [
        t_enable_disable,
        t_set_redirect_servers,
        t_get_status,
        t_validate_servers,
        t_get_redirect_server,
        t_hook_callbacks
    ].

init_per_suite(Config) ->
    emqx_cth_suite:start([emqx], #{work_dir => emqx_cth_suite:work_dir(Config)}),
    Config.

end_per_suite(_Config) ->
    emqx_cth_suite:stop(),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

t_enable_disable(_Config) ->
    %% Test enable with valid options
    Options = #{
        redirect_servers => [
            #{host => <<"server1.example.com">>, port => 1883},
            #{host => <<"server2.example.com">>, port => 1884}
        ],
        redirect_strategy => random,
        max_connections => 1000
    },
    ?assertEqual(ok, emqx_server_redirection:enable(Options)),

    %% Check status
    Status = emqx_server_redirection:get_status(),
    ?assertEqual(true, maps:get(enabled, Status)),
    ?assertEqual(2, length(maps:get(redirect_servers, Status))),
    ?assertEqual(random, maps:get(redirect_strategy, Status)),
    ?assertEqual(1000, maps:get(max_connections, Status)),

    %% Test disable
    ?assertEqual(ok, emqx_server_redirection:disable()),

    %% Check status after disable
    Status2 = emqx_server_redirection:get_status(),
    ?assertEqual(false, maps:get(enabled, Status2)).

t_set_redirect_servers(_Config) ->
    %% Enable first
    Options = #{
        redirect_servers => [
            #{host => <<"server1.example.com">>, port => 1883}
        ],
        redirect_strategy => random,
        max_connections => 1000
    },
    ?assertEqual(ok, emqx_server_redirection:enable(Options)),

    %% Set new servers
    NewServers = [
        #{host => <<"server3.example.com">>, port => 1885},
        #{host => <<"server4.example.com">>, port => 1886}
    ],
    ?assertEqual(ok, emqx_server_redirection:set_redirect_servers(NewServers)),

    %% Check servers were updated
    ?assertEqual(NewServers, emqx_server_redirection:get_redirect_servers()).

t_get_status(_Config) ->
    %% Test initial status
    Status = emqx_server_redirection:get_status(),
    ?assertEqual(false, maps:get(enabled, Status)),
    ?assertEqual([], maps:get(redirect_servers, Status)),
    ?assertEqual(random, maps:get(redirect_strategy, Status)),
    ?assertEqual(1000, maps:get(max_connections, Status)),
    ?assertEqual(0, maps:get(current_connections, Status)).

t_validate_servers(_Config) ->
    %% Test valid servers
    ValidServers = [
        #{host => <<"server1.example.com">>, port => 1883},
        #{host => <<"server2.example.com">>}
    ],
    ?assertEqual(ok, emqx_server_redirection:set_redirect_servers(ValidServers)),

    %% Test invalid servers
    InvalidServers = [
        %% Missing host
        #{port => 1883},
        %% Invalid port
        #{host => <<"server3.example.com">>, port => 70000}
    ],
    ?assertEqual(
        {error, "Missing host in server configuration"},
        emqx_server_redirection:set_redirect_servers(InvalidServers)
    ).

t_get_redirect_server(_Config) ->
    %% Enable with servers
    Options = #{
        redirect_servers => [
            #{host => <<"server1.example.com">>, port => 1883},
            #{host => <<"server2.example.com">>, port => 1884}
        ],
        redirect_strategy => random,
        max_connections => 1000
    },
    ?assertEqual(ok, emqx_server_redirection:enable(Options)),

    %% Test getting redirect server
    {ok, ServerRef} = emqx_server_redirection:get_redirect_server(),
    ?assert(is_binary(ServerRef)),
    ?assert(string:find(ServerRef, <<"server">>) =/= nomatch).

t_hook_callbacks(_Config) ->
    %% Enable server redirection
    Options = #{
        redirect_servers => [
            #{host => <<"server1.example.com">>, port => 1883}
        ],
        redirect_strategy => random,
        %% Set low to trigger redirection
        max_connections => 1
    },
    ?assertEqual(ok, emqx_server_redirection:enable(Options)),

    %% Test on_connect callback when max connections reached
    ConnInfo = #{},
    Props = #{},
    ?assertEqual(
        {stop, {error, ?RC_USE_ANOTHER_SERVER}},
        emqx_server_redirection:on_connect(ConnInfo, Props)
    ),

    %% Test on_connack callback for MQTT v5
    ClientInfo = #{proto_name => <<"MQTT">>, proto_ver => ?MQTT_PROTO_V5},
    Reason = use_another_server,
    Props2 = #{},
    {ok, NewProps} = emqx_server_redirection:on_connack(ClientInfo, Reason, Props2),
    ?assert(maps:is_key('Server-Reference', NewProps)),

    %% Test on_connack callback for other protocols
    ClientInfo2 = #{proto_name => <<"MQTT">>, proto_ver => ?MQTT_PROTO_V4},
    {ok, Props3} = emqx_server_redirection:on_connack(ClientInfo2, Reason, Props2),
    ?assertEqual(Props2, Props3).
