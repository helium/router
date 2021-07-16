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
    start_link/1,
    estimate_cost/0,
    check_filters/0,
    deveui_appeui/1,
    rebalance_filters/0
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
-define(REBALANCE_FILTERS, rebalance_filters).
-define(CHECK_FILTERS_TIMER, timer:minutes(10)).
-define(HASH_FUN, fun xxhash:hash64/1).
-define(SUBMIT_RESULT, submit_result).

-type device_dev_eui_app_eui() :: binary().
-type devices_dev_eui_app_eui() :: list(device_dev_eui_app_eui()).

-record(state, {
    pubkey :: libp2p_crypto:public_key(),
    sig_fun :: libp2p_crypto:sig_fun(),
    chain :: undefined | blockchain:blockchain(),
    oui :: undefined | non_neg_integer(),
    pending_txns = #{} :: #{
        blockchain_txn:hash() => {non_neg_integer(), devices_dev_eui_app_eui()}
    },
    filter_to_devices = #{} :: #{non_neg_integer() => devices_dev_eui_app_eui()},
    check_filters_ref :: undefined | reference(),
    txn_count = 0 :: non_neg_integer()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec estimate_cost() -> noop | {non_neg_integer(), non_neg_integer()}.
estimate_cost() ->
    gen_server:call(?SERVER, estimate_cost, infinity).

-spec check_filters() -> ok.
check_filters() ->
    ?SERVER ! ?CHECK_FILTERS_TICK,
    ok.

-spec rebalance_filters() -> ok.
rebalance_filters() ->
    ?SERVER ! ?REBALANCE_FILTERS,
    ok.

-spec deveui_appeui(router_device:device()) -> device_dev_eui_app_eui().
deveui_appeui(Device) ->
    <<DevEUI:64/integer-unsigned-big>> = router_device:dev_eui(Device),
    <<AppEUI:64/integer-unsigned-big>> = router_device:app_eui(Device),
    <<DevEUI:64/integer-unsigned-little, AppEUI:64/integer-unsigned-little>>.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, PubKey, SigFun, _} = blockchain_swarm:keys(),
    ok = schedule_post_init(),
    {ok, #state{pubkey = PubKey, sig_fun = SigFun}}.

handle_call(estimate_cost, _From, State) ->
    Reply = estimate_cost(State),
    lager:info("estimating cost ~p", [Reply]),
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?REBALANCE_FILTERS, #state{chain = Chain, oui = OUI} = State) ->
    Pendings =
        case router_console_api:get_all_devices() of
            {error, _Reason} = Err ->
                lager:error("failed to get device ~p", [_Reason]),
                throw({could_not_rebalance_filters, Err});
            {ok, Devices} ->
                DevicesDevEuiAppEUI = get_devices_deveui_app_eui(Devices),

                Grouped = distribute_devices_across_n_groups(DevicesDevEuiAppEUI, 5),

                Ledger = blockchain:ledger(Chain),
                {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),
                CurrNonce = blockchain_ledger_routing_v1:nonce(Routing),
                lists:map(
                    fun({Idx, GroupEuis}) ->
                        Nonce = CurrNonce + Idx + 1,
                        {Filter, _} = xor16:new(GroupEuis, ?HASH_FUN),
                        Txn = craft_rebalance_update_filter_txn(Idx, Nonce, Filter, State),
                        Hash = submit_txn(Txn),
                        lager:info("updating filter txn ~p submitted ~p", [
                            Hash,
                            lager:pr(Txn, blockchain_txn_routing_v1)
                        ]),

                        {Hash, {Idx, GroupEuis}}
                    end,
                    enumerate_0(Grouped)
                )
        end,

    {noreply, State#state{pending_txns = maps:from_list(Pendings)}};
handle_info(post_init, #state{check_filters_ref = undefined} = State) ->
    State1 =
        case blockchain_worker:blockchain() of
            undefined ->
                ok = schedule_post_init(),
                {noreply, State};
            Chain ->
                case router_utils:get_oui() of
                    undefined ->
                        lager:warning("OUI undefined"),
                        ok = schedule_post_init(),
                        {noreply, State};
                    OUI ->
                        case enabled() of
                            true ->
                                Ref = schedule_check_filters(1),
                                State#state{chain = Chain, oui = OUI, check_filters_ref = Ref};
                            false ->
                                State#state{chain = Chain, oui = OUI}
                        end
                end
        end,
    FilterToDevices =
        case read_devices_from_disk() of
            {error, not_found} -> #{};
            Val -> Val
        end,
    {noreply, State1#state{filter_to_devices = FilterToDevices}};
handle_info(
    ?CHECK_FILTERS_TICK,
    #state{
        pubkey = PubKey,
        sig_fun = SigFun,
        chain = Chain,
        oui = OUI,
        filter_to_devices = FilterToDevices,
        pending_txns = Pendings0,
        check_filters_ref = OldRef,
        txn_count = TxnCount
    } = State
) ->
    case erlang:is_reference(OldRef) of
        false -> ok;
        true -> erlang:cancel_timer(OldRef)
    end,

    case should_update_filters(Chain, OUI, FilterToDevices) of
        noop ->
            lager:info("filters are still up to date"),
            Ref = schedule_check_filters(default_timer()),
            {noreply, State#state{check_filters_ref = Ref}};
        {Routing, Updates} ->
            CurrNonce = blockchain_ledger_routing_v1:nonce(Routing),
            {Pendings1, _, NewTC} = lists:foldl(
                fun
                    ({new, NewDevicesDevEuiAppEui}, {Pendings, Nonce, TC}) ->
                        ct:print("adding new filter"),
                        {Filter, _} = xor16:new(NewDevicesDevEuiAppEui, ?HASH_FUN),
                        Txn = craft_new_filter_txn(PubKey, SigFun, Chain, OUI, Filter, Nonce + 1),
                        Hash = submit_txn(Txn),
                        lager:info("new filter txn ~p submitted ~p", [
                            Hash,
                            lager:pr(Txn, blockchain_txn_routing_v1)
                        ]),

                        Index = erlang:length(blockchain_ledger_routing_v1:filters(Routing)),
                        {
                            maps:put(Hash, {Index, NewDevicesDevEuiAppEui, TC}, Pendings),
                            Nonce + 1,
                            TC + 1
                        };
                    ({update, Index, NewDevicesDevEuiAppEui}, {Pendings, Nonce, TC}) ->
                        ct:print("updating filter @ index ~p", [Index]),
                        {Filter, _} = xor16:new(NewDevicesDevEuiAppEui, ?HASH_FUN),
                        Txn = craft_update_filter_txn(
                            PubKey,
                            SigFun,
                            Chain,
                            OUI,
                            Filter,
                            Nonce + 1,
                            Index
                        ),
                        Hash = submit_txn(Txn),
                        lager:info("updating filter txn ~p submitted ~p", [
                            Hash,
                            lager:pr(Txn, blockchain_txn_routing_v1)
                        ]),
                        {
                            maps:put(Hash, {Index, NewDevicesDevEuiAppEui, TC}, Pendings),
                            Nonce + 1,
                            TC + 1
                        }
                end,
                {Pendings0, CurrNonce, TxnCount},
                Updates
            ),
            {noreply, State#state{pending_txns = Pendings1, txn_count = NewTC}}
    end;
handle_info(
    {?SUBMIT_RESULT, Hash, ok},
    #state{
        pending_txns = Pendings,
        filter_to_devices = FilterToDevices
    } = State0
) ->
    {Index, DevicesDevEuiAppEui, TxnCount} = maps:get(Hash, Pendings),
    lager:info("successfully submitted txn: ~p added ~p to filter ~p", [
        lager:pr(Hash, blockchain_txn_routing_v1),
        DevicesDevEuiAppEui,
        Index
    ]),
    State1 = State0#state{
        pending_txns = maps:remove(Hash, Pendings),
        filter_to_devices = maps:put(Index, DevicesDevEuiAppEui, FilterToDevices)
    },

    case State1#state.pending_txns == #{} of
        false ->
            lager:info("waiting for more txn to clear"),
            ct:print("~p:~p not writing to disk, waiting for more txns to clear", [Index, TxnCount]),
            {noreply, State1};
        true ->
            lager:info("all txns cleared"),
            Two = maps:values(State1#state.filter_to_devices),
            ct:print("~p:~p writing to disk: ~p~n~n~p~n~n", [
                Index,
                TxnCount,
                length(lists:flatten(Two)),
                Two
            ]),
            ok = write_devices_to_disk(State1#state.filter_to_devices),
            Ref = schedule_check_filters(default_timer()),
            {noreply, State1#state{check_filters_ref = Ref}}
    end;
handle_info(
    {?SUBMIT_RESULT, Hash, Return},
    #state{
        pending_txns = Pendings
    } = State0
) ->
    lager:error("failed to submit txn: ~p / ~p", [
        lager:pr(Hash, blockchain_txn_routing_v1),
        Return
    ]),
    State1 = State0#state{pending_txns = maps:remove(Hash, Pendings)},
    case State1#state.pending_txns == #{} of
        false ->
            lager:info("waiting for more txn to clear"),
            {noreply, State1};
        true ->
            lager:info("all txns cleared"),
            Ref = schedule_check_filters(1),
            {noreply, State1#state{check_filters_ref = Ref}}
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec read_devices_from_disk() -> {ok, map()} | {error, any()}.
read_devices_from_disk() ->
    {ok, DB, CF} = router_db:get(xor_filter_devices),
    case rocksdb:get(DB, CF, <<"xor_filter_state">>, []) of
        {ok, BinMap} ->
            erlang:binary_to_term(BinMap);
        not_found ->
            {error, not_found};
        Err ->
            Err
    end.

-spec write_devices_to_disk(map()) -> ok.
write_devices_to_disk(FtD) ->
    {ok, DB, CF} = router_db:get(xor_filter_devices),
    case rocksdb:put(DB, CF, <<"xor_filter_state">>, erlang:term_to_binary(FtD), []) of
        {error, _} = Err -> ct:print("failed to write!!!!!", [Err]);
        ok -> ok
    end.

-spec estimate_cost(#state{}) -> noop | {non_neg_integer(), non_neg_integer()}.
estimate_cost(#state{
    pubkey = PubKey,
    sig_fun = SigFun,
    chain = Chain,
    oui = OUI,
    filter_to_devices = FilterToDevices
}) ->
    case should_update_filters(Chain, OUI, FilterToDevices) of
        noop ->
            noop;
        {_Routing, Updates} ->
            lists:foldl(
                fun
                    ({new, NewDevicesDevEuiAppEui}, {Cost, N}) ->
                        {Filter, _} = xor16:new(NewDevicesDevEuiAppEui, ?HASH_FUN),
                        Txn = craft_new_filter_txn(PubKey, SigFun, Chain, OUI, Filter, 1),
                        {Cost + blockchain_txn_routing_v1:calculate_fee(Txn, Chain),
                            N + erlang:length(NewDevicesDevEuiAppEui)};
                    ({update, Index, NewDevicesDevEuiAppEui}, {Cost, N}) ->
                        {Filter, _} = xor16:new(NewDevicesDevEuiAppEui, ?HASH_FUN),
                        Txn = craft_update_filter_txn(PubKey, SigFun, Chain, OUI, Filter, 1, Index),
                        {Cost + blockchain_txn_routing_v1:calculate_fee(Txn, Chain),
                            N + erlang:length(NewDevicesDevEuiAppEui)}
                end,
                {0, 0},
                Updates
            )
    end.

distribute_devices_across_n_groups(Devices, FilterCount) ->
    %% Add 0.4 to more consistenly round up
    GroupSize = erlang:round((erlang:length(Devices) / FilterCount) + 0.4),
    do_distribute_devices_across_n_groups(Devices, GroupSize, []).

do_distribute_devices_across_n_groups([], _, G) ->
    G;
do_distribute_devices_across_n_groups(Devices, GroupSize, Grouped) ->
    {Group, Leftover} = lists:split(erlang:min(GroupSize, erlang:length(Devices)), Devices),
    do_distribute_devices_across_n_groups(Leftover, GroupSize, [Group | Grouped]).

-spec should_update_filters(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    FilterToDevices :: map()
) ->
    noop
    | {blockchain_ledger_routing_v1:routing(), [
        {new, devices_dev_eui_app_eui()}
        | {update, non_neg_integer(), devices_dev_eui_app_eui()}
    ]}.
should_update_filters(Chain, OUI, FilterToDevices) ->
    case router_console_api:get_all_devices() of
        {error, _Reason} ->
            ct:print("ten ~p", [_Reason]),
            lager:error("failed to get device ~p", [_Reason]),
            noop;
        {ok, Devices} ->
            DevicesDevEuiAppEui = get_devices_deveui_app_eui(Devices),
            One = length(Devices),
            Two = length(DevicesDevEuiAppEui),
            Three = length(lists:flatten(maps:values(FilterToDevices))),
            case {One, Two, Three} of
                {A, A, A} ->
                    ct:print("One two there are the same");
                {_, _, _} ->
                    ct:print("~nDevices:~n~p but only got ~p~nFilters length: ~p~nMap = ~p", [
                        One,
                        Two,
                        Three,
                        FilterToDevices
                    ])
            end,
            Ledger = blockchain:ledger(Chain),
            case blockchain_ledger_v1:find_routing(OUI, Ledger) of
                {error, _Reason} ->
                    lager:error("failed to find routing for OUI: ~p ~p", [OUI, _Reason]),
                    noop;
                {ok, Routing} ->
                    {ok, MaxXorFilter} = blockchain:config(max_xor_filter_num, Ledger),
                    BinFilters = blockchain_ledger_routing_v1:filters(Routing),
                    ct:print(
                        "Test with these args~nBinFilters = ~p, ~nFilterToDevices = ~p, ~nDevicesDevEuiAppEui = ~p, ",
                        [
                            BinFilters,
                            FilterToDevices,
                            DevicesDevEuiAppEui
                        ]
                    ),
                    Updates = contained_in_filters(
                        BinFilters,
                        FilterToDevices,
                        DevicesDevEuiAppEui
                    ),
                    ct:print("Updates:~n~p", [Updates]),
                    case craft_updates(Updates, BinFilters, MaxXorFilter) of
                        noop -> noop;
                        Crafted -> {Routing, Crafted}
                    end
            end
    end.

craft_updates(Updates, BinFilters, MaxXorFilter) ->
    case Updates of
        {_Map, [], Removed} when Removed == #{} ->
            noop;
        {Map, Added, Removed} when Removed == #{} ->
            case erlang:length(BinFilters) < MaxXorFilter of
                true ->
                    [{new, Added}];
                false ->
                    ct:print("Nothing to remove"),
                    case smallest_first(maps:to_list(Map)) of
                        [] ->
                            [{update, 0, Added}];
                        [{Index, SmallestDevicesDevEuiAppEui} | _] ->
                            [{update, Index, Added ++ SmallestDevicesDevEuiAppEui}]
                    end
            end;
        {Map, [], Removed} ->
            ct:print("we're only removed things~nMap = ~p~nRemoved = ~p", [Map, Removed]),
            craft_remove_updates(Map, Removed);
        {Map, Added, Removed} ->
            ct:print("We have some stuff to remove"),
            [{update, Index, R} | OtherUpdates] = smallest_first(
                craft_remove_updates(Map, Removed)
            ),
            [{update, Index, R ++ Added} | OtherUpdates]
    end.

-spec get_devices_deveui_app_eui(Devices :: [router_device:device()]) ->
    list(device_dev_eui_app_eui()).
get_devices_deveui_app_eui(Devices) ->
    get_devices_deveui_app_eui(Devices, []).

-spec get_devices_deveui_app_eui(
    Devices :: [router_device:device()],
    DevEUIsAppEUIs :: list(device_dev_eui_app_eui())
) -> list(device_dev_eui_app_eui()).
get_devices_deveui_app_eui([], DevEUIsAppEUIs) ->
    lists:usort(DevEUIsAppEUIs);
get_devices_deveui_app_eui([Device | Devices], DevEUIsAppEUIs) ->
    try deveui_appeui(Device) of
        DevEUiAppEUI ->
            get_devices_deveui_app_eui(Devices, [DevEUiAppEUI | DevEUIsAppEUIs])
    catch
        _C:_R ->
            lager:warning("failed to get deveui_appeui for device ~p: ~p", [
                router_device:id(Device),
                {_C, _R}
            ]),
            get_devices_deveui_app_eui(Devices, DevEUIsAppEUIs)
    end.

-spec smallest_first([{any(), L1 :: list()} | {any(), any(), L1 :: list()}]) -> list().
smallest_first(List) ->
    lists:sort(
        fun
            ({_, L1}, {_, L2}) ->
                erlang:length(L1) < erlang:length(L2);
            ({_, _, L1}, {_, _, L2}) ->
                erlang:length(L1) < erlang:length(L2)
        end,
        List
    ).

-spec craft_remove_updates(map(), map()) ->
    list({update, non_neg_integer(), devices_dev_eui_app_eui()}).

craft_remove_updates(Map, RemovedDevicesDevEuiAppEuiMap) ->
    maps:fold(
        fun(Index, RemovedDevicesDevEuiAppEui, Acc) ->
            [
                {update, Index, maps:get(Index, Map, []) -- RemovedDevicesDevEuiAppEui}
                | Acc
            ]
        end,
        [],
        RemovedDevicesDevEuiAppEuiMap
    ).

%% Return {map of IN FILTER device_dev_eui_app_eui indexed by their filter,
%%         list of added device
%%         map of REMOVED device_dev_eui_app_eui indexed by their filter}
-spec contained_in_filters(
    BinFilters :: list(binary()),
    FilterToDevices :: map(),
    DevicesDevEuiAppEui :: devices_dev_eui_app_eui()
) ->
    {#{non_neg_integer() => devices_dev_eui_app_eui()}, devices_dev_eui_app_eui(), #{
        non_neg_integer() => devices_dev_eui_app_eui()
    }}.
contained_in_filters(BinFilters, FilterToDevices, DevicesDevEuiAppEui) ->
    BinFiltersWithIndex = lists:zip(lists:seq(0, erlang:length(BinFilters) - 1), BinFilters),
    ContainedBy = fun(Filter) -> fun(Bin) -> xor16:contain({Filter, ?HASH_FUN}, Bin) end end,
    One = lists:flatten(maps:values(FilterToDevices)),
    Stuff = One -- DevicesDevEuiAppEui,
    ct:print("What's this stuff:~n~p - ~p == ~p~n~p", [
        length(One),
        length(DevicesDevEuiAppEui),
        length(Stuff),
        Stuff
    ]),
    {CurrFilter, Removed, Added, _} =
        lists:foldl(
            fun({Index, Filter}, {InFilterAcc0, RemovedAcc0, AddedToCheck, RemovedToCheck}) ->
                {AddedInFilter, AddedLeftover} = lists:partition(
                    ContainedBy(Filter),
                    AddedToCheck
                ),
                InFilterAcc1 =
                    case AddedInFilter == [] of
                        false -> maps:put(Index, AddedInFilter, InFilterAcc0);
                        true -> InFilterAcc0
                    end,
                {RemovedInFilter, RemovedLeftover} = lists:partition(
                    ContainedBy(Filter),
                    RemovedToCheck
                ),
                RemovedAcc1 =
                    case RemovedInFilter == [] of
                        false -> maps:put(Index, RemovedInFilter, RemovedAcc0);
                        true -> RemovedAcc0
                    end,
                {InFilterAcc1, RemovedAcc1, AddedLeftover, RemovedLeftover}
            end,
            {#{}, #{}, DevicesDevEuiAppEui, Stuff},
            BinFiltersWithIndex
        ),
    {CurrFilter, Added, Removed}.

-spec craft_new_filter_txn(
    PubKey :: libp2p_crypto:public_key(),
    SigFun :: libp2p_crypto:sig_fun(),
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference(),
    Nonce :: non_neg_integer()
) -> blockchain_txn_routing_v1:txn_routing().
craft_new_filter_txn(PubKey, SignFun, Chain, OUI, Filter, Nonce) ->
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Txn0 = blockchain_txn_routing_v1:new_xor(
        OUI,
        libp2p_crypto:pubkey_to_bin(PubKey),
        BinFilter,
        Nonce
    ),
    Fees = blockchain_txn_routing_v1:calculate_fee(Txn0, Chain),
    Txn1 = blockchain_txn_routing_v1:fee(Txn0, Fees),
    blockchain_txn_routing_v1:sign(Txn1, SignFun).

-spec craft_rebalance_update_filter_txn(
    Index :: non_neg_integer(),
    Nonce :: non_neg_integer(),
    Filter :: reference(),
    State :: #state{}
) -> blockchain_txn_routing_v1:txn_routing().
craft_rebalance_update_filter_txn(Index, Nonce, Filter, #state{
    pubkey = PubKey,
    sig_fun = SigFun,
    chain = Chain,
    oui = OUI
}) ->
    craft_update_filter_txn(PubKey, SigFun, Chain, OUI, Filter, Nonce, Index).

-spec craft_update_filter_txn(
    PubKey :: libp2p_crypto:public_key(),
    SigFun :: libp2p_crypto:sig_fun(),
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference(),
    Nonce :: non_neg_integer(),
    Index :: non_neg_integer()
) -> blockchain_txn_routing_v1:txn_routing().
craft_update_filter_txn(PubKey, SignFun, Chain, OUI, Filter, Nonce, Index) ->
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Txn0 = blockchain_txn_routing_v1:update_xor(
        OUI,
        libp2p_crypto:pubkey_to_bin(PubKey),
        Index,
        BinFilter,
        Nonce
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

-spec schedule_check_filters(non_neg_integer()) -> reference().
schedule_check_filters(Timer) ->
    erlang:send_after(Timer, self(), ?CHECK_FILTERS_TICK).

-spec enabled() -> boolean().
enabled() ->
    case application:get_env(router, router_xor_filter_worker, false) of
        "true" -> true;
        true -> true;
        _ -> false
    end.

-spec default_timer() -> non_neg_integer().
default_timer() ->
    case application:get_env(router, router_xor_filter_worker_timer, ?CHECK_FILTERS_TIMER) of
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        I -> I
    end.

enumerate_0(L) ->
    lists:zip(lists:seq(0, erlang:length(L) - 1), L).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

deveui_appeui_test() ->
    DevEUI = 6386327472473908003,
    AppEUI = 6386327472473964541,
    DeviceUpdates = [
        {dev_eui, <<DevEUI:64/integer-unsigned-big>>},
        {app_eui, <<AppEUI:64/integer-unsigned-big>>}
    ],
    Device = router_device:update(DeviceUpdates, router_device:new(<<"ID0">>)),
    ?assertEqual(
        <<DevEUI:64/integer-unsigned-little, AppEUI:64/integer-unsigned-little>>,
        deveui_appeui(Device)
    ).

should_update_filters_test() ->
    {timeout, 15, fun test_for_should_update_filters_test/0}.
test_for_should_update_filters_test() ->
    OUI = 1,

    meck:new(blockchain, [passthrough]),
    meck:new(router_console_api, [passthrough]),
    meck:new(blockchain_ledger_v1, [passthrough]),

    %% ------------------------
    %% We start by testing if we got 0 device from API
    meck:expect(blockchain, ledger, fun(_) -> ledger end),
    %% This set the max xor filter chain var
    meck:expect(blockchain, config, fun(_, _) -> {ok, 2} end),
    meck:expect(router_console_api, get_all_devices, fun() -> {error, any} end),

    ?assertEqual(noop, should_update_filters(chain, OUI, #{})),

    %% ------------------------
    %% Testing if no devices were added or removed
    Device0Updates = [
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 1>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 1>>}
    ],
    Device0 = router_device:update(Device0Updates, router_device:new(<<"ID0">>)),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device0]}
    end),

    {Filter, _} = xor16:new([deveui_appeui(Device0)], ?HASH_FUN),
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    Routing0 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, Routing0}
    end),

    ?assertEqual(noop, should_update_filters(chain, OUI, #{})),

    %% ------------------------
    %% Testing if a device was added
    {EmptyFilter, _} = xor16:new([], ?HASH_FUN),
    {BinEmptyFilter, _} = xor16:to_bin({EmptyFilter, ?HASH_FUN}),
    EmptyRouting = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinEmptyFilter, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, EmptyRouting}
    end),

    ?assertEqual(
        {EmptyRouting, [{new, [deveui_appeui(Device0)]}]},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    %% Testing if a device was added but we have at our max filter (set to 1)
    meck:expect(blockchain, config, fun(_, _) -> {ok, 1} end),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, Routing0}
    end),
    DeviceUpdates1 = [
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 2>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 1>>}
    ],
    Device1 = router_device:update(DeviceUpdates1, router_device:new(<<"ID1">>)),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device0, Device1]}
    end),

    ?assertEqual(
        {Routing0, [{update, 0, [deveui_appeui(Device1), deveui_appeui(Device0)]}]},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Testing that we removed Device0
    meck:expect(blockchain, config, fun(_, _) -> {ok, 2} end),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device1]}
    end),

    ?assertEqual(
        {Routing0, [{update, 0, [deveui_appeui(Device1)]}]},
        should_update_filters(chain, OUI, #{
            0 => [deveui_appeui(Device0)]
        })
    ),

    %% ------------------------
    % Testing that we removed Device0 and added Device2
    DeviceUpdates2 = [
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 3>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 1>>}
    ],
    Device2 = router_device:update(DeviceUpdates2, router_device:new(<<"ID2">>)),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device1, Device2]}
    end),

    ?assertEqual(
        {Routing0, [{update, 0, [deveui_appeui(Device1), deveui_appeui(Device2)]}]},
        should_update_filters(chain, OUI, #{
            0 => [deveui_appeui(Device0)]
        })
    ),

    %% ------------------------
    % Testing that we removed Device0 and Device1 but from diff filters
    {Filter0, _} = xor16:new([deveui_appeui(Device0)], ?HASH_FUN),
    {BinFilter0, _} = xor16:to_bin({Filter0, ?HASH_FUN}),
    RoutingRemoved0 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter0, [], 1),
    {Filter1, _} = xor16:new([deveui_appeui(Device1)], ?HASH_FUN),
    {BinFilter1, _} = xor16:to_bin({Filter1, ?HASH_FUN}),
    RoutingRemoved1 = blockchain_ledger_routing_v1:update(
        RoutingRemoved0,
        {new_xor, BinFilter1},
        1
    ),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, RoutingRemoved1}
    end),

    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, []}
    end),

    ?assertEqual(
        {RoutingRemoved1, [{update, 1, []}, {update, 0, []}]},
        should_update_filters(chain, OUI, #{
            0 => [deveui_appeui(Device0)],
            1 => [deveui_appeui(Device1)]
        })
    ),

    %% ------------------------
    % Testing with a device that has bad app eui or dev eui
    DeviceUpdates3 = [
        {dev_eui, <<0, 0, 3>>},
        {app_eui, <<0, 0, 0, 2, 1>>}
    ],
    Device3 = router_device:update(DeviceUpdates3, router_device:new(<<"ID3">>)),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device3]}
    end),

    ?assertEqual(
        noop,
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Testing for an empty Map
    RoutingEmptyMap0 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter0, [], 1),
    RoutingEmptyMap1 = blockchain_ledger_routing_v1:update(
        RoutingEmptyMap0,
        {new_xor, BinFilter1},
        1
    ),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, RoutingEmptyMap1}
    end),
    DeviceUpdates4 = [
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 4>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 1>>}
    ],
    Device4 = router_device:update(DeviceUpdates4, router_device:new(<<"ID2">>)),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device4]}
    end),

    ?assertEqual(
        {RoutingEmptyMap1, [{update, 0, [deveui_appeui(Device4)]}]},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Testing Duplicate eui pairs for new filters
    DeviceUpdates5 = [
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 5>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 1>>}
    ],
    Device5 = router_device:update(DeviceUpdates5, router_device:new(<<"ID0">>)),
    Device5Copy = router_device:update(DeviceUpdates5, router_device:new(<<"ID0Copy">>)),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device5, Device5Copy]}
    end),

    {EmptyFilter2, _} = xor16:new([], ?HASH_FUN),
    {BinEmptyFilter2, _} = xor16:to_bin({EmptyFilter2, ?HASH_FUN}),
    EmptyRouting2 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinEmptyFilter2, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, EmptyRouting}
    end),

    %% Devices with matching app/dev eui should be deduplicated
    ?assertEqual(
        {EmptyRouting2, [{new, [deveui_appeui(Device5)]}]},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Devices already in Filter should not cause updates
    {FilterLast, _} = xor16:new([deveui_appeui(Device5)], ?HASH_FUN),
    {BinFilterLast, _} = xor16:to_bin({FilterLast, ?HASH_FUN}),
    RoutingLast = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilterLast, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, RoutingLast}
    end),

    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device5Copy]}
    end),

    ?assertEqual(
        noop,
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Testing duplicate eui pairs for a filter that already has a device
    DeviceUpdates6 = [
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 6>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 2>>}
    ],
    Device6 = router_device:update(DeviceUpdates6, router_device:new(<<"ID6">>)),
    Device6Copy = router_device:update(DeviceUpdates6, router_device:new(<<"ID6Copy">>)),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device6, Device6Copy]}
    end),

    %% Force 1 filter so we update the existing
    meck:expect(blockchain, config, fun(_, _) -> {ok, 1} end),

    ?assertEqual(
        {RoutingLast, [{update, 0, [deveui_appeui(Device6)]}]},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Testing duplicate eui pairs for a filter that already has the duplicate device
    DeviceUpdates7 = [
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 7>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 2>>}
    ],
    Device7 = router_device:update(DeviceUpdates7, router_device:new("ID7")),
    DeviceUpdates8 = [
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 8>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 2>>}
    ],
    Device8 = router_device:update(DeviceUpdates8, router_device:new("ID8")),
    {Filter7, _} = xor16:new([deveui_appeui(Device7)], ?HASH_FUN),
    {BinFilter7, _} = xor16:to_bin({Filter7, ?HASH_FUN}),
    Routing7 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter7, [], 1),

    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) -> {ok, Routing7} end),
    meck:expect(router_console_api, get_all_devices, fun() -> {ok, [Device7, Device7, Device8]} end),
    meck:expect(blockchain, config, fun(_, _) -> {ok, 1} end),

    ?assertEqual(
        {Routing7, [{update, 0, [deveui_appeui(Device8), deveui_appeui(Device7)]}]},
        should_update_filters(chain, OUI, #{})
    ),

    meck:unload(blockchain_ledger_v1),
    meck:unload(router_console_api),
    meck:unload(blockchain),
    ok.

contained_in_filters_test_() ->
    BinDevices = lists:sort([crypto:strong_rand_bytes(16) || _ <- lists:seq(1, 10)]),

    {BinDevices1, BinDevices2} = lists:split(5, BinDevices),
    {Filter1, _} = xor16:new(BinDevices1, ?HASH_FUN),
    {BinFilter1, _} = xor16:to_bin({Filter1, ?HASH_FUN}),
    {Filter2, _} = xor16:new(BinDevices2, ?HASH_FUN),
    {BinFilter2, _} = xor16:to_bin({Filter2, ?HASH_FUN}),
    [
        ?_assertEqual(
            {
                #{0 => BinDevices1, 1 => BinDevices2},
                lists:sort([]),
                #{}
            },
            contained_in_filters([BinFilter1, BinFilter2], #{}, BinDevices)
        ),
        ?_assertEqual(
            {
                #{0 => BinDevices1},
                BinDevices2,
                #{}
            },
            contained_in_filters([BinFilter1], #{}, BinDevices)
        ),
        ?_assertEqual(
            {
                #{0 => BinDevices1},
                [],
                #{1 => BinDevices2}
            },
            contained_in_filters([BinFilter1, BinFilter2], #{0 => BinDevices2}, BinDevices1)
        ),
        ?_assertEqual(
            {
                #{},
                BinDevices2,
                #{0 => BinDevices1}
            },
            contained_in_filters([BinFilter1], #{0 => BinDevices1}, BinDevices2)
        )
    ].

craft_updates_test() ->
    BinFilters = [
        <<193, 92, 2, 137, 236, 45, 10, 145, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,
        <<193, 92, 2, 137, 236, 45, 10, 145, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 164, 124, 168, 173, 11,
            131, 0, 0, 0, 0, 0, 0, 79, 237, 0, 0, 0, 0, 108, 225, 189, 136, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 103, 120, 111, 120, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            109, 19, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 227, 167, 0, 0, 0, 0, 0, 0, 0, 0>>,
        <<193, 92, 2, 137, 236, 45, 10, 145, 18, 0, 0, 0, 0, 0, 0, 0, 4, 145, 0, 0, 186, 160, 0, 0,
            0, 0, 0, 0, 0, 0, 1, 13, 0, 0, 139, 240, 1, 190, 0, 34, 0, 0, 126, 87, 62, 204, 51, 87,
            0, 0, 0, 0, 0, 0, 113, 19, 0, 0, 0, 0, 0, 0, 0, 0, 179, 85, 0, 0, 46, 191, 0, 0, 170,
            223, 137, 142, 174, 80, 0, 0, 0, 0, 0, 0, 88, 127, 0, 0, 0, 0, 0, 0, 67, 109, 0, 0, 0,
            0, 20, 253, 0, 0, 212, 208, 0, 0, 0, 0, 0, 0, 18, 240, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0>>,
        <<193, 92, 2, 137, 236, 45, 10, 145, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10, 16, 0, 0, 223,
            56, 0, 0, 203, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,
        <<193, 92, 2, 137, 236, 45, 10, 145, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 84, 209, 0, 0, 0, 0, 63, 208, 217, 239, 103, 146, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0>>
    ],
    FilterToDevices = #{
        2 => [
            <<15, 52, 125, 2, 75, 173, 167, 178, 58, 99, 246, 170, 34, 98, 122, 36>>,
            <<41, 197, 112, 109, 185, 64, 211, 126, 28, 65, 233, 116, 170, 220, 178, 247>>,
            <<53, 78, 38, 219, 222, 233, 110, 153, 125, 208, 47, 133, 107, 31, 26, 192>>,
            <<137, 214, 231, 107, 53, 252, 130, 196, 3, 177, 145, 57, 40, 53, 235, 92>>,
            <<139, 18, 136, 10, 22, 42, 17, 74, 145, 167, 131, 43, 164, 181, 120, 231>>,
            <<153, 82, 86, 211, 24, 239, 100, 110, 146, 93, 115, 14, 63, 78, 254, 19>>,
            <<169, 133, 0, 210, 44, 195, 12, 89, 41, 71, 228, 224, 175, 162, 198, 161>>,
            <<227, 217, 52, 38, 66, 4, 223, 76, 182, 84, 68, 127, 225, 140, 141, 228>>,
            <<244, 48, 199, 110, 203, 81, 40, 179, 64, 117, 108, 43, 142, 199, 144, 93>>,
            <<252, 201, 117, 214, 195, 171, 133, 52, 246, 162, 14, 145, 209, 168, 227, 61>>
        ],
        3 => [
            <<2, 131, 230, 61, 144, 116, 63, 113, 82, 1, 209, 189, 133, 220, 249, 157>>,
            <<16, 54, 11, 199, 41, 46, 183, 38, 24, 109, 113, 186, 233, 60, 30, 61>>,
            <<88, 134, 182, 36, 255, 178, 243, 97, 95, 161, 111, 56, 213, 77, 160, 49>>,
            <<97, 171, 209, 115, 150, 106, 131, 136, 68, 191, 147, 17, 171, 98, 120, 69>>,
            <<118, 209, 233, 117, 141, 143, 58, 243, 144, 125, 171, 128, 29, 137, 208, 78>>,
            <<120, 111, 133, 115, 6, 35, 122, 43, 216, 24, 19, 196, 79, 182, 82, 156>>,
            <<124, 16, 210, 231, 211, 2, 171, 4, 124, 54, 109, 90, 123, 182, 192, 253>>,
            <<133, 53, 118, 245, 106, 27, 146, 253, 24, 65, 13, 141, 159, 104, 107, 106>>,
            <<138, 157, 41, 38, 235, 20, 151, 46, 184, 155, 28, 25, 94, 39, 41, 127>>,
            <<145, 98, 216, 167, 66, 217, 19, 202, 57, 98, 58, 155, 7, 20, 219, 169>>,
            <<177, 204, 67, 142, 206, 139, 100, 179, 21, 221, 208, 254, 244, 225, 95, 124>>,
            <<182, 36, 142, 33, 228, 41, 0, 196, 7, 192, 104, 211, 172, 41, 186, 166>>,
            <<182, 211, 99, 152, 21, 85, 218, 1, 187, 43, 147, 53, 174, 36, 65, 216>>,
            <<207, 127, 101, 78, 125, 183, 147, 71, 232, 113, 84, 179, 167, 180, 159, 248>>,
            <<207, 182, 86, 234, 61, 217, 86, 98, 92, 29, 85, 176, 186, 224, 218, 230>>,
            <<208, 38, 70, 157, 4, 110, 220, 207, 152, 19, 73, 239, 112, 26, 131, 208>>,
            <<211, 48, 136, 34, 95, 19, 181, 228, 102, 206, 209, 125, 187, 34, 135, 105>>,
            <<222, 54, 95, 143, 7, 231, 251, 65, 140, 234, 240, 3, 250, 188, 120, 19>>,
            <<248, 178, 167, 17, 25, 116, 62, 197, 119, 175, 168, 120, 40, 155, 106, 121>>,
            <<249, 35, 177, 203, 254, 126, 56, 109, 17, 62, 221, 35, 0, 89, 105, 144>>
        ],
        4 => [
            <<68, 12, 3, 230, 29, 62, 24, 213, 11, 224, 211, 138, 48, 203, 211, 97>>,
            <<157, 91, 120, 109, 166, 224, 146, 204, 201, 105, 154, 210, 105, 74, 244, 126>>,
            <<227, 97, 152, 174, 93, 19, 168, 80, 214, 220, 123, 59, 238, 125, 91, 86>>
        ],
        5 => [
            <<23, 117, 0, 60, 92, 162, 235, 113, 31, 171, 194, 29, 6, 184, 216, 120>>,
            <<83, 76, 57, 86, 134, 43, 61, 179, 82, 201, 153, 217, 138, 112, 156, 61>>,
            <<90, 188, 202, 57, 27, 176, 237, 95, 173, 74, 186, 2, 171, 129, 252, 228>>,
            <<236, 188, 148, 242, 80, 220, 239, 7, 207, 62, 123, 22, 24, 7, 161, 73>>
        ]
    },
    DevicesDevEuiAppEui = [
        <<2, 131, 230, 61, 144, 116, 63, 113, 82, 1, 209, 189, 133, 220, 249, 157>>,
        <<15, 52, 125, 2, 75, 173, 167, 178, 58, 99, 246, 170, 34, 98, 122, 36>>,
        <<16, 54, 11, 199, 41, 46, 183, 38, 24, 109, 113, 186, 233, 60, 30, 61>>,
        <<23, 117, 0, 60, 92, 162, 235, 113, 31, 171, 194, 29, 6, 184, 216, 120>>,
        <<41, 197, 112, 109, 185, 64, 211, 126, 28, 65, 233, 116, 170, 220, 178, 247>>,
        <<53, 78, 38, 219, 222, 233, 110, 153, 125, 208, 47, 133, 107, 31, 26, 192>>,
        <<68, 12, 3, 230, 29, 62, 24, 213, 11, 224, 211, 138, 48, 203, 211, 97>>,
        <<73, 113, 127, 124, 231, 136, 219, 160, 29, 224, 56, 200, 178, 176, 99, 80>>,
        <<83, 76, 57, 86, 134, 43, 61, 179, 82, 201, 153, 217, 138, 112, 156, 61>>,
        <<88, 134, 182, 36, 255, 178, 243, 97, 95, 161, 111, 56, 213, 77, 160, 49>>,
        <<89, 145, 250, 157, 168, 203, 232, 122, 248, 109, 142, 218, 193, 79, 230, 132>>,
        <<90, 188, 202, 57, 27, 176, 237, 95, 173, 74, 186, 2, 171, 129, 252, 228>>,
        <<94, 124, 32, 83, 4, 59, 167, 145, 79, 157, 200, 28, 32, 7, 12, 39>>,
        <<97, 171, 209, 115, 150, 106, 131, 136, 68, 191, 147, 17, 171, 98, 120, 69>>,
        <<118, 209, 233, 117, 141, 143, 58, 243, 144, 125, 171, 128, 29, 137, 208, 78>>,
        <<120, 111, 133, 115, 6, 35, 122, 43, 216, 24, 19, 196, 79, 182, 82, 156>>,
        <<124, 16, 210, 231, 211, 2, 171, 4, 124, 54, 109, 90, 123, 182, 192, 253>>,
        <<133, 53, 118, 245, 106, 27, 146, 253, 24, 65, 13, 141, 159, 104, 107, 106>>,
        <<137, 214, 231, 107, 53, 252, 130, 196, 3, 177, 145, 57, 40, 53, 235, 92>>,
        <<138, 157, 41, 38, 235, 20, 151, 46, 184, 155, 28, 25, 94, 39, 41, 127>>,
        <<139, 18, 136, 10, 22, 42, 17, 74, 145, 167, 131, 43, 164, 181, 120, 231>>,
        <<145, 98, 216, 167, 66, 217, 19, 202, 57, 98, 58, 155, 7, 20, 219, 169>>,
        <<153, 82, 86, 211, 24, 239, 100, 110, 146, 93, 115, 14, 63, 78, 254, 19>>,
        <<157, 91, 120, 109, 166, 224, 146, 204, 201, 105, 154, 210, 105, 74, 244, 126>>,
        <<169, 133, 0, 210, 44, 195, 12, 89, 41, 71, 228, 224, 175, 162, 198, 161>>,
        <<177, 204, 67, 142, 206, 139, 100, 179, 21, 221, 208, 254, 244, 225, 95, 124>>,
        <<179, 61, 92, 69, 233, 223, 238, 189, 140, 186, 192, 245, 208, 27, 243, 185>>,
        <<182, 36, 142, 33, 228, 41, 0, 196, 7, 192, 104, 211, 172, 41, 186, 166>>,
        <<182, 211, 99, 152, 21, 85, 218, 1, 187, 43, 147, 53, 174, 36, 65, 216>>,
        <<207, 127, 101, 78, 125, 183, 147, 71, 232, 113, 84, 179, 167, 180, 159, 248>>,
        <<207, 182, 86, 234, 61, 217, 86, 98, 92, 29, 85, 176, 186, 224, 218, 230>>,
        <<208, 38, 70, 157, 4, 110, 220, 207, 152, 19, 73, 239, 112, 26, 131, 208>>,
        <<211, 48, 136, 34, 95, 19, 181, 228, 102, 206, 209, 125, 187, 34, 135, 105>>,
        <<222, 54, 95, 143, 7, 231, 251, 65, 140, 234, 240, 3, 250, 188, 120, 19>>,
        <<227, 97, 152, 174, 93, 19, 168, 80, 214, 220, 123, 59, 238, 125, 91, 86>>,
        <<227, 217, 52, 38, 66, 4, 223, 76, 182, 84, 68, 127, 225, 140, 141, 228>>,
        <<231, 65, 255, 203, 138, 161, 127, 5, 89, 237, 211, 107, 213, 244, 243, 123>>,
        <<236, 188, 148, 242, 80, 220, 239, 7, 207, 62, 123, 22, 24, 7, 161, 73>>,
        <<244, 48, 199, 110, 203, 81, 40, 179, 64, 117, 108, 43, 142, 199, 144, 93>>,
        <<248, 178, 167, 17, 25, 116, 62, 197, 119, 175, 168, 120, 40, 155, 106, 121>>,
        <<249, 35, 177, 203, 254, 126, 56, 109, 17, 62, 221, 35, 0, 89, 105, 144>>,
        <<252, 201, 117, 214, 195, 171, 133, 52, 246, 162, 14, 145, 209, 168, 227, 61>>
    ],
    ?debugFmt("~nMapping: ~n~p", [FilterToDevices]),
    Updates = contained_in_filters(
        BinFilters,
        FilterToDevices,
        DevicesDevEuiAppEui
    ),
    ?debugFmt("~nUpdates:~n~p", [Updates]),
    Res = craft_updates(Updates, BinFilters, 5),
    ?debugFmt("~nCrafted:~n~p", [Res]),
    ok.

-endif.
