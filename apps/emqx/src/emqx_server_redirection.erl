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

-module(emqx_server_redirection).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("emqx/include/logger.hrl").

-behaviour(gen_server).
-behaviour(emqx_config_handler).

%% API
-export([
    start_link/0,
    enable/1,
    disable/0,
    get_status/0,
    get_redirect_server/0,
    get_cluster_server_references/0,
    get_node_server_reference/1,
    get_node_listener_info/1,
    find_mqtt_listener/1,
    is_mqtt_listener/1,
    parse_bind_address/1,
    format_server_reference/1
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

%% emqx_config_handler callbacks
-export([
    pre_config_update/3,
    post_config_update/5
]).

%% Hooks
-export([
    on_connect/2,
    on_connack/3
]).

-record(state, {
    enabled = false :: boolean(),
    redirect_servers = [] :: list(),
    redirect_strategy = random :: random | round_robin,
    max_connections = 1000 :: non_neg_integer(),
    current_connections = 0 :: non_neg_integer(),
    round_robin_index = 0 :: non_neg_integer()
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

enable(Options) ->
    gen_server:call(?MODULE, {enable, Options}).

disable() ->
    gen_server:call(?MODULE, disable).

get_status() ->
    gen_server:call(?MODULE, get_status).

get_redirect_server() ->
    gen_server:call(?MODULE, get_redirect_server).

%%--------------------------------------------------------------------
%% Hooks
%%--------------------------------------------------------------------

on_connect(_ConnInfo, _Props) ->
    case get_status() of
        #{enabled := true, current_connections := Current, max_connections := Max} when
            Current >= Max
        ->
            {stop, {error, ?RC_USE_ANOTHER_SERVER}};
        _ ->
            ignore
    end.

on_connack(
    #{proto_name := <<"MQTT">>, proto_ver := ?MQTT_PROTO_V5},
    use_another_server,
    Props
) ->
    case get_redirect_server() of
        {ok, ServerReference} ->
            {ok, Props#{'Server-Reference' => ServerReference}};
        {error, _} ->
            {ok, Props}
    end;
on_connack(_ClientInfo, _Reason, Props) ->
    {ok, Props}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

enable_redirection(Options, State) ->
    try
        Servers = maps:get(redirect_servers, Options, []),
        Strategy = maps:get(redirect_strategy, Options, random),
        MaxConn = maps:get(max_connections, Options, 1000),

        case validate_servers(Servers) of
            ok ->
                hook(),
                {ok, State#state{
                    enabled = true,
                    redirect_servers = Servers,
                    redirect_strategy = Strategy,
                    max_connections = MaxConn
                }};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        _:Error ->
            {error, Error}
    end.

disable_redirection(State) ->
    try
        unhook(),
        {ok, State#state{enabled = false}}
    catch
        _:Error ->
            {error, Error}
    end.

validate_servers([]) ->
    {error, "No redirect servers configured"};
validate_servers(Servers) when is_list(Servers) ->
    case lists:all(fun validate_server/1, Servers) of
        true -> ok;
        false -> {error, "Invalid server configuration"}
    end;
validate_servers(_) ->
    {error, "Invalid servers format"}.

validate_server(#{host := Host, port := Port}) when
    is_binary(Host), is_integer(Port), Port > 0, Port =< 65535
->
    true;
validate_server(_) ->
    false.

select_redirect_server(random, Servers) ->
    case Servers of
        [] -> {error, "No servers available"};
        _ -> {ok, lists:nth(rand:uniform(length(Servers)), Servers)}
    end;
select_redirect_server(round_robin, Servers) ->
    case Servers of
        [] ->
            {error, "No servers available"};
        _ ->
            State = get_status(),
            Index = maps:get(round_robin_index, State, 0) rem length(Servers) + 1,
            {ok, lists:nth(Index, Servers)}
    end.

format_server_reference(#{host := Host, port := Port}) ->
    case is_ipv6_address(Host) of
        true ->
            <<"[", Host/binary, "]:", (integer_to_binary(Port))/binary>>;
        false ->
            <<Host/binary, ":", (integer_to_binary(Port))/binary>>
    end.

is_ipv6_address(Host) ->
    case inet:parse_address(unicode:characters_to_list(Host)) of
        {ok, {_, _, _, _, _, _, _, _}} -> true;
        _ -> false
    end.

%%--------------------------------------------------------------------
%% Cluster node information functions
%%--------------------------------------------------------------------

get_cluster_server_references() ->
    try
        Nodes = emqx:running_nodes(),
        ?SLOG(debug, #{msg => "get_cluster_server_references_called", nodes => Nodes}),
        ServerRefs = lists:filtermap(fun get_node_server_reference/1, Nodes),
        ?SLOG(debug, #{msg => "get_cluster_server_references_result", server_refs => ServerRefs}),
        ServerRefs
    catch
        Error:Reason ->
            ?SLOG(error, #{
                msg => "get_cluster_server_references_error", error => Error, reason => Reason
            }),
            []
    end.

get_node_server_reference(Node) ->
    try
        ?SLOG(debug, #{msg => "get_node_server_reference_called", node => Node}),
        case get_node_listener_info(Node) of
            {ok, Listeners} ->
                ?SLOG(debug, #{
                    msg => "get_node_listener_info_success", node => Node, listeners => Listeners
                }),
                case find_mqtt_listener(Listeners) of
                    {ok, {Host, Port}} ->
                        ServerRef = format_server_reference(#{host => Host, port => Port}),
                        ?SLOG(debug, #{
                            msg => "get_node_server_reference_success",
                            node => Node,
                            host => Host,
                            port => Port,
                            server_ref => ServerRef
                        }),
                        {true, ServerRef};
                    Error1 ->
                        ?SLOG(debug, #{
                            msg => "find_mqtt_listener_failed", node => Node, error => Error1
                        }),
                        false
                end;
            Error2 ->
                ?SLOG(debug, #{
                    msg => "get_node_listener_info_failed", node => Node, error => Error2
                }),
                false
        end
    catch
        Error3:Reason ->
            ?SLOG(error, #{
                msg => "get_node_server_reference_error",
                node => Node,
                error => Error3,
                reason => Reason
            }),
            false
    end.

get_node_listener_info(Node) ->
    try
        case rpc:call(Node, emqx_listeners, list, [], 5000) of
            {badrpc, _} -> {error, rpc_failed};
            Listeners -> {ok, Listeners}
        end
    catch
        _:_ ->
            {error, rpc_failed}
    end.

find_mqtt_listener(Listeners) ->
    case lists:search(fun is_mqtt_listener/1, Listeners) of
        {value, {_Type, #{bind := Bind}}} ->
            parse_bind_address(Bind);
        _ ->
            {error, not_found}
    end.

is_mqtt_listener({Type, _Config}) when Type =:= 'tcp:default'; Type =:= 'ssl:default' -> true;
is_mqtt_listener(_) -> false.

parse_bind_address({IP, Port}) when is_tuple(IP), is_integer(Port) ->
    Host = list_to_binary(inet:ntoa(IP)),
    {ok, {Host, Port}};
parse_bind_address(_) ->
    {error, invalid_format}.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, #state{}}.

handle_call({enable, Options}, _From, State) ->
    case enable_redirection(Options, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(disable, _From, State) ->
    case disable_redirection(State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(get_status, _From, State) ->
    Status = #{
        enabled => State#state.enabled,
        redirect_servers => State#state.redirect_servers,
        redirect_strategy => State#state.redirect_strategy,
        max_connections => State#state.max_connections,
        current_connections => State#state.current_connections,
        round_robin_index => State#state.round_robin_index
    },
    {reply, Status, State};
handle_call(get_redirect_server, _From, State) ->
    case State#state.enabled of
        true ->
            case
                select_redirect_server(State#state.redirect_strategy, State#state.redirect_servers)
            of
                {ok, Server} ->
                    ServerRef = format_server_reference(Server),
                    {reply, {ok, ServerRef}, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        false ->
            {reply, {error, "Server redirection is disabled"}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    unhook(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% emqx_config_handler callbacks
%%--------------------------------------------------------------------

pre_config_update(server_redirection, Config, _OldConfig) ->
    {ok, Config}.

post_config_update(server_redirection, _Request, _NewConfig, _OldConfig, _AppEnvs) ->
    {ok, []}.

%%--------------------------------------------------------------------
%% Hook management
%%--------------------------------------------------------------------

hook() ->
    emqx_hooks:add('client.connect', {?MODULE, on_connect, []}, 100),
    emqx_hooks:add('client.connack', {?MODULE, on_connack, []}, 100).

unhook() ->
    emqx_hooks:del('client.connect', {?MODULE, on_connect, []}),
    emqx_hooks:del('client.connack', {?MODULE, on_connack, []}).
