%%%-------------------------------------------------------------------
%% @doc router_cli_hotspot_deny_list
%% @end
%%%-------------------------------------------------------------------
-module(router_cli_hotspot_deny_list).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [hotspot_deny_list_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [hotspot_deny_list_cmd()]
    ).

%%--------------------------------------------------------------------
%% hotspot_deny_list
%%--------------------------------------------------------------------

hotspot_deny_list_usage() ->
    [
        ["hotspot_deny_list"],
        [
            "\n\n",
            "NOTE: any add or remove also needs to be done in config file to persist restart",
            "\n\n",
            "hotspot_deny_list ls                         - Display all hotspots in deny list\n",
            "hotspot_deny_list add <b58_hotspot_id>       - Add hotspot to deny list\n",
            "hotspot_deny_list remote <b58_hotspot_id>    - Remove hotspot from deny list\n"
        ]
    ].

hotspot_deny_list_cmd() ->
    [
        [["hotspot_deny_list", "ls"], [], [], fun hotspot_deny_list_ls/3],
        [["hotspot_deny_list", "add", '*'], [], [], fun hotspot_deny_list_add/3],
        [["hotspot_deny_list", "remove", '*'], [], [], fun hotspot_deny_list_remove/3]
    ].

hotspot_deny_list_ls(["hotspot_deny_list", "ls"], [], []) ->
    case router_hotspot_deny_list:enabled() of
        false ->
            c_text("Hotspot Deny List disabled");
        true ->
            DenyList = router_hotspot_deny_list:ls(),
            c_table(format_deny_list(DenyList))
    end;
hotspot_deny_list_ls([_, _, _], [], []) ->
    usage.

hotspot_deny_list_add(["hotspot_deny_list", "add", B58], [], []) ->
    case router_hotspot_deny_list:enabled() of
        false ->
            c_text("Hotspot Deny List disabled");
        true ->
            PubKeyBin = libp2p_crypto:b58_to_bin(B58),
            ok = router_hotspot_deny_list:deny(PubKeyBin),
            Name = blockchain_utils:addr2name(PubKeyBin),
            c_text("Hotspot ~p (~p) added to Deny List", [Name, B58])
    end;
hotspot_deny_list_add([_, _, _], [], []) ->
    usage.

hotspot_deny_list_remove(["hotspot_deny_list", "remove", B58], [], []) ->
    case router_hotspot_deny_list:enabled() of
        false ->
            c_text("Hotspot Deny List disabled");
        true ->
            PubKeyBin = libp2p_crypto:b58_to_bin(B58),
            ok = router_hotspot_deny_list:approve(PubKeyBin),
            Name = blockchain_utils:addr2name(PubKeyBin),
            c_text("Hotspot ~p (~p) removed from Deny List", [Name, B58])
    end;
hotspot_deny_list_remove([_, _, _], [], []) ->
    usage.

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

-spec format_deny_list(list()) -> list(list()).
format_deny_list(DenyList) ->
    lists:map(
        fun({PubKeyBin, _}) ->
            [
                {b58, libp2p_crypto:bin_to_b58(PubKeyBin)},
                {name, blockchain_utils:addr2name(PubKeyBin)}
            ]
        end,
        DenyList
    ).

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
