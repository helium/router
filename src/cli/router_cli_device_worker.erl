-module(router_cli_device_worker).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [device_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [device_cmd()]
    ).

%%--------------------------------------------------------------------
%% device
%%--------------------------------------------------------------------

device_usage() ->
    [
     ["device"],
     [
      "Device commands\n\n",
      "  none yet. Stay tuned"
     ]
    ].

device_cmd() ->
    [
     [["device"], [], [], ?USAGE],
     [["device", "one"], [], [], fun first/3]
    ].

first(["device", "one"], [], []) ->
    c_text("What's up michael").


-spec c_list(list()) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
