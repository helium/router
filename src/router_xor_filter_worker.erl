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
    rebalance_filters/0,
    refresh_cache/0
]).

-export([
    report_device_status/1,
    report_filter_sizes/0,
    report_timer/0
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

-type device_eui() :: binary().
-type device_dev_eui_app_eui() :: #{
    device_id => binary(),
    eui => device_eui(),
    filter_index => unset | 0..4
}.
-type devices_dev_eui_app_eui() :: list(device_dev_eui_app_eui()).
-type filter_eui_mapping() :: #{0..4 := devices_dev_eui_app_eui()}.
-type update() ::
    {new, devices_dev_eui_app_eui()} | {update, FilterIndex :: 0..4, devices_dev_eui_app_eui()}.

-record(state, {
    pubkey :: libp2p_crypto:public_key(),
    sig_fun :: libp2p_crypto:sig_fun(),
    chain :: undefined | blockchain:blockchain(),
    oui :: undefined | non_neg_integer(),
    pending_txns = #{} :: #{
        blockchain_txn:hash() => {non_neg_integer(), devices_dev_eui_app_eui()}
    },
    filter_to_devices = #{} :: #{
        FilterIndex ::
            0..4 => #{
                device_id => binary(),
                eui => device_dev_eui_app_eui(),
                filter_index => 0..4
            }
    },
    check_filters_ref :: undefined | reference()
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
    gen_server:cast(?SERVER, ?REBALANCE_FILTERS).

-spec deveui_appeui(router_device:device()) -> device_eui().
deveui_appeui(Device) ->
    <<DevEUI:64/integer-unsigned-big>> = router_device:dev_eui(Device),
    <<AppEUI:64/integer-unsigned-big>> = router_device:app_eui(Device),
    <<DevEUI:64/integer-unsigned-little, AppEUI:64/integer-unsigned-little>>.

-spec report_device_status(router_device:device()) -> proplists:proplist().
report_device_status(Device) ->
    gen_server:call(?SERVER, {report_device_status, Device}).

-spec report_filter_sizes() -> proplists:proplist().
report_filter_sizes() ->
    gen_server:call(?SERVER, report_filter_sizes).

-spec report_timer() -> undefined | reference().
report_timer() ->
    gen_server:call(?SERVER, report_timer).

-spec refresh_cache() -> ok.
refresh_cache() ->
    gen_server:call(?SERVER, refresh_cache).

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
handle_call(report_timer, _From, #state{check_filters_ref = Timer} = State) ->
    {reply, Timer, State};
handle_call(report_filter_sizes, _From, #state{filter_to_devices = FilterToDevices} = State) ->
    Filters = get_filters(State),

    Reply = [
        {routing, enumerate_0([byte_size(F) || F <- Filters])},
        {in_memory, [{Idx, erlang:length(Devs)} || {Idx, Devs} <- maps:to_list(FilterToDevices)]}
    ],

    {reply, Reply, State};
handle_call(
    {report_device_status, Device},
    _From,
    #state{filter_to_devices = FilterToDevices} = State
) ->
    BinFilters = get_filters(State),
    [#{eui := DeviceEUI} = DeviceEUIEntry] = get_devices_deveui_app_eui([Device]),

    Reply = [
        {routing, [
            {Idx, xor16:contain({Filter, ?HASH_FUN}, DeviceEUI)}
            || {Idx, Filter} <- enumerate_0(BinFilters)
        ]},
        {in_memory, [
            {Idx, is_unset_filter_index_in_list(DeviceEUIEntry, DeviceList)}
            || {Idx, DeviceList} <- lists:sort(maps:to_list(FilterToDevices))
        ]}
    ],

    {reply, Reply, State};
handle_call(refresh_cache, _From, State) ->
    {ok, FilterToDevices} = read_devices_from_disk(),
    {reply, ok, State#state{filter_to_devices = FilterToDevices}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(?REBALANCE_FILTERS, #state{chain = Chain, oui = OUI} = State) ->
    Pendings =
        case router_console_api:get_all_devices() of
            {error, _Reason} ->
                lager:error("failed to get devices ~p", [_Reason]),
                {error, {could_not_rebalance_filters, _Reason}};
            {ok, Devices} ->
                DevicesDevEuiAppEUI = get_devices_deveui_app_eui(Devices),

                Grouped = distribute_devices_across_n_groups(DevicesDevEuiAppEUI, 5),

                Ledger = blockchain:ledger(Chain),
                {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),
                CurrNonce = blockchain_ledger_routing_v1:nonce(Routing),
                lists:map(
                    fun({Idx, GroupEuis}) ->
                        Nonce = CurrNonce + Idx + 1,
                        Filter = new_xor_filter(GroupEuis),
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
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

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
    {ok, FilterToDevices} = read_devices_from_disk(),
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
        check_filters_ref = OldRef
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
            {Pendings1, _} = lists:foldl(
                fun
                    ({new, NewDevicesDevEuiAppEui}, {Pendings, Nonce}) ->
                        lager:info("adding new filter"),
                        Filter = new_xor_filter(NewDevicesDevEuiAppEui),
                        Txn = craft_new_filter_txn(PubKey, SigFun, Chain, OUI, Filter, Nonce + 1),
                        Hash = submit_txn(Txn),
                        lager:info("new filter txn ~p submitted ~p", [
                            Hash,
                            lager:pr(Txn, blockchain_txn_routing_v1)
                        ]),
                        %% Filters are zero-indexed
                        Index = erlang:length(blockchain_ledger_routing_v1:filters(Routing)),
                        {
                            maps:put(
                                Hash,
                                {Index, assign_filter_index(Index, NewDevicesDevEuiAppEui)},
                                Pendings
                            ),
                            Nonce + 1
                        };
                    ({update, Index, NewDevicesDevEuiAppEui}, {Pendings, Nonce}) ->
                        lager:info("updating filter @ index ~p", [Index]),
                        Filter = new_xor_filter(NewDevicesDevEuiAppEui),
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
                            maps:put(
                                Hash,
                                {Index, assign_filter_index(Index, NewDevicesDevEuiAppEui)},
                                Pendings
                            ),
                            Nonce + 1
                        }
                end,
                {Pendings0, CurrNonce},
                Updates
            ),
            {noreply, State#state{pending_txns = Pendings1}}
    end;
handle_info(
    {?SUBMIT_RESULT, Hash, ok},
    #state{
        pending_txns = Pendings,
        filter_to_devices = FilterToDevices
    } = State0
) ->
    {Index, DevicesDevEuiAppEui} = maps:get(Hash, Pendings),
    lager:info("successfully submitted txn: ~p added ~p to filter ~p", [
        lager:pr(Hash, blockchain_txn_routing_v1),
        DevicesDevEuiAppEui,
        Index
    ]),
    State1 = State0#state{
        pending_txns = maps:remove(Hash, Pendings),
        filter_to_devices = maps:put(Index, DevicesDevEuiAppEui, FilterToDevices)
    },

    {AddedDevices, RemovedDevices} = diff_filter_to_devices(
        State0#state.filter_to_devices,
        State1#state.filter_to_devices
    ),
    ok = update_console_api(AddedDevices, RemovedDevices),
    ok = sync_cache_to_disk(AddedDevices, RemovedDevices),

    case State1#state.pending_txns == #{} of
        false ->
            lager:info("waiting for more txn to clear"),
            {noreply, State1};
        true ->
            lager:info("all txns cleared"),
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

terminate(_Reason, #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

get_filters(#state{chain = Chain, oui = OUI}) ->
    get_filters(Chain, OUI).

get_filters(Chain, OUI) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_routing(OUI, Ledger) of
        {error, _Reason} = Err ->
            lager:error("failed to find routing for OUI: ~p ~p", [OUI, _Reason]),
            throw({could_not_get_filters, Err});
        {ok, Routing} ->
            blockchain_ledger_routing_v1:filters(Routing)
    end.

-spec read_devices_from_disk() -> {ok, map()}.
read_devices_from_disk() ->
    {ok, DB, CF} = router_db:get_xor_filter_devices(),

    List = get_fold(
        DB,
        CF,
        fun
            (#{eui := _EUI, filter_index := FilterIndex, device_id := _DeviceID} = Entry) ->
                {true, {FilterIndex, Entry}};
            (_) ->
                false
        end
    ),

    Collected = [{Key, proplists:get_all_values(Key, List)} || Key <- lists:seq(0, 4)],
    {ok, maps:from_list(Collected)}.

-spec get_fold(
    DB :: rocksdb:db_handle(),
    CF :: rocksdb:cf_handle(),
    FilterTransformFun :: fun((map()) -> {true, ReturnType} | false)
) -> [ReturnType].
get_fold(DB, CF, FilterTransformFun) ->
    {ok, Itr} = rocksdb:iterator(DB, CF, []),
    First = rocksdb:iterator_move(Itr, first),
    Acc = get_fold(DB, CF, Itr, First, FilterTransformFun, []),
    rocksdb:iterator_close(Itr),
    Acc.

-spec get_fold(
    DB :: rocksdb:db_handle(),
    CF :: rocksdb:cf_handle(),
    Iterator :: rocksdb:itr_handle(),
    RocksDBEntry :: any(),
    FilterTransformFun :: fun((...) -> ReturnType),
    Accumulator :: list()
) -> [ReturnType].
get_fold(DB, CF, Itr, {ok, _K, Bin}, FilterTransformFun, Acc) ->
    Next = rocksdb:iterator_move(Itr, next),
    Device = erlang:binary_to_term(Bin),
    case FilterTransformFun(Device) of
        {true, Val} -> get_fold(DB, CF, Itr, Next, FilterTransformFun, [Val | Acc]);
        false -> get_fold(DB, CF, Itr, Next, FilterTransformFun, Acc)
    end;
get_fold(DB, CF, Itr, {ok, _}, FilterTransformFun, Acc) ->
    Next = rocksdb:iterator_move(Itr, next),
    get_fold(DB, CF, Itr, Next, FilterTransformFun, Acc);
get_fold(_DB, _CF, _Itr, {error, _}, _FilterTransformFun, Acc) ->
    Acc.

-spec diff_filter_to_devices(
    OldMapping :: filter_eui_mapping(),
    NewMapping :: filter_eui_mapping()
) -> {Added :: filter_eui_mapping(), Removed :: filter_eui_mapping()}.
diff_filter_to_devices(OldMapping, NewMapping) ->
    OldSorted = lists:sort(maps:to_list(OldMapping)),
    NewSorted = lists:sort(maps:to_list(NewMapping)),

    {ToBeAdded, ToBeRemoved} = lists:unzip([
        {
            {Key, NewFilter -- OldFilter},
            {Key, OldFilter -- NewFilter}
        }
        || {{Key, OldFilter}, {Key, NewFilter}} <- lists:zip(OldSorted, NewSorted)
    ]),
    {
        maps:from_list(ToBeAdded),
        maps:from_list(ToBeRemoved)
    }.

-spec update_console_api(
    Added :: filter_eui_mapping(),
    Removed :: filter_eui_mapping()
) -> ok.
update_console_api(Added, Removed) ->
    AddedDevs = maps:values(Added),
    RemovedDevs = maps:values(Removed),
    AddedIDs = [maps:get(device_id, Dev) || Dev <- lists:flatten(AddedDevs)],
    RemovedIDs = [maps:get(device_id, Dev) || Dev <- lists:flatten(RemovedDevs)],
    ok = router_console_api:xor_filter_updates(AddedIDs, RemovedIDs).

-spec sync_cache_to_disk(
    Added :: filter_eui_mapping(),
    Removed :: filter_eui_mapping()
) -> ok.
sync_cache_to_disk(Added, Removed) ->
    ok = remove_devices_from_disk(lists:flatten(maps:values(Removed))),
    ok = write_devices_to_disk(lists:flatten(maps:values(Added))).

-spec remove_devices_from_disk(devices_dev_eui_app_eui()) -> ok.
remove_devices_from_disk(DevicesToRemove) ->
    {ok, DB, CF} = router_db:get_xor_filter_devices(),
    lists:foreach(
        fun(#{eui := DeviceEUI} = _Device) ->
            rocksdb:delete(DB, CF, DeviceEUI, [])
        end,
        DevicesToRemove
    ).

-spec write_devices_to_disk(devices_dev_eui_app_eui()) -> ok.
write_devices_to_disk(DevicesToAdd) ->
    {ok, DB, CF} = router_db:get_xor_filter_devices(),
    lists:foreach(
        fun(#{eui := DeviceEUI} = Entry) ->
            case rocksdb:put(DB, CF, DeviceEUI, erlang:term_to_binary(Entry), []) of
                {error, _} = Err ->
                    lager:error("xor filter failed to write to rocksdb: ~p", [Err]),
                    throw(Err);
                ok ->
                    ok
            end
        end,
        DevicesToAdd
    ).

-spec estimate_cost(#state{}) -> noop | {non_neg_integer(), non_neg_integer()}.
estimate_cost(#state{
    pubkey = PubKey,
    sig_fun = SigFun,
    chain = Chain,
    oui = OUI,
    filter_to_devices = FilterToDevices
}) ->
    %% TODO: Add some logic here to get a better picture of what is going to
    %% happen next run. Probably need to unroll the should_update ->
    %% contained_in_filters -> craft_updates function stuff.

    %% TODO: Also maybe break out the getting the diff logic when sending stuff to
    %% the API for use here. That could make some things easier.
    case should_update_filters(Chain, OUI, FilterToDevices) of
        noop ->
            noop;
        {_Routing, Updates} ->
            lists:foldl(
                fun
                    ({new, NewDevicesDevEuiAppEui}, {Cost, N}) ->
                        Filter = new_xor_filter(NewDevicesDevEuiAppEui),
                        Txn = craft_new_filter_txn(PubKey, SigFun, Chain, OUI, Filter, 1),
                        {Cost + blockchain_txn_routing_v1:calculate_fee(Txn, Chain),
                            N + erlang:length(NewDevicesDevEuiAppEui)};
                    ({update, Index, NewDevicesDevEuiAppEui}, {Cost, N}) ->
                        Filter = new_xor_filter(NewDevicesDevEuiAppEui),
                        Txn = craft_update_filter_txn(PubKey, SigFun, Chain, OUI, Filter, 1, Index),
                        {Cost + blockchain_txn_routing_v1:calculate_fee(Txn, Chain),
                            N + erlang:length(NewDevicesDevEuiAppEui)}
                end,
                {0, 0},
                Updates
            )
    end.

-spec distribute_devices_across_n_groups(devices_dev_eui_app_eui(), non_neg_integer()) ->
    list(list(devices_dev_eui_app_eui())).
distribute_devices_across_n_groups(Devices, FilterCount) ->
    %% Add 0.4 to more consistenly round up
    GroupSize = erlang:round((erlang:length(Devices) / FilterCount) + 0.4),
    do_distribute_devices_across_n_groups(Devices, GroupSize, []).

-spec do_distribute_devices_across_n_groups(
    Devices :: devices_dev_eui_app_eui(),
    GroupSize :: non_neg_integer(),
    Groups :: list(list(devices_dev_eui_app_eui()))
) -> list(list(devices_dev_eui_app_eui())).
do_distribute_devices_across_n_groups([], _, G) ->
    G;
do_distribute_devices_across_n_groups(Devices, GroupSize, Grouped) ->
    {Group, Leftover} = lists:split(erlang:min(GroupSize, erlang:length(Devices)), Devices),
    do_distribute_devices_across_n_groups(Leftover, GroupSize, [Group | Grouped]).

-spec should_update_filters(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    FilterToDevices :: map()
) -> noop | {blockchain_ledger_routing_v1:routing(), [update()]}.
should_update_filters(Chain, OUI, FilterToDevices) ->
    case router_console_api:get_all_devices() of
        {error, _Reason} ->
            lager:error("failed to get device ~p", [_Reason]),
            noop;
        {ok, Devices} ->
            DevicesDevEuiAppEui = get_devices_deveui_app_eui(Devices),
            Ledger = blockchain:ledger(Chain),
            case blockchain_ledger_v1:find_routing(OUI, Ledger) of
                {error, _Reason} ->
                    lager:error("failed to find routing for OUI: ~p ~p", [OUI, _Reason]),
                    noop;
                {ok, Routing} ->
                    {ok, MaxXorFilter} = blockchain:config(max_xor_filter_num, Ledger),
                    BinFilters = blockchain_ledger_routing_v1:filters(Routing),
                    Updates = contained_in_filters(
                        BinFilters,
                        FilterToDevices,
                        DevicesDevEuiAppEui
                    ),
                    case craft_updates(Updates, BinFilters, MaxXorFilter) of
                        noop -> noop;
                        Crafted -> {Routing, Crafted}
                    end
            end
    end.

-spec craft_updates(
    {Current :: map(), Added :: [binary()], Remove :: map()},
    Filters :: [binary()],
    MaxFilters :: non_neg_integer()
) -> noop | [update()].
craft_updates(Updates, BinFilters, MaxXorFilter) ->
    case Updates of
        {_Map, [], Removed} when Removed == #{} ->
            noop;
        {Map, Added, Removed} when Removed == #{} ->
            case erlang:length(BinFilters) < MaxXorFilter of
                true ->
                    [{new, Added}];
                false ->
                    case smallest_first(maps:to_list(Map)) of
                        [] ->
                            [{update, 0, Added}];
                        [{Index, SmallestDevicesDevEuiAppEui} | _] ->
                            [{update, Index, Added ++ SmallestDevicesDevEuiAppEui}]
                    end
            end;
        {Map, [], Removed} ->
            craft_remove_updates(Map, Removed);
        {Map, Added, Removed} ->
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
            Entry = #{
                eui => DevEUiAppEUI,
                filter_index => unset,
                device_id => router_device:id(Device)
            },
            get_devices_deveui_app_eui(Devices, [Entry | DevEUIsAppEUIs])
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

-spec craft_remove_updates(map(), map()) -> [update()].
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

assign_filter_index(Index, DeviceEuis) -> [N#{filter_index => Index} || N <- DeviceEuis].

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
    ContainedBy = fun(Filter) ->
        fun(#{eui := Bin}) ->
            xor16:contain({Filter, ?HASH_FUN}, Bin)
        end
    end,

    %% Key known devices by device id
    Keyed = lists:foldl(
        fun(#{device_id := DevID, eui := EUI} = Elem, Acc) ->
            Acc#{{DevID, EUI} => Elem}
        end,
        #{},
        lists:flatten(maps:values(FilterToDevices))
    ),
    %% subtract new devices from list
    IncomingDevIds = [{DID, EUI} || #{device_id := DID, eui := EUI} <- DevicesDevEuiAppEui],
    MaybeRemovedDevices = lists:flatten(maps:values(maps:without(IncomingDevIds, Keyed))),

    {CurrFilter, Removed, Added, _} =
        lists:foldl(
            fun({Index, Filter}, {InFilterAcc0, RemovedAcc0, AddedToCheck, RemovedToCheck}) ->
                {AddedInFilter, AddedLeftover} = lists:partition(
                    ContainedBy(Filter),
                    AddedToCheck
                ),
                InFilterAcc1 =
                    case AddedInFilter == [] of
                        false ->
                            maps:put(
                                Index,
                                assign_filter_index(Index, AddedInFilter),
                                InFilterAcc0
                            );
                        true ->
                            InFilterAcc0
                    end,
                {RemovedInFilter, RemovedLeftover} = lists:partition(
                    ContainedBy(Filter),
                    RemovedToCheck
                ),
                RemovedAcc1 =
                    case RemovedInFilter == [] of
                        false ->
                            maps:put(
                                Index,
                                assign_filter_index(Index, RemovedInFilter),
                                RemovedAcc0
                            );
                        true ->
                            RemovedAcc0
                    end,
                {InFilterAcc1, RemovedAcc1, AddedLeftover, RemovedLeftover}
            end,
            {#{}, #{}, DevicesDevEuiAppEui, MaybeRemovedDevices},
            enumerate_0(BinFilters)
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

-spec enumerate_0(list(T)) -> list({non_neg_integer(), T}).
enumerate_0(L) ->
    lists:zip(lists:seq(0, erlang:length(L) - 1), L).

-spec new_xor_filter(devices_dev_eui_app_eui()) -> Filter :: reference().
new_xor_filter(DeviceEntries) ->
    IDS = [ID || #{eui := ID} <- DeviceEntries],
    {Filter, _} = xor16:new(IDS, ?HASH_FUN),
    Filter.

-spec is_unset_filter_index_in_list(
    device_dev_eui_app_eui(),
    devices_dev_eui_app_eui()
) -> boolean().
is_unset_filter_index_in_list(#{eui := EUI1, device_id := ID1}, L) ->
    lists:any(
        fun(#{eui := EUI2, device_id := ID2}) ->
            EUI1 == EUI2 andalso ID1 == ID2
        end,
        L
    ).

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

-endif.
