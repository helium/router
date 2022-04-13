%%%-------------------------------------------------------------------
%% @doc router_cli_hotspot_reputation
%% @end
%%%-------------------------------------------------------------------
-module(router_cli_hotspot_reputation).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [hotspot_reputation_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [hotspot_reputation_cmd()]
    ).

%%--------------------------------------------------------------------
%% hotspot_reputation
%%--------------------------------------------------------------------

hotspot_reputation_usage() ->
    [
        ["hotspot_reputation"],
        [
            "\n\n",
            "hotspot_reputation ls                        - Display all hotspots' reputation\n",
            "hotspot_reputation <b58_hotspot_id>          - Display a hotspot's reputation\n",
            "hotspot_reputation reset <b58_hotspot_id>    - Reset hotspot's reputation to 0\n"
        ]
    ].

hotspot_reputation_cmd() ->
    [
        [["hotspot_reputation", '*'], [], [], fun hotspot_reputation_get/3],
        [["hotspot_reputation", "reset", '*'], [], [], fun hotspot_reputation_reset/3]
    ].

hotspot_reputation_get(["hotspot_reputation", "ls"], [], []) ->
    case router_hotspot_reputation:enabled() of
        false ->
            c_text("Hotspot Reputation is disabled");
        true ->
            List = router_hotspot_reputation:reputations(),
            c_table(format(List))
    end;
hotspot_reputation_get(["hotspot_reputation", B58], [], []) ->
    case router_hotspot_reputation:enabled() of
        false ->
            c_text("Hotspot Reputation is disabled");
        true ->
            Hotspot = libp2p_crypto:b58_to_bin(B58),
            List = router_hotspot_reputation:reputation(Hotspot),
            c_table(format(List))
    end;
hotspot_reputation_get([_, _, _], [], []) ->
    usage.

hotspot_reputation_reset(["hotspot_reputation", "reset", B58], [], []) ->
    case router_hotspot_reputation:enabled() of
        false ->
            c_text("Hotspot Reputation is disabled");
        true ->
            PubKeyBin = libp2p_crypto:b58_to_bin(B58),
            Name = blockchain_utils:addr2name(PubKeyBin),
            ok = router_hotspot_reputation:reset(PubKeyBin),
            c_text("Hotspot ~p (~p) reputation reseted", [Name, B58])
    end;
hotspot_reputation_reset([_, _, _], [], []) ->
    usage.

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

-spec format(list()) -> list(list()).
format(List) ->
    lists:map(
        fun({PubKeyBin, Reputation}) ->
            [
                {name, blockchain_utils:addr2name(PubKeyBin)},
                {b58, libp2p_crypto:bin_to_b58(PubKeyBin)},
                {reputation, Reputation}
            ]
        end,
        List
    ).

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
