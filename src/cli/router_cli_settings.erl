-module(router_cli_settings).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [settings_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [settings_cmd()]
    ).

%%--------------------------------------------------------------------
%% settings
%%--------------------------------------------------------------------

settings_usage() ->
    [
        ["settings"],
        [
            "\n\n"
            "log <level>         - lager:set_loglevel(lager_file_backend, \"router.log\", <level>)"
            "set <field> <value> - application:set_env(router, <field>, <value>)"
        ]
    ].

settings_cmd() ->
    [
        [["settings"], [], [], ?USAGE],
        [["settings", "log", '*'], [], [], fun set_log_level/3],
        [["settings", "set", '*', '*'], [], fun set_application_env/3]
    ].

%%--------------------------------------------------------------------
%% settings log
%%--------------------------------------------------------------------

set_log_level(["settings", "log", Level], [], []) ->
    case Level of
        "debug" -> lager:set_loglevel(lager_file_backend, "router.log", debug);
        "info" -> lager:set_loglevel(lager_file_backend, "router.log", info);
        "warning" -> lager:set_loglevel(lager_file_backend, "router.log", warning);
        "error" -> lager:set_loglevel(lager_file_backend, "router.log", error);
        _ -> [clique_status:text([io_lib:format("~p unsupported log level~n", [Level])])]
    end.

%%--------------------------------------------------------------------
%% settings set
%%--------------------------------------------------------------------

set_application_env(["settings", "set", Field, Value], [], []) ->
    Settings = application:get_all_env(router),
    Keys = lists:map(fun erlang:atom_to_list/1, proplists:get_keys(Settings)),
    case lists:member(Field, Keys) of
        true ->
            FieldAtom = erlang:list_to_existing_atom(Field),
            {ok, OldVal} = application:get_env(router, FieldAtom),
            application:set_env(router, FieldAtom, Value),
            [clique_status:text([io_lib:format("~p from ~p to ~p~n", [Field, OldVal, Value])])];
        false ->
            [clique_status:text([io_lib:format("~p not an application setting~n", [Field])])]
    end.
