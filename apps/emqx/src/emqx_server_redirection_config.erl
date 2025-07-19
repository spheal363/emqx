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

-module(emqx_server_redirection_config).

-include_lib("emqx/include/logger.hrl").

-export([
    load/0,
    update/1,
    get_config/0,
    add_handler/0,
    remove_handler/0,
    post_config_update/5
]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

load() ->
    case emqx:get_config([server_redirection]) of
        undefined ->
            ?SLOG(debug, #{msg => "server_redirection_config_not_found"}),
            ok;
        Config ->
            case maps:get(enable, Config, false) of
                true ->
                    Options = #{
                        redirect_servers => maps:get(redirect_servers, Config, []),
                        redirect_strategy => maps:get(redirect_strategy, Config, random),
                        max_connections => maps:get(max_connections, Config, 1000)
                    },
                    case emqx_server_redirection:enable(Options) of
                        ok ->
                            ?SLOG(info, #{
                                msg => "server_redirection_enabled",
                                config => emqx_utils:redact(Config)
                            });
                        {error, Reason} ->
                            ?SLOG(error, #{
                                msg => "server_redirection_enable_failed",
                                reason => Reason,
                                config => emqx_utils:redact(Config)
                            })
                    end;
                false ->
                    ?SLOG(debug, #{msg => "server_redirection_disabled"})
            end
    end.

update(Config) ->
    case maps:get(enable, Config, false) of
        true ->
            Options = #{
                redirect_servers => maps:get(redirect_servers, Config, []),
                redirect_strategy => maps:get(redirect_strategy, Config, random),
                max_connections => maps:get(max_connections, Config, 1000)
            },
            case emqx_server_redirection:enable(Options) of
                ok ->
                    ?SLOG(info, #{
                        msg => "server_redirection_updated",
                        config => emqx_utils:redact(Config)
                    });
                {error, Reason} ->
                    ?SLOG(error, #{
                        msg => "server_redirection_update_failed",
                        reason => Reason,
                        config => emqx_utils:redact(Config)
                    })
            end;
        false ->
            case emqx_server_redirection:disable() of
                ok ->
                    ?SLOG(info, #{msg => "server_redirection_disabled"});
                {error, Reason} ->
                    ?SLOG(error, #{
                        msg => "server_redirection_disable_failed",
                        reason => Reason
                    })
            end
    end.

get_config() ->
    case emqx_server_redirection:get_status() of
        #{enabled := true} = Status ->
            #{
                enable => true,
                redirect_servers => maps:get(redirect_servers, Status, []),
                redirect_strategy => maps:get(redirect_strategy, Status, random),
                max_connections => maps:get(max_connections, Status, 1000)
            };
        _ ->
            #{enable => false}
    end.

add_handler() ->
    ok = emqx_config_handler:add_handler([server_redirection], ?MODULE),
    ok.

remove_handler() ->
    ok = emqx_config_handler:remove_handler([server_redirection]),
    ok.

post_config_update([server_redirection], _Req, NewConf, _OldConf, _AppEnvs) ->
    update(NewConf),
    ok.
