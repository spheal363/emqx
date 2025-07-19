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

-module(emqx_server_reference_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/types.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

%% Define channel record for testing
-record(channel, {
    %% MQTT ConnInfo
    conninfo :: emqx_types:conninfo(),
    %% MQTT ClientInfo
    clientinfo :: emqx_types:clientinfo(),
    %% MQTT Session
    session :: option(emqx_session:t()),
    %% Keepalive
    keepalive :: option(emqx_keepalive:keepalive()),
    %% MQTT Will Msg
    will_msg :: option(emqx_types:message()),
    %% MQTT Topic Aliases
    topic_aliases :: emqx_types:topic_aliases(),
    %% MQTT Topic Alias Maximum
    alias_maximum :: option(map()),
    %% Authentication Data Cache
    auth_cache :: option(map()),
    %% Quota checkers
    quota :: emqx_limiter_container:container(),
    %% Timers
    timers :: #{atom() => disabled | option(reference())},
    %% Conn State
    conn_state :: conn_state(),
    %% Takeover
    takeover :: boolean(),
    %% Resume
    resuming :: false | _ReplayContext,
    %% Pending delivers when takeovering
    pendings :: list()
}).

-type conn_state() ::
    idle
    | connecting
    | connected
    | reauthenticating
    | disconnected.

%%--------------------------------------------------------------------
%% CT callbacks
%%--------------------------------------------------------------------

all() ->
    [
        t_server_reference_in_connack,
        t_server_reference_ipv4_format,
        t_server_reference_ipv6_format,
        t_server_reference_multiple_nodes,
        t_server_reference_no_nodes,
        t_server_reference_rpc_failure,
        t_user_properties_in_connack
    ].

init_per_suite(Config) ->
    emqx_common_test_helpers:boot_modules(all),
    emqx_common_test_helpers:start_apps([]),
    Config.

end_per_suite(_Config) ->
    emqx_common_test_helpers:stop_apps([]).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

t_server_reference_in_connack(_Config) ->
    %% Mock emqx:running_nodes() to return a single node
    meck:new(emqx, [passthrough]),
    meck:expect(emqx, running_nodes, 0, [node()]),

    %% Mock emqx_listeners:list() to return a simple listener
    meck:new(emqx_listeners, [passthrough]),
    meck:expect(emqx_listeners, list, 0, [
        {'tcp:default', #{bind => "127.0.0.1:1883", running => true}}
    ]),

    %% Create a test channel
    Channel = #channel{
        clientinfo = #{zone => default},
        conninfo = #{receive_maximum => 100}
    },

    %% Test enrich_connack_caps
    AckProps = emqx_channel:enrich_connack_caps(#{}, Channel),

    %% Verify Server-Reference is present
    ?assert(maps:is_key('Server-Reference', AckProps)),
    ServerRef = maps:get('Server-Reference', AckProps),
    ?assertEqual("127.0.0.1:1883", ServerRef),

    %% Verify User Properties are present
    ?assert(maps:is_key('User-Property', AckProps)),
    UserProps = maps:get('User-Property', AckProps),
    ?assert(lists:keymember(<<"cluster-nodes">>, 1, UserProps)),
    ?assert(lists:keymember(<<"cluster-node-count">>, 1, UserProps)),
    ?assert(lists:keymember(<<"current-node">>, 1, UserProps)),

    %% Verify User Property values
    {<<"cluster-nodes">>, ClusterNodes} = lists:keyfind(<<"cluster-nodes">>, 1, UserProps),
    {<<"cluster-node-count">>, ClusterNodeCount} = lists:keyfind(
        <<"cluster-node-count">>, 1, UserProps
    ),
    {<<"current-node">>, CurrentNode} = lists:keyfind(<<"current-node">>, 1, UserProps),
    ?assertEqual(<<"127.0.0.1:1883">>, ClusterNodes),
    ?assertEqual(<<"1">>, ClusterNodeCount),
    ?assertEqual(atom_to_binary(node(), utf8), CurrentNode),

    meck:unload([emqx, emqx_listeners]).

t_server_reference_ipv4_format(_Config) ->
    meck:new(emqx, [passthrough]),
    meck:expect(emqx, running_nodes, 0, [node()]),

    meck:new(emqx_listeners, [passthrough]),
    meck:expect(emqx_listeners, list, 0, [
        {'tcp:default', #{bind => "192.168.1.100:8883", running => true}}
    ]),

    Channel = #channel{
        clientinfo = #{zone => default},
        conninfo = #{receive_maximum => 100}
    },

    AckProps = emqx_channel:enrich_connack_caps(#{}, Channel),
    ServerRef = maps:get('Server-Reference', AckProps),
    ?assertEqual("192.168.1.100:8883", ServerRef),

    meck:unload([emqx, emqx_listeners]).

t_server_reference_ipv6_format(_Config) ->
    meck:new(emqx, [passthrough]),
    meck:expect(emqx, running_nodes, 0, [node()]),

    meck:new(emqx_listeners, [passthrough]),
    meck:expect(emqx_listeners, list, 0, [
        {'tcp:default', #{bind => "[2001:db8::1]:1883", running => true}}
    ]),

    Channel = #channel{
        clientinfo = #{zone => default},
        conninfo = #{receive_maximum => 100}
    },

    AckProps = emqx_channel:enrich_connack_caps(#{}, Channel),
    ServerRef = maps:get('Server-Reference', AckProps),
    ?assertEqual("[2001:db8::1]:1883", ServerRef),

    meck:unload([emqx, emqx_listeners]).

t_server_reference_multiple_nodes(_Config) ->
    meck:new(emqx, [passthrough]),
    meck:expect(emqx, running_nodes, 0, [node1@host1, node2@host2]),

    meck:new(emqx_listeners, [passthrough]),
    meck:expect(emqx_listeners, list, 0, [
        {'tcp:default', #{bind => "192.168.1.100:1883", running => true}}
    ]),

    %% Mock RPC calls for different nodes
    meck:new(rpc, [passthrough]),
    meck:expect(rpc, call, fun
        (node1@host1, emqx_listeners, list, [], 5000) ->
            [{'tcp:default', #{bind => "192.168.1.100:1883", running => true}}];
        (node2@host2, emqx_listeners, list, [], 5000) ->
            [{'tcp:default', #{bind => "192.168.1.101:1883", running => true}}]
    end),

    Channel = #channel{
        clientinfo = #{zone => default},
        conninfo = #{receive_maximum => 100}
    },

    AckProps = emqx_channel:enrich_connack_caps(#{}, Channel),
    ServerRef = maps:get('Server-Reference', AckProps),

    %% Should contain both server references separated by space
    ?assert(string:find(ServerRef, "192.168.1.100:1883") =/= nomatch),
    ?assert(string:find(ServerRef, "192.168.1.101:1883") =/= nomatch),

    meck:unload([emqx, emqx_listeners, rpc]).

t_server_reference_no_nodes(_Config) ->
    meck:new(emqx, [passthrough]),
    meck:expect(emqx, running_nodes, 0, []),

    Channel = #channel{
        clientinfo = #{zone => default},
        conninfo = #{receive_maximum => 100}
    },

    AckProps = emqx_channel:enrich_connack_caps(#{}, Channel),

    %% Should not contain Server-Reference when no nodes
    ?assertNot(maps:is_key('Server-Reference', AckProps)),
    %% Should not contain User Properties when no nodes
    ?assertNot(maps:is_key('User-Property', AckProps)),

    meck:unload([emqx]).

t_server_reference_rpc_failure(_Config) ->
    meck:new(emqx, [passthrough]),
    meck:expect(emqx, running_nodes, 0, [node()]),

    meck:new(rpc, [passthrough]),
    meck:expect(rpc, call, fun(_, _, _, _, _) -> {badrpc, timeout} end),

    Channel = #channel{
        clientinfo = #{zone => default},
        conninfo = #{receive_maximum => 100}
    },

    AckProps = emqx_channel:enrich_connack_caps(#{}, Channel),

    %% Should not contain Server-Reference when RPC fails
    ?assertNot(maps:is_key('Server-Reference', AckProps)),
    %% Should not contain User Properties when RPC fails
    ?assertNot(maps:is_key('User-Property', AckProps)),

    meck:unload([emqx, rpc]).

t_user_properties_in_connack(_Config) ->
    %% Mock emqx:running_nodes() to return multiple nodes
    meck:new(emqx, [passthrough]),
    meck:expect(emqx, running_nodes, 0, [node1@host1, node2@host2]),

    %% Mock emqx_listeners:list() to return a simple listener
    meck:new(emqx_listeners, [passthrough]),
    meck:expect(emqx_listeners, list, 0, [
        {'tcp:default', #{bind => "192.168.1.100:1883", running => true}}
    ]),

    %% Mock RPC calls for different nodes
    meck:new(rpc, [passthrough]),
    meck:expect(rpc, call, fun
        (node1@host1, emqx_listeners, list, [], 5000) ->
            [{'tcp:default', #{bind => "192.168.1.100:1883", running => true}}];
        (node2@host2, emqx_listeners, list, [], 5000) ->
            [{'tcp:default', #{bind => "192.168.1.101:1883", running => true}}]
    end),

    %% Create a test channel with existing User Properties
    Channel = #channel{
        clientinfo = #{zone => default},
        conninfo = #{receive_maximum => 100}
    },

    %% Test with existing User Properties
    ExistingUserProps = [{<<"existing-key">>, <<"existing-value">>}],
    AckProps = emqx_channel:enrich_connack_caps(#{'User-Property' => ExistingUserProps}, Channel),

    %% Verify User Properties are present and merged correctly
    ?assert(maps:is_key('User-Property', AckProps)),
    UserProps = maps:get('User-Property', AckProps),

    %% Should contain existing User Properties
    ?assert(lists:keymember(<<"existing-key">>, 1, UserProps)),
    {<<"existing-key">>, <<"existing-value">>} = lists:keyfind(<<"existing-key">>, 1, UserProps),

    %% Should contain cluster User Properties
    ?assert(lists:keymember(<<"cluster-nodes">>, 1, UserProps)),
    ?assert(lists:keymember(<<"cluster-node-count">>, 1, UserProps)),
    ?assert(lists:keymember(<<"current-node">>, 1, UserProps)),

    %% Verify cluster User Property values
    {<<"cluster-nodes">>, ClusterNodes} = lists:keyfind(<<"cluster-nodes">>, 1, UserProps),
    {<<"cluster-node-count">>, ClusterNodeCount} = lists:keyfind(
        <<"cluster-node-count">>, 1, UserProps
    ),
    {<<"current-node">>, CurrentNode} = lists:keyfind(<<"current-node">>, 1, UserProps),
    ?assertEqual(<<"192.168.1.100:1883,192.168.1.101:1883">>, ClusterNodes),
    ?assertEqual(<<"2">>, ClusterNodeCount),
    ?assertEqual(atom_to_binary(node(), utf8), CurrentNode),

    %% Verify total number of User Properties

    %% 1 existing + 3 cluster
    ?assertEqual(4, length(UserProps)),

    meck:unload([emqx, emqx_listeners, rpc]).
