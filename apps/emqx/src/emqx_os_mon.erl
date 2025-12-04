%%--------------------------------------------------------------------
%% Copyright (c) 2019-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_os_mon).

-behaviour(gen_server).

-include("emqx.hrl").
-include("logger.hrl").

-export([start_link/0]).

-export([
    get_sysmem_high_watermark/0,
    set_sysmem_high_watermark/1,
    get_procmem_high_watermark/0,
    set_procmem_high_watermark/1
]).

-export([
    current_sysmem_percent/0
]).

-export([update/1]).

%% gen_server callbacks
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-export([is_os_check_supported/0]).

-define(OS_MON, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?OS_MON}, ?MODULE, [], []).

update(OS) ->
    gen_server:cast(?MODULE, {monitor_conf_update, OS}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

get_sysmem_high_watermark() ->
    gen_server:call(?OS_MON, ?FUNCTION_NAME, infinity).

set_sysmem_high_watermark(Float) ->
    gen_server:call(?OS_MON, {?FUNCTION_NAME, Float}, infinity).

get_procmem_high_watermark() ->
    memsup:get_procmem_high_watermark().

set_procmem_high_watermark(Float) ->
    memsup:set_procmem_high_watermark(Float).

current_sysmem_percent() ->
    Ratio = load_ctl:get_memory_usage(),
    erlang:floor(Ratio * 10000) / 100.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, undefined, {continue, setup}}.

handle_continue(setup, undefined) ->
    %% start os_mon temporarily
    {ok, _} = application:ensure_all_started(os_mon),
    %% memsup is not reliable, on some systems, it doesn't take
    %% buffer and cache into account that buffer and cache are
    %% reclaimable memory.
    memsup:set_sysmem_high_watermark(1.0),
    SysHW = init_os_monitor(),
    MemRef = start_mem_check_timer(),
    CpuRef = start_cpu_check_timer(),
    %% the value of the first call should be regarded as garbage.
    _Val = cpu_sup:util(),
    {noreply, #{
        sysmem_high_watermark => SysHW,
        mem_time_ref => MemRef,
        cpu_time_ref => CpuRef,
        consecutive_high_cpu_count => 0
    }}.

init_os_monitor() ->
    init_os_monitor(emqx:get_config([sysmon, os])).

init_os_monitor(OS) ->
    #{
        sysmem_high_watermark := SysHW,
        procmem_high_watermark := PHW
    } = OS,
    set_procmem_high_watermark(PHW),
    ok = update_memory_protect_threshold(SysHW),
    ok = update_mem_alarm_status(SysHW),
    SysHW.

handle_call(get_sysmem_high_watermark, _From, #{sysmem_high_watermark := HWM} = State) ->
    {reply, HWM, State};
handle_call({set_sysmem_high_watermark, New}, _From, #{sysmem_high_watermark := _Old} = State) ->
    ok = update_memory_protect_threshold(New),
    ok = update_mem_alarm_status(New),
    {reply, ok, State#{sysmem_high_watermark := New}};
handle_call(Req, _From, State) ->
    {reply, {error, {unexpected_call, Req}}, State}.

handle_cast({monitor_conf_update, OS}, State) ->
    cancel_outdated_timer(State),
    SysHW = init_os_monitor(OS),
    MemRef = start_mem_check_timer(),
    CpuRef = start_cpu_check_timer(),
    {noreply,
        maps:merge(State, #{
            sysmem_high_watermark => SysHW,
            mem_time_ref => MemRef,
            cpu_time_ref => CpuRef,
            consecutive_high_cpu_count => 0
        })};
handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", cast => Msg}),
    {noreply, State}.

handle_info({timeout, _Timer, mem_check}, #{sysmem_high_watermark := HWM} = State) ->
    ok = update_mem_alarm_status(HWM),
    Ref = start_mem_check_timer(),
    {noreply, State#{mem_time_ref => Ref}};
handle_info({timeout, _Timer, cpu_check}, State) ->
    %% コア数を取得して閾値を計算（コア数×0.8）
    Cores = erlang:system_info(schedulers_online),
    CPUThreshold = Cores * 0.8,
    %% cpu_sup:avg1()はスケーリングされた値を返すので、256で割って実際のロードアベレージを取得
    RawLoadAvg = cpu_sup:avg1(),
    LoadAvg =
        case RawLoadAvg of
            Val when is_number(Val) -> Val / 256.0;
            _ -> RawLoadAvg
        end,
    %% 連続で閾値を超えた回数を取得（デフォルトは0）
    ConsecutiveCount = maps:get(consecutive_high_cpu_count, State, 0),
    {_NewConsecutiveCount, NewState} =
        case LoadAvg of
            %% 0 or 0.0
            Load when Load == 0 ->
                %% ロードが0の場合はアラームを非アクティブ化し、カウントをリセット
                ok = emqx_alarm:ensure_deactivated(
                    high_cpu_usage,
                    #{
                        load_avg => Load,
                        threshold => CPUThreshold,
                        cores => Cores
                    },
                    usage_msg(Load, cpu)
                ),
                {0, State#{consecutive_high_cpu_count => 0}};
            Load when is_number(Load) ->
                %% ロードアベレージをCPU使用率のパーセンテージに変換
                %% ロードアベレージがコア数に近い場合、CPU使用率は高い
                %% ロードアベレージがコア数の80%を超えた場合、CPU使用率が高いと判断
                if
                    Load > CPUThreshold ->
                        %% CPU使用率が閾値を超えた場合、連続カウントをインクリメント
                        NewCount = ConsecutiveCount + 1,
                        ?SLOG(debug, #{
                            msg => "cpu_threshold_exceeded",
                            load_avg => Load,
                            threshold => CPUThreshold,
                            cores => Cores,
                            consecutive_count => NewCount
                        }),
                        %% アラームをアクティブ化
                        case
                            emqx_alarm:activate(
                                high_cpu_usage,
                                #{
                                    load_avg => Load,
                                    threshold => CPUThreshold,
                                    cores => Cores,
                                    consecutive_count => NewCount
                                },
                                usage_msg(Load, cpu)
                            )
                        of
                            ok ->
                                %% 新しいアラームが作成された場合
                                ?SLOG(warning, #{
                                    msg => "cpu_alarm_activated",
                                    load_avg => Load,
                                    threshold => CPUThreshold,
                                    cores => Cores,
                                    consecutive_count => NewCount
                                });
                            {error, already_existed} ->
                                %% アラームが既に存在する場合
                                ?SLOG(info, #{
                                    msg => "cpu_alarm_already_active",
                                    load_avg => Load,
                                    threshold => CPUThreshold,
                                    cores => Cores,
                                    consecutive_count => NewCount
                                });
                            Error ->
                                ?SLOG(error, #{
                                    msg => "failed_to_activate_cpu_alarm",
                                    error => Error,
                                    load_avg => Load,
                                    threshold => CPUThreshold
                                })
                        end,
                        %% 2回連続で閾値を超えた場合のみリダイレクトを実行
                        case NewCount >= 2 of
                            true ->
                                ?SLOG(warning, #{
                                    msg => "cpu_consecutive_threshold_exceeded",
                                    load_avg => Load,
                                    threshold => CPUThreshold,
                                    consecutive_count => NewCount,
                                    action => "redirecting_publisher"
                                }),
                                emqx_load_redirect:maybe_redirect_publisher(),
                                %% リダイレクト後はカウントをリセット（クールダウン）
                                {0, State#{consecutive_high_cpu_count => 0}};
                            false ->
                                {NewCount, State#{consecutive_high_cpu_count => NewCount}}
                        end;
                    true ->
                        %% ロードアベレージが閾値以下の場合、アラームを非アクティブ化し、カウントをリセット
                        ok = emqx_alarm:ensure_deactivated(
                            high_cpu_usage,
                            #{
                                load_avg => Load,
                                threshold => CPUThreshold,
                                cores => Cores
                            },
                            usage_msg(Load, cpu)
                        ),
                        ?SLOG(info, #{
                            msg => "cpu_alarm_deactivated",
                            load_avg => Load,
                            threshold => CPUThreshold,
                            cores => Cores
                        }),
                        {0, State#{consecutive_high_cpu_count => 0}}
                end;
            LoadError ->
                %% {error, timeout} ...
                ?SLOG(warning, #{
                    msg => "cpu_monitor_timeout",
                    load_avg => LoadError
                }),
                %% エラー時はカウントをリセット
                {0, State#{consecutive_high_cpu_count => 0}}
        end,
    Ref = start_cpu_check_timer(),
    {noreply, NewState#{cpu_time_ref => Ref}};
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
cancel_outdated_timer(State) ->
    MemRef = maps:get(mem_time_ref, State, undefined),
    CpuRef = maps:get(cpu_time_ref, State, undefined),
    emqx_utils:cancel_timer(MemRef),
    emqx_utils:cancel_timer(CpuRef),
    ok.

start_cpu_check_timer() ->
    Interval = emqx:get_config([sysmon, os, cpu_check_interval]),
    case erlang:system_info(system_architecture) of
        "x86_64-pc-linux-musl" -> undefined;
        _ -> start_timer(Interval, cpu_check)
    end.

is_os_check_supported() ->
    {unix, linux} =:= os:type().

start_mem_check_timer() ->
    Interval = emqx:get_config([sysmon, os, mem_check_interval]),
    case is_integer(Interval) andalso is_os_check_supported() of
        true ->
            start_timer(Interval, mem_check);
        false ->
            undefined
    end.

start_timer(Interval, Msg) ->
    emqx_utils:start_timer(Interval, Msg).

update_mem_alarm_status(HWM) when HWM > 1.0 orelse HWM < 0.0 ->
    ?SLOG(warning, #{msg => "discarded_out_of_range_mem_alarm_threshold", value => HWM}),
    ok = emqx_alarm:ensure_deactivated(
        high_system_memory_usage,
        #{},
        <<"Deactivated mem usage alarm due to out of range threshold">>
    );
update_mem_alarm_status(HWM) ->
    is_os_check_supported() andalso
        do_update_mem_alarm_status(HWM),
    ok.

do_update_mem_alarm_status(HWM0) ->
    HWM = HWM0 * 100,
    Usage = current_sysmem_percent(),
    case Usage > HWM of
        true ->
            _ = emqx_alarm:activate(
                high_system_memory_usage,
                #{
                    usage => Usage,
                    high_watermark => HWM
                },
                usage_msg(Usage, mem)
            );
        false ->
            ok = emqx_alarm:ensure_deactivated(
                high_system_memory_usage,
                #{
                    usage => Usage,
                    high_watermark => HWM
                },
                usage_msg(Usage, mem)
            )
    end,
    ok.

usage_msg(Usage, cpu) ->
    %% CPUの場合はロードアベレージとして表示
    %% 大きな値にも対応するため、適切なフォーマットを使用
    case Usage of
        Val when is_integer(Val) ->
            iolist_to_binary(io_lib:format("~p load average", [Val]));
        Val when is_float(Val) ->
            iolist_to_binary(io_lib:format("~.2f load average", [Val]));
        _ ->
            iolist_to_binary(io_lib:format("~p load average", [Usage]))
    end;
usage_msg(Usage, What) ->
    %% その他の場合はパーセンテージとして表示
    iolist_to_binary(io_lib:format("~.2f% ~p usage", [Usage / 1.0, What])).

update_memory_protect_threshold(New) ->
    LCConfig = load_ctl:get_config(),
    load_ctl:put_config(LCConfig#{memory_threshold := New}).
