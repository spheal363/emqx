%%--------------------------------------------------------------------
%% EMQX Dashboard Publisher Stats API
%%--------------------------------------------------------------------
-module(emqx_dashboard_publisher_stats_api).
-behaviour(minirest_api).

-export([api_spec/0, paths/0, schema/1, get_publisher_stats/2]).

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true, translate_body => true}).

paths() ->
    [
        "/publisher_stats",
        "/publisher_stats/:clientid"
    ].

schema("/publisher_stats") ->
    #{
        'operationId' => get_publisher_stats,
        get => #{
            tags => [<<"Publisher Stats">>],
            description => <<"Get all publisher statistics">>,
            responses => #{
                200 => #{
                    description => <<"Publisher statistics">>,
                    content => #{
                        'application/json' => #{
                            schema => #{
                                type => object,
                                properties => #{
                                    data => #{
                                        type => array,
                                        items => #{
                                            type => object,
                                            properties => #{
                                                clientid => #{type => string},
                                                publish_count => #{type => integer},
                                                timestamp => #{type => integer},
                                                topic => #{type => string}
                                            }
                                        },
                                        description => <<"Publisher statistics data">>
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    };
schema("/publisher_stats/:clientid") ->
    #{
        'operationId' => get_publisher_stats,
        get => #{
            tags => [<<"Publisher Stats">>],
            description => <<"Get publisher statistics by client ID">>,
            responses => #{
                200 => #{
                    description => <<"Publisher statistics">>,
                    content => #{
                        'application/json' => #{
                            schema => #{
                                type => object,
                                properties => #{
                                    data => #{
                                        type => array,
                                        items => #{
                                            type => object,
                                            properties => #{
                                                clientid => #{type => string},
                                                publish_count => #{type => integer},
                                                timestamp => #{type => integer},
                                                topic => #{type => string}
                                            }
                                        },
                                        description => <<"Publisher statistics data">>
                                    }
                                }
                            }
                        }
                    }
                },
                400 => #{
                    description => <<"Bad request">>,
                    content => #{
                        'application/json' => #{
                            schema => #{
                                type => object,
                                properties => #{
                                    code => #{
                                        type => string,
                                        description => <<"Error code">>
                                    },
                                    message => #{
                                        type => string,
                                        description => <<"Error message">>
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }.

get_publisher_stats(get, #{bindings := #{}}) ->
    %% 全Publisher
    Stats = emqx_publisher_stats:get_publisher_stats(),
    %% binary型をstring型に変換
    ConvertedStats = lists:map(
        fun(Stat) ->
            Stat#{
                clientid => unicode:characters_to_list(maps:get(clientid, Stat)),
                topic => unicode:characters_to_list(maps:get(topic, Stat))
            }
        end,
        Stats
    ),
    {200, #{data => ConvertedStats}};
get_publisher_stats(get, #{bindings := #{clientid := ClientId}}) ->
    %% 特定Publisher
    Stats = emqx_publisher_stats:get_publisher_stats(list_to_binary(ClientId)),
    %% binary型をstring型に変換
    ConvertedStats = lists:map(
        fun(Stat) ->
            Stat#{
                clientid => unicode:characters_to_list(maps:get(clientid, Stat)),
                topic => unicode:characters_to_list(maps:get(topic, Stat))
            }
        end,
        Stats
    ),
    {200, #{data => ConvertedStats}};
get_publisher_stats(get, _) ->
    {400, #{code => 'BAD_REQUEST', message => <<"Invalid request">>}}.
