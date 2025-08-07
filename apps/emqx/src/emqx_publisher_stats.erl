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

-module(emqx_publisher_stats).

-behaviour(gen_server).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx_utils/include/emqx_message.hrl").

-export([
    start_link/0,
    stop/0
]).

-export([
    on_message_publish/1,
    get_publisher_stats/0,
    get_publisher_stats/1,
    get_publisher_stats/2,
    clear_stats/0,
    clear_stats/1,
    get_current_second_key/0
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
-define(TAB, ?MODULE).
% 1分ごとにクリーンアップ
-define(CLEANUP_INTERVAL, timer:seconds(60)).
% 1時間保持
-define(RETENTION_SECONDS, 3600).

-record(state, {
    cleanup_timer :: undefined | reference()
}).

-type publisher_stats() :: #{
    clientid := binary(),
    publish_count := non_neg_integer(),
    timestamp := non_neg_integer()
}.

% "20250725132701"形式
-type second_key() :: binary().

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_server:call(?SERVER, stop, infinity).

%% @doc メッセージPublish時のフック関数
-spec on_message_publish(emqx_types:message()) -> {ok, emqx_types:message()}.
on_message_publish(Message = #message{from = ClientId, topic = Topic, flags = Flags}) ->
    case maps:get(sys, Flags, false) of
        false ->
            %% システムメッセージ以外をカウント
            record_publish(ClientId, Topic);
        true ->
            ok
    end,
    {ok, Message}.

%% @doc 全Publisherの統計を取得
-spec get_publisher_stats() -> [publisher_stats()].
get_publisher_stats() ->
    gen_server:call(?SERVER, get_all_stats, infinity).

%% @doc 特定のPublisherの統計を取得
-spec get_publisher_stats(binary()) -> [publisher_stats()].
get_publisher_stats(ClientId) ->
    gen_server:call(?SERVER, {get_publisher_stats, ClientId}, infinity).

%% @doc 特定のPublisherの特定秒の統計を取得
-spec get_publisher_stats(binary(), second_key()) -> publisher_stats() | undefined.
get_publisher_stats(ClientId, SecondKey) ->
    gen_server:call(?SERVER, {get_publisher_stats, ClientId, SecondKey}, infinity).

%% @doc 全統計をクリア
-spec clear_stats() -> ok.
clear_stats() ->
    gen_server:call(?SERVER, clear_all_stats, infinity).

%% @doc 特定のPublisherの統計をクリア
-spec clear_stats(binary()) -> ok.
clear_stats(ClientId) ->
    gen_server:call(?SERVER, {clear_stats, ClientId}, infinity).

%% @doc 現在の秒キーを取得（"20250725132701"形式）
-spec get_current_second_key() -> second_key().
get_current_second_key() ->
    {Date, Time} = calendar:universal_time(),
    {{Year, Month, Day}, {Hour, Min, Sec}} = {Date, Time},
    list_to_binary(
        io_lib:format(
            "~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B",
            [Year, Month, Day, Hour, Min, Sec]
        )
    ).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    %% ETSテーブルを作成
    ok = emqx_utils_ets:new(?TAB, [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    %% メッセージフックを登録
    ok = emqx_hooks:put('message.publish', {?MODULE, on_message_publish, []}, 100),
    %% クリーンアップタイマーを開始
    Timer = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {ok, #state{cleanup_timer = Timer}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(get_all_stats, _From, State) ->
    Stats = collect_all_stats(),
    {reply, Stats, State};
handle_call({get_publisher_stats, ClientId}, _From, State) ->
    Stats = collect_publisher_stats(ClientId),
    {reply, Stats, State};
handle_call({get_publisher_stats, ClientId, SecondKey}, _From, State) ->
    Stats = get_publisher_stats_for_second(ClientId, SecondKey),
    {reply, Stats, State};
handle_call(clear_all_stats, _From, State) ->
    ets:delete_all_objects(?TAB),
    {reply, ok, State};
handle_call({clear_stats, ClientId}, _From, State) ->
    clear_publisher_stats(ClientId),
    {reply, ok, State};
handle_call(Req, _From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", call => Req}),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", cast => Msg}),
    {noreply, State}.

handle_info(cleanup, State = #state{cleanup_timer = _Timer}) ->
    cleanup_old_stats(),
    NewTimer = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {noreply, State#state{cleanup_timer = NewTimer}};
handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {noreply, State}.

terminate(_Reason, #state{cleanup_timer = Timer}) ->
    emqx_utils:cancel_timer(Timer),
    %% メッセージフックを削除
    emqx_hooks:del('message.publish', {?MODULE, on_message_publish, []}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% @doc Publishを記録
-spec record_publish(binary(), binary()) -> ok.
record_publish(ClientId, Topic) ->
    SecondKey = get_current_second_key(),
    Key = {ClientId, SecondKey},
    case ets:lookup(?TAB, Key) of
        [] ->
            %% 新しいエントリを作成
            Stats = #{
                clientid => ClientId,
                publish_count => 1,
                timestamp => erlang:system_time(millisecond),
                topic => Topic
            },
            ets:insert(?TAB, {Key, Stats});
        [{Key, Stats}] ->
            %% 既存のエントリを更新
            NewCount = maps:get(publish_count, Stats, 0) + 1,
            NewStats = Stats#{publish_count => NewCount},
            ets:insert(?TAB, {Key, NewStats})
    end.

%% @doc 全Publisherの統計を収集
-spec collect_all_stats() -> [publisher_stats()].
collect_all_stats() ->
    ets:foldl(
        fun({_Key, Stats}, Acc) ->
            [Stats | Acc]
        end,
        [],
        ?TAB
    ).

%% @doc 特定のPublisherの統計を収集
-spec collect_publisher_stats(binary()) -> [publisher_stats()].
collect_publisher_stats(ClientId) ->
    ets:foldl(
        fun
            ({{PubClientId, _SecondKey}, Stats}, Acc) when PubClientId =:= ClientId ->
                [Stats | Acc];
            (_, Acc) ->
                Acc
        end,
        [],
        ?TAB
    ).

%% @doc 特定のPublisherの特定秒の統計を取得
-spec get_publisher_stats_for_second(binary(), second_key()) -> publisher_stats() | undefined.
get_publisher_stats_for_second(ClientId, SecondKey) ->
    Key = {ClientId, SecondKey},
    case ets:lookup(?TAB, Key) of
        [] -> undefined;
        [{Key, Stats}] -> Stats
    end.

%% @doc 特定のPublisherの統計をクリア
-spec clear_publisher_stats(binary()) -> ok.
clear_publisher_stats(ClientId) ->
    ets:foldl(
        fun
            ({{PubClientId, _SecondKey}, _Stats}, _Acc) when PubClientId =:= ClientId ->
                ets:delete(?TAB, {PubClientId, _SecondKey});
            (_, Acc) ->
                Acc
        end,
        ok,
        ?TAB
    ).

%% @doc 古い統計をクリーンアップ
-spec cleanup_old_stats() -> ok.
cleanup_old_stats() ->
    Now = erlang:system_time(millisecond),
    CutoffTime = Now - (?RETENTION_SECONDS * 1000),
    ets:foldl(
        fun({Key, Stats}, _Acc) ->
            Timestamp = maps:get(timestamp, Stats, 0),
            case Timestamp < CutoffTime of
                true ->
                    ets:delete(?TAB, Key);
                false ->
                    ok
            end
        end,
        ok,
        ?TAB
    ).
