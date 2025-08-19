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

-module(emqx_cpu_redirect).

-behaviour(gen_server).

-include("emqx.hrl").
-include("emqx_mqtt.hrl").
-include("logger.hrl").

-export([
    start_link/0,
    stop/0,
    maybe_redirect_publisher/0,
    find_max_throughput_publisher/0,
    find_low_cpu_nodes/0,
    get_node_cpu_util/1,
    format_server_references/1,
    node_to_address/1,
    disconnect_publisher/2,
    should_redirect/1,
    get_local_node_info/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
% コア数×0.6の閾値（動的に計算）
% 30秒のクールダウン
-define(REDIRECT_COOLDOWN, timer:seconds(30)).

-record(state, {
    last_redirect_time :: undefined | non_neg_integer()
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_server:call(?SERVER, stop, infinity).

%% @doc CPU使用率が高い場合にpublisherをリダイレクト
-spec maybe_redirect_publisher() -> ok.
maybe_redirect_publisher() ->
    gen_server:cast(?SERVER, maybe_redirect_publisher).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, #state{last_redirect_time = undefined}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(Req, _From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", call => Req}),
    {reply, ignored, State}.

handle_cast(maybe_redirect_publisher, State) ->
    case should_redirect(State) of
        true ->
            case find_max_throughput_publisher() of
                {ok, ClientId, Throughput} ->
                    case find_low_cpu_nodes() of
                        [] ->
                            %% 他のノードの情報も取得してログに含める
                            OtherNodesInfo = get_other_nodes_info(),
                            ?SLOG(warning, #{
                                msg => "no_low_cpu_nodes_available",
                                client_id => ClientId,
                                throughput => Throughput,
                                other_nodes_info => OtherNodesInfo
                            });
                        LowCpuNodes ->
                            ServerReferences = format_server_references(LowCpuNodes),
                            case disconnect_publisher(ClientId, ServerReferences) of
                                ok ->
                                    ?SLOG(info, #{
                                        msg => "publisher_redirected",
                                        client_id => ClientId,
                                        throughput => Throughput,
                                        server_references => ServerReferences,
                                        target_nodes => LowCpuNodes
                                    });
                                {error, Reason} ->
                                    ?SLOG(error, #{
                                        msg => "failed_to_redirect_publisher",
                                        client_id => ClientId,
                                        reason => Reason
                                    })
                            end
                    end;
                {error, Reason} ->
                    ?SLOG(warning, #{
                        msg => "no_publishers_found",
                        reason => Reason
                    })
            end,
            {noreply, State#state{last_redirect_time = erlang:system_time(millisecond)}};
        false ->
            {noreply, State}
    end;
handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", cast => Msg}),
    {noreply, State}.

handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% @doc リダイレクトすべきかチェック
-spec should_redirect(#state{}) -> boolean().
should_redirect(#state{last_redirect_time = LastTime}) ->
    Now = erlang:system_time(millisecond),
    case LastTime of
        undefined ->
            true;
        LastTime when is_integer(LastTime) ->
            case (Now - LastTime) > ?REDIRECT_COOLDOWN of
                true -> true;
                false -> false
            end;
        _ ->
            false
    end.

%% @doc 最もスループットが大きいpublisherを特定
-spec find_max_throughput_publisher() -> {ok, binary(), non_neg_integer()} | {error, term()}.
find_max_throughput_publisher() ->
    try
        %% 全publisherの統計を取得
        AllStats = emqx_publisher_stats:get_publisher_stats(),

        %% 直近60秒のpublish数（スループット）を計算
        %% タイムスタンプが秒単位かミリ秒単位かを自動判定して処理
        CurrentTime = erlang:system_time(second),
        RecentStats = [
            {maps:get(clientid, S), maps:get(publish_count, S, 0)}
         || S <- AllStats,
            case maps:get(timestamp, S, 0) of
                Timestamp when Timestamp > 1000000000000 ->
                    %% ミリ秒単位（13桁以上）
                    (Timestamp div 1000) >= (CurrentTime - 60);
                Timestamp when Timestamp > 1000000000 ->
                    %% 秒単位（10桁）
                    Timestamp >= (CurrentTime - 60);
                _ ->
                    false
            end
        ],

        case RecentStats of
            [] ->
                {error, no_recent_publishers};
            _ ->
                %% クライアント別のスループットを集計
                ClientThroughput = lists:foldl(
                    fun({ClientId, Count}, Acc) ->
                        maps:update_with(ClientId, fun(V) -> V + Count end, Count, Acc)
                    end,
                    #{},
                    RecentStats
                ),
                %% スループットが最大のpublisherを特定
                {ClientId, MaxThroughput} = maps:fold(
                    fun(K, V, {MaxClient, MaxCount}) ->
                        case V > MaxCount of
                            true -> {K, V};
                            false -> {MaxClient, MaxCount}
                        end
                    end,
                    {<<>>, 0},
                    ClientThroughput
                ),
                {ok, ClientId, MaxThroughput}
        end
    catch
        E:R:S ->
            ?SLOG(error, #{
                msg => "error_finding_max_throughput_publisher",
                error => E,
                reason => R,
                stacktrace => S
            }),
            {error, {E, R}}
    end.

%% @doc CPU使用率が低いノードを特定
-spec find_low_cpu_nodes() -> [node()].
find_low_cpu_nodes() ->
    try
        Nodes = emqx:running_nodes(),
        %% 自身のノードを除外
        OtherNodes = lists:delete(node(), Nodes),
        ?SLOG(debug, #{
            msg => "finding_low_cpu_nodes",
            total_nodes => Nodes,
            other_nodes => OtherNodes
        }),
        LowCpuNodes = lists:filter(
            fun(Node) ->
                case get_node_cpu_util(Node) of
                    {ok, RawLoadAvg} when is_number(RawLoadAvg) ->
                        %% 各ノードの実際のコア数を取得して閾値を計算
                        NodeCores = get_node_cores(Node),
                        NodeThreshold = NodeCores * 0.6,
                        %% emqx_vm:cpu_util()は256でスケーリングされたロードアベレージを返す
                        %% 256で割って実際のロードアベレージを取得
                        ActualLoadAvg = RawLoadAvg / 256.0,
                        IsLowCpu = ActualLoadAvg < NodeThreshold,
                        ?SLOG(debug, #{
                            msg => "node_cpu_check",
                            node => Node,
                            raw_load_avg => RawLoadAvg,
                            actual_load_avg => ActualLoadAvg,
                            cores => NodeCores,
                            threshold => NodeThreshold,
                            is_low_cpu => IsLowCpu
                        }),
                        IsLowCpu;
                    {error, Reason} ->
                        ?SLOG(debug, #{
                            msg => "node_cpu_check_error",
                            node => Node,
                            error => Reason
                        }),
                        false
                end
            end,
            OtherNodes
        ),
        ?SLOG(debug, #{
            msg => "low_cpu_nodes_result",
            low_cpu_nodes => LowCpuNodes
        }),
        LowCpuNodes
    catch
        E:R:S ->
            ?SLOG(error, #{
                msg => "error_finding_low_cpu_nodes",
                error => E,
                reason => R,
                stacktrace => S
            }),
            []
    end.

%% @doc ノードのCPU使用率を取得
-spec get_node_cpu_util(node()) -> {ok, float()} | {error, term()}.
get_node_cpu_util(Node) ->
    try
        case Node =:= node() of
            true ->
                %% ローカルノードの場合
                case emqx_vm:cpu_util() of
                    CpuUtil when is_number(CpuUtil) ->
                        {ok, CpuUtil};
                    _ ->
                        {error, cpu_util_not_available}
                end;
            false ->
                %% リモートノードの場合
                case erpc:call(Node, emqx_vm, cpu_util, [], 5000) of
                    CpuUtil when is_number(CpuUtil) ->
                        {ok, CpuUtil};
                    _ ->
                        {error, cpu_util_not_available}
                end
        end
    catch
        E:R ->
            {error, {E, R}}
    end.

%% @doc ノードのコア数を取得
-spec get_node_cores(node()) -> non_neg_integer().
get_node_cores(Node) ->
    try
        case Node =:= node() of
            true ->
                %% ローカルノードの場合
                erlang:system_info(schedulers_online);
            false ->
                %% リモートノードの場合
                case erpc:call(Node, erlang, system_info, [schedulers_online], 5000) of
                    Schedulers when is_integer(Schedulers) ->
                        Schedulers;
                    _ ->
                        % エラー時は0を返す
                        0
                end
        end
    catch
        E:R ->
            ?SLOG(error, #{
                msg => "error_getting_node_cores",
                node => Node,
                error => E,
                reason => R
            }),
            % エラー時は0を返す
            0
    end.

%% @doc Server Referenceをフォーマット
-spec format_server_references([node()]) -> binary().
format_server_references(Nodes) ->
    Addresses = lists:map(fun node_to_address/1, Nodes),
    iolist_to_binary(string:join(Addresses, ",")).

%% @doc ノードをアドレスに変換
-spec node_to_address(node()) -> string().
node_to_address(Node) ->
    %% ノード名からIPアドレスを抽出
    NodeStr = atom_to_list(Node),
    case string:split(NodeStr, "@") of
        [_Name, Host] ->
            Host;
        _ ->
            %% フォールバック: ノード名をそのまま使用
            NodeStr
    end.

%% @doc publisherをdisconnect
-spec disconnect_publisher(binary(), binary()) -> ok | {error, term()}.
disconnect_publisher(ClientId, ServerReference) ->
    try
        %% クライアントのチャネルPIDを取得
        case emqx_cm:lookup_channels(ClientId) of
            [] ->
                {error, client_not_found};
            Channels when is_list(Channels) ->
                %% チャンネルの形式を確認して処理
                case Channels of
                    [{ChanPid, _ChanInfo} | _] when is_pid(ChanPid) ->
                        %% チャンネル情報付きの形式
                        ChanPid !
                            {disconnect, ?RC_USE_ANOTHER_SERVER, use_another_server, #{
                                'Server-Reference' => ServerReference
                            }},
                        ok;
                    [ChanPid | _] when is_pid(ChanPid) ->
                        %% PIDのみの形式
                        ChanPid !
                            {disconnect, ?RC_USE_ANOTHER_SERVER, use_another_server, #{
                                'Server-Reference' => ServerReference
                            }},
                        ok;
                    _ ->
                        {error, invalid_channel_format}
                end
        end
    catch
        E:R:S ->
            ?SLOG(error, #{
                msg => "error_disconnecting_publisher",
                client_id => ClientId,
                error => E,
                reason => R,
                stacktrace => S
            }),
            {error, {E, R}}
    end.

%% @doc 他のノードの情報を取得
-spec get_other_nodes_info() -> [map()].
get_other_nodes_info() ->
    try
        Nodes = emqx:running_nodes(),
        %% 自身のノードを除外
        OtherNodes = lists:delete(node(), Nodes),
        lists:map(
            fun(Node) ->
                case get_node_info(Node) of
                    {ok, Info} ->
                        Info;
                    {error, Reason} ->
                        #{
                            node => Node,
                            error => Reason
                        }
                end
            end,
            OtherNodes
        )
    catch
        E:R:S ->
            ?SLOG(error, #{
                msg => "error_getting_other_nodes_info",
                error => E,
                reason => R,
                stacktrace => S
            }),
            []
    end.

%% @doc ノードの詳細情報を取得
-spec get_node_info(node()) -> {ok, map()} | {error, term()}.
get_node_info(Node) ->
    try
        case Node =:= node() of
            true ->
                %% ローカルノードの場合
                Cores = erlang:system_info(schedulers_online),
                Threshold = Cores * 0.6,
                case emqx_vm:cpu_util() of
                    LoadAvg when is_number(LoadAvg) ->
                        {ok, #{
                            node => Node,
                            cores => Cores,
                            load_avg => LoadAvg,
                            threshold => Threshold,
                            is_local => true
                        }};
                    _ ->
                        {error, load_average_not_available}
                end;
            false ->
                %% リモートノードの場合
                case erpc:call(Node, ?MODULE, get_local_node_info, [], 5000) of
                    {ok, Info} ->
                        {ok, Info#{is_local => false}};
                    {error, Reason} ->
                        {error, Reason}
                end
        end
    catch
        E:R ->
            {error, {E, R}}
    end.

%% @doc ローカルノードの情報を取得（リモートノードから呼び出される）
-spec get_local_node_info() -> {ok, map()} | {error, term()}.
get_local_node_info() ->
    try
        Cores = erlang:system_info(schedulers_online),
        Threshold = Cores * 0.6,
        case emqx_vm:cpu_util() of
            LoadAvg when is_number(LoadAvg) ->
                {ok, #{
                    node => node(),
                    cores => Cores,
                    load_avg => LoadAvg,
                    threshold => Threshold
                }};
            _ ->
                {error, load_average_not_available}
        end
    catch
        E:R ->
            {error, {E, R}}
    end.
