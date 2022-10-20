%%%-------------------------------------------------------------------
%% @doc router_cli_migration
%% @end
%%%-------------------------------------------------------------------
-module(router_cli_migration).

-behavior(clique_handler).

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
            "migration oui    - Migrate OUI \n",
            "    [--print json / normal] default: json\n",
            "    [--no_euis] default: false (EUIs included)\n",
            "    [--max_copies 1] default: 1\n"
        ]
    ].

info_cmd() ->
    [
        [
            ["migration", "oui"],
            [],
            [
                {print, [{longname, "print"}]},
                {no_euis, [{longname, "no_euis"}, {datatype, boolean}]},
                {max_copies, [{longmame, "max_copies"}, {datatype, integer}]}
            ],
            fun migration_oui/3
        ]
    ].

migration_oui(["migration", "oui"], [], Flags) ->
    Options = maps:from_list(Flags),
    case create_migration_oui_map(Options) of
        {error, Reason} ->
            c_text("Error ~p~n", [Reason]);
        {ok, Map} ->
            migration_oui(Map, Options)
    end;
migration_oui([_, _, _], [], _Flags) ->
    usage.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec create_migration_oui_map(Options :: map()) -> {ok, map()} | {error, any()}.
create_migration_oui_map(Options) ->
    OUI = router_utils:get_oui(),
    Chain = router_utils:get_blockchain(),
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_routing(OUI, Ledger) of
        {error, _} ->
            {error, oui_not_found};
        {ok, RoutingEntry} ->
            case get_grpc_address() of
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
                    Map = #{
                        oui => OUI,
                        owner_wallet_id => erlang:list_to_binary(libp2p_crypto:bin_to_b58(Owner)),
                        payer_wallet_id => erlang:list_to_binary(libp2p_crypto:bin_to_b58(Owner)),
                        routes => [
                            #{
                                devaddr_ranges => DevAddrRanges,
                                euis => EUIs,
                                net_id => erlang:list_to_binary(io_lib:format("~.16B", [IntNetID])),
                                oui => OUI,
                                server => #{
                                    host => Host,
                                    port => Port,
                                    protocol => #{
                                        type => <<"packet_router">>
                                    }
                                },
                                max_copies => maps:get(max_copies, Options, 1)
                            }
                        ]
                    },
                    {ok, Map}
            end
    end.

-spec migration_oui(Map :: map(), Options :: map()) -> clique_status:status().
migration_oui(Map, Options) ->
    case maps:get(print, Options, json) of
        json ->
            c_text("~n~nPLEASE VERIFY THAT ALL THE DATA MATCH~n~n~s~n", [
                jsx:prettify(jsx:encode(Map))
            ]);
        _ ->
            migrate_oui_print(Map)
    end.

-spec migrate_oui_print(Map :: map()) -> clique_status:status().
migrate_oui_print(Map) ->
    %% PLEASE VERIFY THAT ALL THE DATA MATCH
    %% OUI: 4
    %% Owner: XYZ
    %% Payer: XYZ
    %% Routes
    %%     Net ID: C00053
    %%     Server: localhost:8080
    %%     Protocol: gwmp
    %%     Max Copies: 1
    %%     DevAddrs (Start, End): 1
    %%         (Start, End)
    %%     EUIs (AppEUI, DevEUI): 1
    %%         (010203040506070809, 010203040506070809)
    %%     ################################################
    Disclamer = io_lib:format("~n~nPLEASE VERIFY THAT ALL THE DATA MATCH~n~n", []),
    OUI = io_lib:format("OUI: ~w~n", [maps:get(oui, Map)]),
    Owner = io_lib:format("Owner: ~s~n", [maps:get(owner_wallet_id, Map)]),
    Payer = io_lib:format("Payer: ~s~n", [maps:get(payer_wallet_id, Map)]),
    RouteSpacer = io_lib:format("    ################################################~n", []),
    Routes = lists:foldl(
        fun(Route, Acc) ->
            NetID = io_lib:format("    Net ID: ~s~n", [maps:get(net_id, Route)]),

            ServerMap = maps:get(server, Route),
            Server = io_lib:format("    Server: ~s:~w~n", [
                maps:get(host, ServerMap), maps:get(port, ServerMap)
            ]),

            ProtocolMap = maps:get(protocol, ServerMap),
            Protocol = io_lib:format("    Protocol: ~s~n", [maps:get(type, ProtocolMap)]),

            MaxCopies = io_lib:format("    Max Copies: ~w~n", [1]),

            DevAddrsCnt = io_lib:format("    DevAddrs (Start, End): ~w~n", [
                erlang:length(maps:get(devaddr_ranges, Route))
            ]),
            DevAddrs = lists:foldl(
                fun(#{start_addr := S, end_addr := E}, Acc1) ->
                    [io_lib:format("        (~s, ~s)~n", [S, E]) | Acc1]
                end,
                [],
                maps:get(devaddr_ranges, Route)
            ),

            EUISCnt = io_lib:format("    EUIs (AppEUI, DevEUI): ~w~n", [
                erlang:length(maps:get(euis, Route))
            ]),
            EUIS = lists:foldl(
                fun(#{app_eui := A, dev_eui := D}, Acc1) ->
                    [io_lib:format("        (~s, ~s)~n", [A, D]) | Acc1]
                end,
                [],
                maps:get(euis, Route)
            ),

            Acc ++ [NetID, Server, Protocol, MaxCopies, DevAddrsCnt] ++ DevAddrs ++ [EUISCnt] ++
                EUIS ++ [RouteSpacer]
        end,
        [io_lib:format("Routes~n", [])],
        maps:get(routes, Map)
    ),
    c_list([Disclamer, OUI, Owner, Payer] ++ Routes).

-spec euis() -> list(map()).
euis() ->
    Devices = router_device_cache:get(),
    lists:usort([
        #{
            app_eui => lorawan_utils:binary_to_hex(router_device:app_eui(D)),
            dev_eui => lorawan_utils:binary_to_hex(router_device:dev_eui(D))
        }
     || D <- Devices
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

-spec get_grpc_address() -> undefined | {ok, binary()}.
get_grpc_address() ->
    case
        lists:filter(
            fun libp2p_transport_tcp:is_public/1,
            libp2p_swarm:listen_addrs(blockchain_swarm)
        )
    of
        [] ->
            undefined;
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

-spec c_list(list(string())) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
