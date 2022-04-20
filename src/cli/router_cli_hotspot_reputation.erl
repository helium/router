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
            "hotspot_reputation reset <b58_hotspot_id>    - Reset hotspot's reputation to 0\n",
            "hotspot_reputation sc [--over 10]            - Display hotspots in state channel going over X time the average (Default 10)\n"
        ]
    ].

hotspot_reputation_cmd() ->
    [
        [["hotspot_reputation", '*'], [], [], fun hotspot_reputation_get/3],
        [["hotspot_reputation", "reset", '*'], [], [], fun hotspot_reputation_reset/3],
        [
            ["hotspot_reputation", "sc"],
            [],
            [
                {over, [
                    {longname, "over"},
                    {datatype, integer}
                ]}
            ],
            fun hotspot_reputation_sc/3
        ]
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
            Reputation = router_hotspot_reputation:reputation(Hotspot),
            c_table(format([{Hotspot, Reputation}]))
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

hotspot_reputation_sc(["hotspot_reputation", "sc"], [], Flags) ->
    TimeOverAvg = proplists:get_value(over, Flags, 10),
    ActiveSCs = maps:values(blockchain_state_channels_server:get_actives()),
    Avg = maps:from_list(
        lists:map(
            fun({SC, _SCState, _Pid}) ->
                TotalDcs = blockchain_state_channel_v1:total_dcs(SC),
                case erlang:length(blockchain_state_channel_v1:summaries(SC)) of
                    0 ->
                        {blockchain_state_channel_v1:name(SC), 0};
                    Actors ->
                        {blockchain_state_channel_v1:name(SC), TotalDcs / Actors}
                end
            end,
            ActiveSCs
        )
    ),
    HotspotList = lists:concat(
        lists:map(
            fun({SC, _SCState, _Pid}) ->
                SCName = blockchain_state_channel_v1:name(SC),
                FilteredSummaries = lists:filter(
                    fun(Summary) ->
                        blockchain_state_channel_summary_v1:num_dcs(Summary) >=
                            TimeOverAvg * maps:get(blockchain_state_channel_v1:name(SC), Avg)
                    end,
                    blockchain_state_channel_v1:summaries(SC)
                ),
                lists:map(
                    fun(Summary) ->
                        PubKeyBin = blockchain_state_channel_summary_v1:client_pubkeybin(Summary),
                        [
                            {hotspot_name,
                                erlang:list_to_binary(blockchain_utils:addr2name(PubKeyBin))},
                            {hotspot_id,
                                erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin))},
                            {hotspot_dcs, blockchain_state_channel_summary_v1:num_dcs(Summary)},
                            {hotspot_packets,
                                blockchain_state_channel_summary_v1:num_packets(Summary)},
                            {hotspot_reputation, router_hotspot_reputation:reputation(PubKeyBin)},
                            {state_channel, erlang:list_to_binary(SCName)},
                            {state_channel_avg, maps:get(SCName, Avg)},
                            {state_channel_base64,
                                base64:encode(blockchain_state_channel_v1:id(SC))}
                        ]
                    end,
                    FilteredSummaries
                )
            end,
            ActiveSCs
        )
    ),
    lists:sort(
        fun(A, B) ->
            proplists:get_value(hotspot_dcs, A) >
                proplists:get_value(hotspot_dcs, B)
        end,
        HotspotList
    );
hotspot_reputation_sc([_, _, _], [], []) ->
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
