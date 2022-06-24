%%%-------------------------------------------------------------------
%% @doc router_cli_hotspot_rep
%% @end
%%%-------------------------------------------------------------------
-module(router_cli_hotspot_rep).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [hotspot_rep_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [hotspot_rep_cmd()]
    ).

%%--------------------------------------------------------------------
%% hotspot_rep
%%--------------------------------------------------------------------

hotspot_rep_usage() ->
    [
        ["hotspot_rep"],
        [
            "\n\n",
            "hotspot_rep ls                           - Display all hotspots' reputation\n",
            "hotspot_rep <b58_hotspot_id>             - Display a hotspot's reputation\n",
            "hotspot_rep reset <b58_hotspot_id>       - Reset hotspot's reputation to 0\n",
            "hotspot_rep sc [--over 10] [--rep 10]    - Display hotspots in state channel going over X time the average (Default 10)\n"
        ]
    ].

hotspot_rep_cmd() ->
    [
        [["hotspot_rep", '*'], [], [], fun hotspot_rep_get/3],
        [["hotspot_rep", "reset", '*'], [], [], fun hotspot_rep_reset/3],
        [
            ["hotspot_rep", "sc"],
            [],
            [
                {over, [
                    {longname, "over"},
                    {datatype, integer}
                ]},
                {rep, [
                    {longname, "rep"},
                    {datatype, integer}
                ]}
            ],
            fun hotspot_rep_sc/3
        ]
    ].

hotspot_rep_get(["hotspot_rep", "ls"], [], []) ->
    List = ru_reputation:reputations(),
    c_table(format(List));
hotspot_rep_get(["hotspot_rep", B58], [], []) ->
    Hotspot = libp2p_crypto:b58_to_bin(B58),
    {PacketMissed, UnknownDevice} = ru_reputation:reputation(Hotspot),
    c_table(format([{Hotspot, PacketMissed, UnknownDevice}]));
hotspot_rep_get([_, _, _], [], []) ->
    usage.

hotspot_rep_reset(["hotspot_rep", "reset", B58], [], []) ->
    PubKeyBin = libp2p_crypto:b58_to_bin(B58),
    Name = blockchain_utils:addr2name(PubKeyBin),
    ok = ru_reputation:reset(PubKeyBin),
    c_text("Hotspot ~p (~p) reputation reseted", [Name, B58]);
hotspot_rep_reset([_, _, _], [], []) ->
    usage.

hotspot_rep_sc(["hotspot_rep", "sc"], [], Flags) ->
    TimeOverAvg = proplists:get_value(over, Flags, 10),
    ReputationOver = proplists:get_value(rep, Flags, 0),
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
                        {PacketMissed, PacketUnknownDevice} = ru_reputation:reputation(
                            PubKeyBin
                        ),
                        [
                            {name, erlang:list_to_binary(blockchain_utils:addr2name(PubKeyBin))},
                            {id, erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin))},
                            {dcs, blockchain_state_channel_summary_v1:num_dcs(Summary)},
                            {packets, blockchain_state_channel_summary_v1:num_packets(Summary)},
                            {reputation, PacketMissed + PacketUnknownDevice},
                            {packet_missed, PacketMissed},
                            {packet_unknown_device, PacketUnknownDevice},
                            {sc, erlang:list_to_binary(SCName)},
                            {sc_avg, erlang:round(maps:get(SCName, Avg))}
                        ]
                    end,
                    FilteredSummaries
                )
            end,
            ActiveSCs
        )
    ),
    FilteredList = lists:filter(
        fun(H) -> proplists:get_value(reputation, H) >= ReputationOver end,
        HotspotList
    ),
    SortedList = lists:sort(
        fun(A, B) ->
            proplists:get_value(dcs, A) >
                proplists:get_value(dcs, B)
        end,
        FilteredList
    ),
    c_table(SortedList);
hotspot_rep_sc([_, _, _], [], []) ->
    usage.

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

-spec format(list()) -> list(list()).
format(List) ->
    lists:sort(
        fun(A, B) ->
            proplists:get_value(reputation, A) >
                proplists:get_value(reputation, B)
        end,
        lists:map(
            fun({PubKeyBin, PacketMissed, PacketUnknownDevice}) ->
                [
                    {name, blockchain_utils:addr2name(PubKeyBin)},
                    {b58, libp2p_crypto:bin_to_b58(PubKeyBin)},
                    {reputation, PacketMissed + PacketUnknownDevice},
                    {packet_missed, PacketMissed},
                    {packet_unknown_device, PacketUnknownDevice}
                ]
            end,
            List
        )
    ).

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
