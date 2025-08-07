%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_cpu_redirect_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_common_test_helpers:start_apps([emqx]),
    Config.

end_per_suite(_Config) ->
    emqx_common_test_helpers:stop_apps([emqx]).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

t_find_max_throughput_publisher(_Config) ->
    %% テスト用のpublisher統計を作成
    ClientId1 = <<"client1">>,
    ClientId2 = <<"client2">>,

    %% モックのpublisher統計を作成
    Stats = [
        #{
            clientid => ClientId1,
            publish_count => 100,
            timestamp => erlang:system_time(millisecond)
        },
        #{
            clientid => ClientId2,
            publish_count => 200,
            timestamp => erlang:system_time(millisecond)
        }
    ],

    %% モックのget_publisher_statsを設定
    meck:new(emqx_publisher_stats, [passthrough]),
    meck:expect(emqx_publisher_stats, get_publisher_stats, fun() -> Stats end),

    %% テスト実行
    {ok, ClientId2, 200} = emqx_cpu_redirect:find_max_throughput_publisher(),

    %% モックをクリーンアップ
    meck:unload(emqx_publisher_stats).

t_find_low_cpu_nodes(_Config) ->
    %% テスト用のノードリストを作成
    Nodes = [node(), 'emqx@node2', 'emqx@node3'],

    %% モックのrunning_nodesを設定
    meck:new(emqx, [passthrough]),
    meck:expect(emqx, running_nodes, fun() -> Nodes end),

    %% モックのcpu_utilを設定
    meck:new(emqx_vm, [passthrough]),
    meck:expect(emqx_vm, cpu_util, fun() -> {all, 0.5, 0.5, []} end),

    %% テスト実行
    LowCpuNodes = emqx_cpu_redirect:find_low_cpu_nodes(),
    ?assert(length(LowCpuNodes) > 0),

    %% モックをクリーンアップ
    meck:unload(emqx),
    meck:unload(emqx_vm).

t_format_server_references(_Config) ->
    Nodes = ['emqx@192.168.1.100', 'emqx@192.168.1.101'],
    ServerRefs = emqx_cpu_redirect:format_server_references(Nodes),
    ?assert(is_binary(ServerRefs)),
    ?assert(string:find(ServerRefs, "192.168.1.100") =/= nomatch),
    ?assert(string:find(ServerRefs, "192.168.1.101") =/= nomatch).

t_node_to_address(_Config) ->
    Node1 = 'emqx@192.168.1.100',
    Node2 = 'emqx@localhost',

    Addr1 = emqx_cpu_redirect:node_to_address(Node1),
    Addr2 = emqx_cpu_redirect:node_to_address(Node2),

    ?assertEqual("192.168.1.100", Addr1),
    ?assertEqual("emqx@localhost", Addr2).

t_disconnect_publisher(_Config) ->
    ClientId = <<"test_client">>,
    ServerRefs = <<"192.168.1.100,192.168.1.101">>,

    %% モックのlookup_channelsを設定
    meck:new(emqx_cm, [passthrough]),
    meck:expect(
        emqx_cm,
        lookup_channels,
        fun(ClientId) -> [{self(), #{}}] end
    ),

    %% テスト実行
    ok = emqx_cpu_redirect:disconnect_publisher(ClientId, ServerRefs),

    %% モックをクリーンアップ
    meck:unload(emqx_cm).

t_should_redirect(_Config) ->
    %% 初回実行時はtrue
    State1 = #emqx_cpu_redirect_state{last_redirect_time = undefined},
    ?assert(emqx_cpu_redirect:should_redirect(State1)),

    %% 30秒以内はfalse
    State2 = #emqx_cpu_redirect_state{last_redirect_time = erlang:system_time(millisecond)},
    ?assertNot(emqx_cpu_redirect:should_redirect(State2)),

    %% 30秒経過後はtrue
    State3 = #emqx_cpu_redirect_state{last_redirect_time = erlang:system_time(millisecond) - 31000},
    ?assert(emqx_cpu_redirect:should_redirect(State3)).

t_maybe_redirect_publisher(_Config) ->
    %% 正常なリダイレクト処理のテスト
    ok = emqx_cpu_redirect:maybe_redirect_publisher(),

    %% エラーハンドリングのテスト（publisherが見つからない場合）
    meck:new(emqx_publisher_stats, [passthrough]),
    meck:expect(emqx_publisher_stats, get_publisher_stats, fun() -> [] end),

    ok = emqx_cpu_redirect:maybe_redirect_publisher(),

    %% モックをクリーンアップ
    meck:unload(emqx_publisher_stats).
