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
            "    [--max_copies 1] default: 1\n",
            "    [--ignore_no_address] default: false\n"
            "migration ouis  \n"
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
                {max_copies, [{longmame, "max_copies"}, {datatype, integer}]},
                {ignore_no_address, [{longname, "ignore_no_address"}, {datatype, boolean}]}
            ],
            fun migration_oui/3
        ],
        [
            ["migration", "ouis"],
            [],
            [],
            fun migration_ouis/3
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

migration_ouis(["migration", "ouis"], [], _Flags) ->
    c_text("TODO ~n");
migration_ouis([_, _, _], [], _Flags) ->
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
                    Map = #{
                        oui => OUI,
                        owner_wallet_id => erlang:list_to_binary(libp2p_crypto:bin_to_b58(Owner)),
                        %% TODO: maybe set payer to Router's address?
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
    {ok, Devices} = get_devices(),
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

-spec get_devices() -> {ok, [map()]} | {error, any()}.
get_devices() ->
    {Endpoint, Token} = token_lookup(),
    api_get_devices(Endpoint, Token, [], undefined).

-spec api_get_devices(
    Endpoint :: binary(),
    Token :: binary(),
    AccDevices :: list(),
    ResourceID :: binary() | undefined
) -> {ok, [map()]} | {error, any()}.
api_get_devices(Endpoint, Token, AccDevices, ResourceID) ->
    Url =
        case ResourceID of
            undefined ->
                <<Endpoint/binary, "/api/router/devices">>;
            ResourceID when is_binary(ResourceID) ->
                <<Endpoint/binary, "/api/router/devices?after=", ResourceID/binary>>
        end,
    Opts = [
        with_body,
        {connect_timeout, timer:seconds(10)},
        {recv_timeout, timer:seconds(10)}
    ],
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, Opts) of
        {ok, 200, _Headers, Body} ->
            case jsx:decode(Body, [return_maps]) of
                #{<<"data">> := Devices, <<"after">> := NewResourceID} ->
                    api_get_devices(Endpoint, Token, AccDevices ++ Devices, NewResourceID);
                #{<<"data">> := Devices} ->
                    {ok, AccDevices ++ Devices}
            end;
        Other ->
            {error, Other}
    end.

-spec token_lookup() -> {Endpoint :: binary(), Token :: binary()}.
token_lookup() ->
    case ets:lookup(router_console_api_ets, token) of
        [] -> {<<>>, <<>>};
        [{token, {Endpoint, _Downlink, Token}}] -> {Endpoint, Token}
    end.

-spec c_list(list(string())) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).
