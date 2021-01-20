%%%-------------------------------------------------------------------
%% @doc
%% == Router xor filter worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_xor_filter_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(POST_INIT_TICK, post_init).
-define(POST_INIT_TIMER, 500).
-define(CHECK_FILTERS_TICK, check_filters).
-define(CHECK_FILTERS_TIMER, timer:minutes(10)).
-define(HASH_FUN, fun xxhash:hash64/1).
-define(SUBMIT_RESULT, submit_result).

-record(state, {
    chain :: undefined | blockchain:blockchain(),
    oui :: undefined | non_neg_integer(),
    pending_txns = #{} :: #{blockchain_txn:hash() => blockchain_txn_routing_v1:txn_routing()}
}).

-type device_dev_eui_app_eui() :: binary().

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ok = schedule_post_init(),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{chain = undefined} = State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            ok = schedule_post_init(),
            {noreply, State};
        Chain ->
            case router_utils:get_router_oui(Chain) of
                undefined ->
                    ok = schedule_post_init(),
                    {noreply, State};
                OUI ->
                    self() ! ?CHECK_FILTERS_TICK,
                    {noreply, State#state{chain = Chain, oui = OUI}}
            end
    end;
handle_info(
    ?CHECK_FILTERS_TICK,
    #state{chain = Chain, oui = OUI, pending_txns = Pendings} = State
) ->
    case should_update_filters(Chain, OUI) of
        noop ->
            lager:info("filters are still update to date"),
            ok = schedule_check_filters(),
            {noreply, State};
        {new, Routing, LeftOverBinDevices} ->
            lager:info("adding new filter"),
            {Filter, _} = xor16:new(LeftOverBinDevices, ?HASH_FUN),
            Txn = craft_new_filter_txn(Chain, OUI, Filter, Routing),
            Hash = submit_txn(Txn),
            lager:info("new filter txn submitted ~p", [
                lager:pr(Txn, blockchain_txn_routing_v1)
            ]),
            {noreply, State#state{pending_txns = maps:put(Hash, Txn, Pendings)}};
        {update, Routing, Index, LeftOverBinDevices} ->
            lager:info("updating filter @ index ~p", [Index]),
            {Filter, _} = xor16:new(LeftOverBinDevices, ?HASH_FUN),
            Txn = craft_update_filter_txn(Chain, OUI, Filter, Routing, Index),
            Hash = submit_txn(Txn),
            lager:info("updating filter txn submitted ~p", [
                lager:pr(Txn, blockchain_txn_routing_v1)
            ]),
            {noreply, State#state{pending_txns = maps:put(Hash, Txn, Pendings)}}
    end;
handle_info(
    {?SUBMIT_RESULT, Hash, Return},
    #state{pending_txns = Pendings} = State
) ->
    Txn = maps:get(Hash, Pendings),
    case Return of
        ok ->
            lager:info("successfully submitted txn: ~p", [
                lager:pr(Txn, blockchain_txn_routing_v1)
            ]),
            %% Transaction submitted successfully so we are scheduling next check normally
            %% and incrementing Index if need bed
            ok = schedule_check_filters(),
            {noreply, State#state{pending_txns = maps:remove(Hash, Pendings)}};
        _ ->
            lager:error("failed to submit txn: ~p / ~p", [
                lager:pr(Txn, blockchain_txn_routing_v1),
                Return
            ]),
            %% Transaction failed so we are scheduling next check right away to try to correct
            %% We are still cleaning txn to avoid conflicts
            self() ! ?CHECK_FILTERS_TICK,
            {noreply, State#state{pending_txns = maps:remove(Hash, Pendings)}}
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec should_update_filters(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer()
) ->
    noop
    | {new, blockchain_ledger_routing_v1:routing(), list(device_dev_eui_app_eui())}
    | {update, blockchain_ledger_routing_v1:routing(), non_neg_integer(),
        list(device_dev_eui_app_eui())}.
should_update_filters(Chain, OUI) ->
    case router_console_device_api:get_all_devices() of
        {error, _Reason} ->
            lager:error("failed to get device ~p", [_Reason]),
            noop;
        {ok, Devices} ->
            DeviceDevEuiAppEuis = [
                <<(router_device:dev_eui(D))/binary, (router_device:app_eui(D))/binary>>
                || D <- Devices
            ],
            Ledger = blockchain:ledger(Chain),
            {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),
            BinFilters = blockchain_ledger_routing_v1:filters(Routing),
            ContainedMap = contained_map(DeviceDevEuiAppEuis, BinFilters),
            case maps:get(0, ContainedMap, []) of
                [] ->
                    noop;
                LeftOverDeviceDevEuiAppEuis ->
                    {ok, MaxXorFilter} = blockchain:config(max_xor_filter_num, Ledger),
                    case erlang:length(BinFilters) < MaxXorFilter of
                        true ->
                            {new, Routing, LeftOverDeviceDevEuiAppEuis};
                        false ->
                            {Index, SmallestDeviceDevEuiAppEuis} = find_smallest(ContainedMap),
                            {update, Routing, Index,
                                LeftOverDeviceDevEuiAppEuis ++ SmallestDeviceDevEuiAppEuis}
                    end
            end
    end.

%% Return a map of device_dev_eui_app_eui indexed by their filter (0 if not found)
-spec contained_map(
    DeviceDevEuiAppEuis :: list(device_dev_eui_app_eui()),
    BinFilters :: list(binary())
) -> #{non_neg_integer() => list(device_dev_eui_app_eui())}.
contained_map(DeviceDevEuiAppEuis, BinFilters) ->
    BinFiltersWithIndex = lists:zip(lists:seq(1, erlang:length(BinFilters)), BinFilters),
    lists:foldl(
        fun(BinDevice, Acc) ->
            case
                lists:foldl(
                    fun
                        ({_Index, _Filter}, {true, _} = True) ->
                            True;
                        ({Index, Filter}, _) ->
                            case xor16:contain({Filter, ?HASH_FUN}, BinDevice) of
                                true -> {true, Index};
                                false -> false
                            end
                    end,
                    false,
                    BinFiltersWithIndex
                )
            of
                false ->
                    maps:put(0, maps:get(0, Acc, []) ++ [BinDevice], Acc);
                {true, Index} ->
                    maps:put(Index, maps:get(Index, Acc, []) ++ [BinDevice], Acc)
            end
        end,
        #{},
        DeviceDevEuiAppEuis
    ).

-spec find_smallest(ContainedMap :: #{non_neg_integer() => list(device_dev_eui_app_eui())}) ->
    {non_neg_integer(), list(device_dev_eui_app_eui())}.
find_smallest(ContainedMap) ->
    ContainedMap1 = maps:remove(0, ContainedMap),
    [{Index, LeftOver} | _] = lists:sort(
        fun({_, A}, {_, B}) ->
            erlang:length(A) < erlang:length(B)
        end,
        maps:to_list(ContainedMap1)
    ),
    {Index, LeftOver}.

-spec craft_new_filter_txn(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference(),
    Routing :: blockchain_ledger_routing_v1:routing()
) -> blockchain_txn_routing_v1:txn_routing().
craft_new_filter_txn(Chain, OUI, Filter, Routing) ->
    {ok, PubKey, SignFun, _} = blockchain_swarm:keys(),
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Txn0 = blockchain_txn_routing_v1:new_xor(
        OUI,
        libp2p_crypto:pubkey_to_bin(PubKey),
        BinFilter,
        blockchain_ledger_routing_v1:nonce(Routing) + 1
    ),
    Fees = blockchain_txn_routing_v1:calculate_fee(Txn0, Chain),
    Txn1 = blockchain_txn_routing_v1:fee(Txn0, Fees),
    blockchain_txn_routing_v1:sign(Txn1, SignFun).

-spec craft_update_filter_txn(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference(),
    Routing :: blockchain_ledger_routing_v1:routing(),
    Index :: non_neg_integer()
) -> blockchain_txn_routing_v1:txn_routing().
craft_update_filter_txn(Chain, OUI, Filter, Routing, Index) ->
    {ok, PubKey, SignFun, _} = blockchain_swarm:keys(),
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Txn0 = blockchain_txn_routing_v1:update_xor(
        OUI,
        libp2p_crypto:pubkey_to_bin(PubKey),
        Index,
        BinFilter,
        blockchain_ledger_routing_v1:nonce(Routing) + 1
    ),
    Fees = blockchain_txn_routing_v1:calculate_fee(Txn0, Chain),
    Txn1 = blockchain_txn_routing_v1:fee(Txn0, Fees),
    blockchain_txn_routing_v1:sign(Txn1, SignFun).

-spec submit_txn(Txn :: blockchain_txn_routing_v1:txn_routing()) -> blockchain_txn:hash().
submit_txn(Txn) ->
    Hash = blockchain_txn_routing_v1:hash(Txn),
    Self = self(),
    Callback = fun(Return) -> Self ! {?SUBMIT_RESULT, Hash, Return} end,
    ok = blockchain_worker:submit_txn(Txn, Callback),
    Hash.

-spec schedule_post_init() -> ok.
schedule_post_init() ->
    {ok, _} = timer:send_after(?POST_INIT_TIMER, self(), ?POST_INIT_TICK),
    ok.

-spec schedule_check_filters() -> ok.
schedule_check_filters() ->
    {ok, _} = timer:send_after(?CHECK_FILTERS_TIMER, self(), ?CHECK_FILTERS_TICK),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

should_update_filters_test() ->
    OUI = 1,

    meck:new(blockchain, [passthrough]),
    meck:expect(blockchain, ledger, fun(_) -> ledger end),
    meck:expect(blockchain, config, fun(_, _) -> {ok, 2} end),
    meck:new(router_console_device_api, [passthrough]),
    meck:expect(router_console_device_api, get_all_devices, fun() -> {error, any} end),
    meck:new(blockchain_ledger_v1, [passthrough]),

    %% We start by testing if we got 0 device from API
    ?assertEqual(noop, should_update_filters(chain, OUI)),

    DeviceUpdates = [
        {dev_eui, <<"deveui">>},
        {app_eui, <<"app_eui">>}
    ],
    Device = router_device:update(DeviceUpdates, router_device:new(<<"ID">>)),
    meck:expect(router_console_device_api, get_all_devices, fun() ->
        {ok, [Device]}
    end),

    {Filter, _} = xor16:new(
        [<<(router_device:dev_eui(Device))/binary, (router_device:app_eui(Device))/binary>>],
        ?HASH_FUN
    ),
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Routing = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, Routing}
    end),

    %% Testing if device in filter = device sent by API
    ?assertEqual(noop, should_update_filters(chain, OUI)),

    {EmptyFilter, _} = xor16:new([], ?HASH_FUN),
    {BinEmptyFilter, _} = xor16:to_bin({EmptyFilter, ?HASH_FUN}),
    EmptyRouting = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinEmptyFilter, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, EmptyRouting}
    end),

    %% Testing if device in filter NOT = device sent by API and we still have room
    ?assertEqual(
        {new, EmptyRouting, [
            <<(router_device:dev_eui(Device))/binary, (router_device:app_eui(Device))/binary>>
        ]},
        should_update_filters(chain, OUI)
    ),

    meck:expect(blockchain, config, fun(_, _) -> {ok, 1} end),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, Routing}
    end),
    DeviceUpdates1 = [
        {dev_eui, <<"deveui1">>},
        {app_eui, <<"app_eui1">>}
    ],
    Device1 = router_device:update(DeviceUpdates1, router_device:new(<<"ID1">>)),
    meck:expect(router_console_device_api, get_all_devices, fun() ->
        {ok, [Device, Device1]}
    end),

    %% Testing if device in filter NOT = device sent by API and we have NO room
    ?assertEqual(
        {update, Routing, 1, [
            <<(router_device:dev_eui(Device1))/binary, (router_device:app_eui(Device1))/binary>>,
            <<(router_device:dev_eui(Device))/binary, (router_device:app_eui(Device))/binary>>
        ]},
        should_update_filters(chain, OUI)
    ),

    ?assert(meck:validate(blockchain_ledger_v1)),
    meck:unload(blockchain_ledger_v1),
    ?assert(meck:validate(router_console_device_api)),
    meck:unload(router_console_device_api),
    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain),
    ok.

contained_map_test() ->
    BinDevices = lists:foldl(
        fun(_, Acc) ->
            [crypto:strong_rand_bytes(16) | Acc]
        end,
        [],
        lists:seq(1, 10)
    ),
    {BinDevices1, BinDevices2} = lists:split(5, BinDevices),
    {Filter1, _} = xor16:new(BinDevices1, ?HASH_FUN),
    {BinFilter1, _} = xor16:to_bin({Filter1, ?HASH_FUN}),
    {Filter2, _} = xor16:new(BinDevices2, ?HASH_FUN),
    {BinFilter2, _} = xor16:to_bin({Filter2, ?HASH_FUN}),
    ?assertEqual(
        #{1 => BinDevices1, 2 => BinDevices2},
        contained_map(BinDevices, [BinFilter1, BinFilter2])
    ),
    ?assertEqual(
        #{0 => BinDevices2, 1 => BinDevices1},
        contained_map(BinDevices, [BinFilter1])
    ),
    ok.

find_smallest_test() ->
    ContainedMap = #{0 => [1], 1 => lists:seq(1, 3), 2 => lists:seq(1, 10), 3 => lists:seq(1, 2)},
    ?assertEqual({3, lists:seq(1, 2)}, find_smallest(ContainedMap)),

    ok.

-endif.
