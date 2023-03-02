%%%-------------------------------------------------------------------
%% @doc router_cli_migration
%% @end
%%%-------------------------------------------------------------------
-module(router_cli_migration).

-behavior(clique_handler).

-include("../grpc/autogen/iot_config_pb.hrl").

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).
-define(DEFAULT_URL, "http://localhost:4000").

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [info_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [info_cmd()]
    ).

%%--------------------------------------------------------------------
%% info
%%--------------------------------------------------------------------

info_usage() ->
    [
        ["migration"],
        [
            "\n\n",
            "migration oui    - Print OUI migration \n",
            "    [--no_euis] default: false (EUIs included)\n",
            "    [--ignore_no_address] default: false\n"
            "migration ouis  \n",
            "migration euis   - Add Console EUIs to config service existing route\n",
            "    [--commit] default: false (compute delta and send to Config Service)\n",
            "migration skfs   - Add Session Keys to config service\n"
        ]
    ].

info_cmd() ->
    [
        [
            ["migration", "oui"],
            [],
            [
                {no_euis, [{longname, "no_euis"}, {datatype, boolean}]},
                {ignore_no_address, [{longname, "ignore_no_address"}, {datatype, boolean}]}
            ],
            fun migration_oui/3
        ],
        [
            ["migration", "ouis"],
            [],
            [],
            fun migration_ouis/3
        ],
        [
            ["migration", "euis"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun send_euis_to_config_service/3
        ],
        [
            ["migration", "skfs"],
            [],
            [],
            fun send_skfs_to_config_service/3
        ]
    ].

migration_oui(["migration", "oui"], [], Flags) ->
    Options = maps:from_list(Flags),
    case create_migration_oui_map(Options) of
        {error, Reason} ->
            c_text("Error ~p~n", [Reason]);
        {ok, Map} ->
            c_text("~n~s~n", [
                jsx:prettify(jsx:encode(Map))
            ])
    end;
migration_oui([_, _, _], [], _Flags) ->
    usage.

migration_ouis(["migration", "ouis"], [], _Flags) ->
    OUIsList = get_ouis(),
    c_text("~n~s~n", [jsx:prettify(jsx:encode(OUIsList))]);
migration_ouis([_, _, _], [], _Flags) ->
    usage.

send_euis_to_config_service(["migration", "euis"], [], Flags) ->
    Options = maps:from_list(Flags),
    Commit = maps:is_key(commit, Options),
    ok = router_ics_eui_worker:reconcile(self(), Commit),
    DryRun =
        case Commit of
            true -> "";
            false -> "DRY RUN"
        end,
    receive
        {router_ics_eui_worker, {ok, Added, Removed}} ->
            ToMap = fun(Pairs) ->
                lists:map(
                    fun(EUIPair) ->
                        AppEUI = lorawan_utils:binary_to_hex(<<
                            (EUIPair#iot_config_eui_pair_v1_pb.app_eui):64/integer-unsigned-big
                        >>),
                        DevEUI = lorawan_utils:binary_to_hex(<<
                            (EUIPair#iot_config_eui_pair_v1_pb.dev_eui):64/integer-unsigned-big
                        >>),
                        #{
                            app_eui => AppEUI,
                            dev_eui => DevEUI,
                            route_id => EUIPair#iot_config_eui_pair_v1_pb.route_id
                        }
                    end,
                    Pairs
                )
            end,
            case {ToMap(Added), ToMap(Removed)} of
                {[], []} ->
                    c_text("~s~n Nothing to do, everything is up to date", [DryRun]);
                {PrintAdded, PrintRemoved} ->
                    c_text("~s~nAdding~n~s~nRemoving~n~s~n", [DryRun, PrintAdded, PrintRemoved])
            end;
        {router_ics_eui_worker, {error, _Reason}} ->
            c_text("~s Updating EUIs failed ~p", [DryRun, _Reason])
    after 900000 ->
        c_text("Error timeout")
    end;
send_euis_to_config_service(A, B, C) ->
    io:format("~p Arguments:~n  ~p~n  ~p~n  ~p~n", [?FUNCTION_NAME, A, B, C]),
    usage.

send_skfs_to_config_service(["migration", "skfs"], [], _Flags) ->
    ok = router_ics_skf_worker:reconcile(self()),
    receive
        {router_ics_skf_worker, {ok, Added, Removed}} ->
            c_text("Updating SKFs: added ~w, remove ~w", [Added, Removed]);
        {router_ics_skf_worker, {error, _Reason}} ->
            c_text("Updating SKFs failed ~p", [_Reason])
    after 5000 ->
        c_text("Error timeout")
    end;
send_skfs_to_config_service(A, B, C) ->
    io:format("~p Arguments:~n  ~p~n  ~p~n  ~p~n", [?FUNCTION_NAME, A, B, C]),
    usage.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

get_ouis() ->
    lists:map(
        fun({OUI, RoutingV1}) ->
            Owner = blockchain_ledger_routing_v1:owner(RoutingV1),
            Routers = blockchain_ledger_routing_v1:addresses(RoutingV1),
            Payer =
                case Routers of
                    [] -> Owner;
                    [Router1 | _] -> Router1
                end,
            Prefix = $H,
            DevAddrRanges = lists:map(
                fun(<<Base:25, Mask:23>> = _Subnet) ->
                    Size = blockchain_ledger_routing_v1:subnet_mask_to_size(Mask),
                    Min = lorawan_utils:reverse(
                        <<Base:25/integer-unsigned-little, Prefix:7/integer>>
                    ),
                    Max = lorawan_utils:reverse(<<
                        (Base + Size - 1):25/integer-unsigned-little, Prefix:7/integer
                    >>),
                    #{start_addr => binary:encode_hex(Min), end_addr => binary:encode_hex(Max)}
                end,
                blockchain_ledger_routing_v1:subnets(RoutingV1)
            ),
            #{
                oui => OUI,
                owner => erlang:list_to_binary(libp2p_crypto:bin_to_b58(Owner)),
                payer => erlang:list_to_binary(libp2p_crypto:bin_to_b58(Payer)),
                delegate_keys => [
                    erlang:list_to_binary(libp2p_crypto:bin_to_b58(R))
                 || R <- Routers
                ],
                devaddrs => DevAddrRanges
            }
        end,
        router_blockchain:get_ouis()
    ).

-spec create_migration_oui_map(Options :: map()) -> {ok, map()} | {error, any()}.
create_migration_oui_map(Options) ->
    OUI = router_utils:get_oui(),
    case router_blockchain:routing_for_oui(OUI) of
        {error, _} ->
            {error, oui_not_found};
        {ok, RoutingEntry} ->
            case get_grpc_address(Options) of
                undefined ->
                    {error, address_not_found};
                {ok, GRPCAddress} ->
                    #{host := Host, port := Port} = uri_string:parse(GRPCAddress),
                    Owner = blockchain_ledger_routing_v1:owner(RoutingEntry),
                    {DevAddrRanges, IntNetID} = devaddr_ranges(RoutingEntry),
                    EUIs =
                        case maps:is_key(no_euis, Options) of
                            true -> [];
                            false -> euis()
                        end,
                    Payer = blockchain_swarm:pubkey_bin(),
                    Map = #{
                        oui => OUI,
                        payer => erlang:list_to_binary(libp2p_crypto:bin_to_b58(Owner)),
                        owner => erlang:list_to_binary(libp2p_crypto:bin_to_b58(Payer)),
                        routes => [
                            #{
                                devaddr_ranges => DevAddrRanges,
                                euis => EUIs,
                                net_id => erlang:list_to_binary(
                                    io_lib:format("~6.16.0B", [IntNetID])
                                ),
                                oui => OUI,
                                server => #{
                                    host => Host,
                                    port => Port,
                                    protocol => #{
                                        type => <<"packet_router">>
                                    }
                                },
                                max_copies => 1
                            }
                        ]
                    },
                    {ok, Map}
            end
    end.

-spec euis() -> list(map()).
euis() ->
    {ok, Devices} = router_console_api:get_json_devices(),
    lists:usort([
        #{
            app_eui => kvc:path([<<"app_eui">>], JSONDevice),
            dev_eui => kvc:path([<<"dev_eui">>], JSONDevice)
        }
     || JSONDevice <- Devices
    ]).

-spec devaddr_ranges(RoutingEntry :: blockchain_ledger_routing_v1:routing()) ->
    {list(map()), non_neg_integer()}.
devaddr_ranges(RoutingEntry) ->
    Subnets = blockchain_ledger_routing_v1:subnets(RoutingEntry),
    lists:foldl(
        fun(<<Base:25, Mask:23>>, {Acc, _}) ->
            Size = blockchain_ledger_routing_v1:subnet_mask_to_size(Mask),
            Prefix = $H,
            Min = lorawan_utils:reverse(<<Base:25/integer-unsigned-little, Prefix:7/integer>>),
            Max = lorawan_utils:reverse(<<
                (Base + Size):25/integer-unsigned-little, Prefix:7/integer
            >>),
            {ok, IntNetID} = lora_subnet:parse_netid(Min, big),
            {
                [#{start_addr => binary:encode_hex(Min), end_addr => binary:encode_hex(Max)} | Acc],
                IntNetID
            }
        end,
        {[], 0},
        Subnets
    ).

-spec get_grpc_address(Options :: map()) -> undefined | {ok, binary()}.
get_grpc_address(Options) ->
    case
        lists:filter(
            fun libp2p_transport_tcp:is_public/1,
            libp2p_swarm:listen_addrs(blockchain_swarm)
        )
    of
        [] ->
            case maps:is_key(ignore_no_address, Options) of
                false -> undefined;
                true -> {ok, <<"http://localhost:8080">>}
            end;
        [First | _] ->
            IP = lists:nth(2, string:tokens(First, "/")),
            {ok, Port} = application:get_env(router, grpc_port),
            RPCAddr = erlang:iolist_to_binary([
                "http://",
                IP,
                ":",
                erlang:integer_to_list(Port)
            ]),
            {ok, RPCAddr}
    end.

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
