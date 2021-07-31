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
    rebalance_filters/0,
    migrate_filter/3,
    get_balanced_filters/0,
    commit_groups_to_filters/1,
    refresh_cache/0,
    get_device_updates/0,
    reset_db/1
]).

-export([
    deveui_appeui/1,
    get_devices_deveui_app_eui/1
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
    filter_to_devices = #{} :: filter_eui_mapping(),
    check_filters_ref :: undefined | reference()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec estimate_cost() ->
    noop
    | {
        ok,
        Cost :: non_neg_integer(),
        AddedDevices :: devices_dev_eui_app_eui(),
        RemovedDevices :: filter_eui_mapping()
    }.
estimate_cost() ->
    gen_server:call(?SERVER, estimate_cost, infinity).

-spec reset_db(boolean()) ->
    {error, atom(), any()}
    | {
        ok,
        Updates :: {
            Curent :: filter_eui_mapping(),
            Added :: devices_dev_eui_app_eui(),
            Removed :: filter_eui_mapping()
        },
        BinFilters :: [binary()],
        Routing :: blockchain_ledger_routin_v1:routing()
    }.
reset_db(Commit) ->
    gen_server:call(?SERVER, {reset_db, Commit}).

-spec get_device_updates() ->
    {ok, filter_eui_mapping(), devices_dev_eui_app_eui(), filter_eui_mapping()}.
get_device_updates() ->
    gen_server:call(?SERVER, get_device_updates).

-spec check_filters() -> ok.
check_filters() ->
    ?SERVER ! ?CHECK_FILTERS_TICK,
    ok.

-spec rebalance_filters() -> ok.
rebalance_filters() ->
    gen_server:cast(?SERVER, ?REBALANCE_FILTERS).

-spec migrate_filter(From :: 0..4, To :: 0..4, Commit :: boolean()) ->
    {ok, CurrentMapping :: filter_eui_mapping(), ChangedFilters :: filter_eui_mapping(),
        Costs :: #{0..4 => non_neg_integer()}}.
migrate_filter(From, To, Commit) ->
    gen_server:call(?SERVER, {migrate_filter, From, To, Commit}, infinity).

-spec get_balanced_filters() -> {ok, Old :: filter_eui_mapping(), New :: filter_eui_mapping()}.
get_balanced_filters() ->
    gen_server:call(?SERVER, get_balanced_filters, infinity).

-spec commit_groups_to_filters(filter_eui_mapping()) ->
    {ok, NewPending :: #{binary() => {0..4, devices_dev_eui_app_eui()}}}.
commit_groups_to_filters(NewGroups) ->
    gen_server:call(?SERVER, {commit_groups_to_filters, NewGroups}).

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
    {ok, #state{
        pubkey = PubKey,
        sig_fun = SigFun,
        filter_to_devices = maps:from_list([{X, []} || X <- lists:seq(0, 4)])
    }}.

handle_call(estimate_cost, _From, State) ->
    Reply = estimate_cost(State),
    lager:info("estimating cost ~p", [Reply]),
    {reply, Reply, State};
handle_call(
    {reset_db, Commit},
    _From,
    #state{chain = Chain, oui = OUI, filter_to_devices = FilterToDevices} = State
) ->
    case {Commit, get_device_updates(Chain, OUI, FilterToDevices)} of
        {false, {ok, {_, _, _}, _, _} = Updates} ->
            {reply, Updates, State};
        {true, {ok, {Curr, _, _}, _, _} = Updates} ->
            lager:info("committing device updates ~p", [Updates]),
            ok = empty_rocksdb(),
            Added = lists:flatten(maps:values(Curr)),
            ok = sync_cache_to_disk(Added, _Removed = []),
            {ok, NewFilterToDevices} = read_devices_from_disk(),
            {reply, Updates, State#state{filter_to_devices = NewFilterToDevices}};
        {_, Response} ->
            lager:warning("unexpected trying to reset xor db [commit: ~p] ~p", [
                Commit,
                Response
            ]),
            {reply, Response, State}
    end;
handle_call(
    get_device_updates,
    _From,
    #state{chain = Chain, oui = OUI, filter_to_devices = FilterToDevices} = State
) ->
    Reply = get_device_updates(Chain, OUI, FilterToDevices),
    lager:info("getting device updates ~p", [Reply]),
    {reply, Reply, State};
handle_call(report_timer, _From, #state{check_filters_ref = Timer} = State) ->
    {reply, Timer, State};
handle_call(
    report_filter_sizes,
    _From,
    #state{chain = Chain, oui = OUI, filter_to_devices = FilterToDevices} = State
) ->
    case get_filters(Chain, OUI) of
        {error, _Reason} = Err ->
            {reply, Err, State};
        {ok, Filters, _Routing} ->
            Reply = [
                {routing, enumerate_0([byte_size(F) || F <- Filters])},
                {in_memory, [
                    {Idx, erlang:length(Devs)}
                    || {Idx, Devs} <- maps:to_list(FilterToDevices)
                ]}
            ],
            {reply, Reply, State}
    end;
handle_call(
    {report_device_status, Device},
    _From,
    #state{chain = Chain, oui = OUI, filter_to_devices = FilterToDevices} = State
) ->
    case get_filters(Chain, OUI) of
        {error, _Reason} = Err ->
            {reply, Err, State};
        {ok, BinFilters, _Routing} ->
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

            {reply, Reply, State}
    end;
handle_call(refresh_cache, _From, State) ->
    {ok, FilterToDevices} = read_devices_from_disk(),
    {reply, ok, State#state{filter_to_devices = FilterToDevices}};
handle_call(get_balanced_filters, _From, #state{filter_to_devices = FilterToDevices} = State) ->
    Reply = get_balanced_filters(FilterToDevices),
    {reply, Reply, State};
handle_call(
    {commit_groups_to_filters, NewGroups},
    _From,
    #state{pending_txns = CurrentPending} = State
) ->
    {ok, NewPending} = commit_groups_to_filters(NewGroups, State),
    NewPendingTxns = maps:merge(CurrentPending, NewPending),
    {reply, {ok, NewPendingTxns}, State#state{pending_txns = NewPendingTxns}};
handle_call(
    {migrate_filter, FromIndex, ToIndex, Commit},
    _From,
    #state{pending_txns = CurrentPendingTxns, filter_to_devices = FilterToDevices} = State
) ->
    lager:info("migrating: filter ~p to ~p", [FromIndex, ToIndex]),

    MigratedFilters = get_migrated_filter_group(FromIndex, ToIndex, FilterToDevices),
    Costs = estimate_cost_for_groups(MigratedFilters, State),

    lager:info(
        "migrating: proposed group size: ~p, cost: ~p",
        [maps:map(fun(_, V) -> length(V) end, MigratedFilters), Costs]
    ),

    NewPendingTxns =
        case Commit of
            true ->
                lager:info("migrating: comitting groups to filters"),
                {ok, NewPending} = commit_groups_to_filters(MigratedFilters, State),
                NewPending;
            false ->
                lager:info("migrating: DRY RUN---"),
                #{}
        end,

    Reply = {ok, FilterToDevices, MigratedFilters, Costs},

    {reply, Reply, State#state{pending_txns = maps:merge(CurrentPendingTxns, NewPendingTxns)}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    ?REBALANCE_FILTERS,
    #state{pending_txns = CurrentPending, filter_to_devices = FilterToDevices} = State
) ->
    {ok, _OldGroup, NewGroups} = get_balanced_filters(FilterToDevices),
    {ok, NewPending} = commit_groups_to_filters(NewGroups, State),

    {noreply, State#state{pending_txns = maps:merge(CurrentPending, NewPending)}};
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
        {update_cache, CurrentFilterToDevices} ->
            lager:info(
                "filters are still up to date, devices have maybe have changed, updating cache"
            ),
            Ref = schedule_check_filters(default_timer()),
            ok = do_updates_from_filter_to_devices_diff(FilterToDevices, CurrentFilterToDevices),
            {noreply, State#state{
                check_filters_ref = Ref,
                filter_to_devices = maps:merge(FilterToDevices, CurrentFilterToDevices)
            }};
        {Routing, Updates, CurrentMapping} ->
            CurrNonce = blockchain_ledger_routing_v1:nonce(Routing),
            BinFilters = blockchain_ledger_routing_v1:filters(Routing),

            %% Remove potential updates that will create a filter that already
            %% exists. This might happen because we track devices by more
            %% information that just the EUIs, and only want to update/create
            %% filters when encountering new EUIs.
            UpdatesToSubmit =
                lists:filtermap(
                    fun
                        ({new, NewDevicesDevEuiAppEui}) ->
                            {ok, Filter, Bin} = new_xor_filter_and_bin(NewDevicesDevEuiAppEui),
                            case lists:member(Bin, BinFilters) of
                                true ->
                                    lager:error(
                                        "trying to create a new filter that already exists, dropping"
                                    ),
                                    false;
                                false ->
                                    {true, {new, Filter, NewDevicesDevEuiAppEui}}
                            end;
                        ({update, Index, NewDevicesDevEuiAppEui}) ->
                            Existing = lists:nth(Index + 1, BinFilters),
                            {ok, Filter, Bin} = new_xor_filter_and_bin(NewDevicesDevEuiAppEui),
                            case Existing == Bin of
                                true ->
                                    false;
                                false ->
                                    {true, {update, Index, Filter, NewDevicesDevEuiAppEui}}
                            end
                    end,
                    Updates
                ),

            {Pendings1, _} = lists:foldl(
                fun
                    ({new, Filter, NewDevicesDevEuiAppEui}, {Pendings, Nonce}) ->
                        lager:info("adding new filter"),
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
                    ({update, Index, Filter, NewDevicesDevEuiAppEui}, {Pendings, Nonce}) ->
                        lager:info("updating filter @ index ~p", [Index]),
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
                UpdatesToSubmit
            ),

            %% Update for devices that may have not caused a txn
            PendingIndexes = [Idx || {Idx, _} <- maps:values(Pendings1)],
            FilterToDevices1 = maps:merge(
                FilterToDevices,
                maps:without(PendingIndexes, CurrentMapping)
            ),
            ok = do_updates_from_filter_to_devices_diff(FilterToDevices, FilterToDevices1),

            {noreply, State#state{pending_txns = Pendings1, filter_to_devices = FilterToDevices1}}
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

    ok = do_updates_from_filter_to_devices_diff(
        State0#state.filter_to_devices,
        State1#state.filter_to_devices
    ),

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

-spec get_balanced_filters(filter_eui_mapping()) ->
    {ok, CurrentMapping :: filter_eui_mapping(), ProposedMapping :: filter_eui_mapping()}.
get_balanced_filters(FilterToDevices) ->
    BalancedFilterToDevices =
        case router_console_api:get_all_devices() of
            {error, _Reason} ->
                lager:error("failed to get devices ~p", [_Reason]),
                {error, {could_not_rebalance_filters, _Reason}};
            {ok, Devices} ->
                DevicesDevEuiAppEUI = get_devices_deveui_app_eui(Devices),
                Grouped = distribute_devices_across_n_groups(DevicesDevEuiAppEUI, 5),
                maps:from_list([
                    {Idx, assign_filter_index(Idx, Group)}
                    || {Idx, Group} <- enumerate_0(Grouped)
                ])
        end,
    {ok, FilterToDevices, BalancedFilterToDevices}.

-spec commit_groups_to_filters(ProposedMapping :: filter_eui_mapping(), #state{}) ->
    {ok,
        PendingTxns :: #{
            blockchain_txn:hash() => {FilterIndex :: 0..4, Devices :: devices_dev_eui_app_eui()}
        }}.
commit_groups_to_filters(NewGroups, #state{chain = Chain, oui = OUI} = State) ->
    Ledger = blockchain:ledger(Chain),
    {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),
    CurrNonce = blockchain_ledger_routing_v1:nonce(Routing),
    NewPending0 =
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
            maps:to_list(NewGroups)
        ),
    {ok, maps:from_list(NewPending0)}.

-spec estimate_cost_for_groups(Groups :: filter_eui_mapping(), #state{}) ->
    #{FilterIndex :: 0..4 => Cost :: non_neg_integer()}.
estimate_cost_for_groups(Groups, #state{chain = Chain, oui = OUI} = State) ->
    Ledger = blockchain:ledger(Chain),
    {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),
    CurrNonce = blockchain_ledger_routing_v1:nonce(Routing),

    maps:map(
        fun(Idx, GroupEuis) ->
            Nonce = CurrNonce + Idx + 1,
            Filter = new_xor_filter(GroupEuis),
            Txn = craft_rebalance_update_filter_txn(Idx, Nonce, Filter, State),
            Cost = blockchain_txn_routing_v1:calculate_fee(Txn, Chain),

            Cost
        end,
        Groups
    ).

-spec get_migrated_filter_group(
    FromIndex :: 0..4,
    ToIndex :: 0..4,
    FilterToDevices :: filter_eui_mapping()
) -> filter_eui_mapping().
get_migrated_filter_group(FromIndex, ToIndex, FilterToDevices) ->
    ToDevices = maps:get(ToIndex, FilterToDevices),
    FromDevices = maps:get(FromIndex, FilterToDevices),
    CombinedDevices = ToDevices ++ FromDevices,
    lager:info(
        "constructing filter mgiration: ~p (~p devices) to ~p (~p devices), total (~p devices)",
        [FromIndex, length(FromDevices), ToIndex, length(ToDevices), length(CombinedDevices)]
    ),
    #{
        ToIndex => CombinedDevices,
        FromIndex => []
    }.

-spec get_filters(blockchain:blockchain(), non_neg_integer()) ->
    {error, any()}
    | {ok, list(binary()), blockchain_ledger_routing_v1:routing()}.

get_filters(Chain, OUI) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_routing(OUI, Ledger) of
        {error, _Reason} = Err ->
            lager:error("failed to find routing for OUI: ~p ~p", [OUI, _Reason]),
            Err;
        {ok, Routing} ->
            {ok, blockchain_ledger_routing_v1:filters(Routing), Routing}
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
        true -> get_fold(DB, CF, Itr, Next, FilterTransformFun, [Device | Acc]);
        {true, Val} -> get_fold(DB, CF, Itr, Next, FilterTransformFun, [Val | Acc]);
        false -> get_fold(DB, CF, Itr, Next, FilterTransformFun, Acc)
    end;
get_fold(DB, CF, Itr, {ok, _}, FilterTransformFun, Acc) ->
    Next = rocksdb:iterator_move(Itr, next),
    get_fold(DB, CF, Itr, Next, FilterTransformFun, Acc);
get_fold(_DB, _CF, _Itr, {error, _}, _FilterTransformFun, Acc) ->
    Acc.

-spec do_updates_from_filter_to_devices_diff(
    OldFilterToDevices :: filter_eui_mapping(),
    NewFilterToDevices :: filter_eui_mapping()
) -> ok.
do_updates_from_filter_to_devices_diff(OldFilterToDevices, NewFilterToDevices) ->
    {AddedDevices, RemovedDevices} = filter_to_devices_diff(
        OldFilterToDevices,
        NewFilterToDevices
    ),
    ok = update_console_api(AddedDevices, RemovedDevices),
    ok = sync_cache_to_disk(AddedDevices, RemovedDevices).

-spec filter_to_devices_diff(
    OldMapping :: filter_eui_mapping(),
    NewMapping :: filter_eui_mapping()
) -> {Added :: devices_dev_eui_app_eui(), Removed :: devices_dev_eui_app_eui()}.
filter_to_devices_diff(OldMapping, NewMapping) ->
    BaseEmpty = maps:from_list([{X, []} || X <- lists:seq(0, 4)]),
    OldSorted = lists:sort(maps:to_list(maps:merge(BaseEmpty, OldMapping))),
    NewSorted = lists:sort(maps:to_list(maps:merge(BaseEmpty, NewMapping))),

    {ToBeAdded, ToBeRemoved} = lists:unzip([
        {
            NewFilter -- OldFilter,
            OldFilter -- NewFilter
        }
        || {{Key, OldFilter}, {Key, NewFilter}} <- lists:zip(OldSorted, NewSorted)
    ]),
    {
        lists:flatten(ToBeAdded),
        lists:flatten(ToBeRemoved)
    }.

-spec update_console_api(
    Added :: devices_dev_eui_app_eui(),
    Removed :: devices_dev_eui_app_eui()
) -> ok.
update_console_api(Added, Removed) ->
    AddedIDs = [maps:get(device_id, Dev) || Dev <- lists:flatten(Added)],
    RemovedIDs = [maps:get(device_id, Dev) || Dev <- lists:flatten(Removed)],
    ok = router_console_api:xor_filter_updates(AddedIDs, RemovedIDs).

-spec sync_cache_to_disk(
    Added :: devices_dev_eui_app_eui(),
    Removed :: devices_dev_eui_app_eui()
) -> ok.
sync_cache_to_disk(Added, Removed) ->
    ok = remove_devices_from_disk(Removed),
    ok = write_devices_to_disk(Added).

-spec remove_devices_from_disk(devices_dev_eui_app_eui()) -> ok.
remove_devices_from_disk(DevicesToRemove) ->
    {ok, DB, CF} = router_db:get_xor_filter_devices(),
    lists:foreach(
        fun(#{device_id := DeviceID, eui := DeviceEUI} = _Device) ->
            rocksdb:delete(DB, CF, <<DeviceID/binary, DeviceEUI/binary>>, [])
        end,
        DevicesToRemove
    ).

-spec write_devices_to_disk(devices_dev_eui_app_eui()) -> ok.
write_devices_to_disk(DevicesToAdd) ->
    {ok, DB, CF} = router_db:get_xor_filter_devices(),
    lists:foreach(
        fun(#{device_id := DeviceID, eui := DeviceEUI} = Entry) ->
            case
                rocksdb:put(
                    DB,
                    CF,
                    <<DeviceID/binary, DeviceEUI/binary>>,
                    erlang:term_to_binary(Entry),
                    []
                )
            of
                {error, _} = Err ->
                    lager:error("xor filter failed to write to rocksdb: ~p", [Err]),
                    throw(Err);
                ok ->
                    ok
            end
        end,
        DevicesToAdd
    ).

-spec empty_rocksdb() -> ok | {error, any()}.
empty_rocksdb() ->
    {ok, DB, CF} = router_db:get_xor_filter_devices(),
    List = get_fold(DB, CF, fun(_) -> true end),
    remove_devices_from_disk(List).

-spec estimate_cost(#state{}) ->
    noop
    | {ok, Cost :: non_neg_integer(), AddedDevices :: devices_dev_eui_app_eui(),
        RemovedDevices :: filter_eui_mapping()}.
estimate_cost(
    #state{
        pubkey = PubKey,
        sig_fun = SigFun,
        chain = Chain,
        filter_to_devices = FilterToDevices,
        oui = OUI
    }
) ->
    case get_device_updates(Chain, OUI, FilterToDevices) of
        {error, _Reason, _Err} ->
            noop;
        {ok, Updates, BinFilters, _Routing} ->
            Ledger = blockchain:ledger(Chain),
            {ok, MaxXorFilter} = blockchain:config(max_xor_filter_num, Ledger),

            CraftedFilters =
                case craft_updates(Updates, BinFilters, MaxXorFilter) of
                    noop -> [];
                    V -> V
                end,

            EstimatedCosts = lists:map(
                fun
                    ({new, NewDevicesDevEuiAppEui}) ->
                        Filter = new_xor_filter(NewDevicesDevEuiAppEui),
                        Txn = craft_new_filter_txn(PubKey, SigFun, Chain, OUI, Filter, 1),
                        blockchain_txn_routing_v1:calculate_fee(Txn, Chain);
                    ({update, Index, NewDevicesDevEuiAppEui}) ->
                        Filter = new_xor_filter(NewDevicesDevEuiAppEui),
                        Txn = craft_update_filter_txn(PubKey, SigFun, Chain, OUI, Filter, 1, Index),
                        blockchain_txn_routing_v1:calculate_fee(Txn, Chain)
                end,
                CraftedFilters
            ),

            {_Curr, Added, Removed} = Updates,
            {ok, lists:sum(EstimatedCosts), Added, Removed}
    end.

-spec get_device_updates(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    FilterToDevices :: filter_eui_mapping()
) ->
    {error, atom(), any()}
    | {
        ok,
        Updates :: tuple(),
        BinFilters :: [binary()],
        Routing :: blockchain_ledger_routin_v1:routing()
    }.
get_device_updates(Chain, OUI, FilterToDevices) ->
    case router_console_api:get_all_devices() of
        {error, _Reason} ->
            {error, could_not_get_devices, _Reason};
        {ok, Devices} ->
            DeviceEUIs = get_devices_deveui_app_eui(Devices),
            case get_filters(Chain, OUI) of
                {error, _Reason} ->
                    {error, could_not_get_filters, _Reason};
                {ok, BinFilters, Routing} ->
                    Updates = contained_in_filters(
                        BinFilters,
                        FilterToDevices,
                        DeviceEUIs
                    ),
                    {ok, Updates, BinFilters, Routing}
            end
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
) ->
    noop
    | {update_cache, filter_eui_mapping()}
    | {blockchain_ledger_routing_v1:routing(), [update()], filter_eui_mapping()}.
should_update_filters(Chain, OUI, FilterToDevices) ->
    case get_device_updates(Chain, OUI, FilterToDevices) of
        {error, could_not_get_devices, _Reason} ->
            lager:error("failed to get device ~p", [_Reason]),
            noop;
        {error, could_not_get_filters, _Reason} ->
            lager:error("failed to find routing for OUI: ~p ~p", [OUI, _Reason]),
            noop;
        {ok, {Curr, _, _} = Updates, BinFilters, Routing} ->
            Ledger = blockchain:ledger(Chain),
            {ok, MaxXorFilter} = blockchain:config(max_xor_filter_num, Ledger),
            case craft_updates(Updates, BinFilters, MaxXorFilter) of
                noop ->
                    {update_cache, Curr};
                Crafted ->
                    {Routing, Crafted, Curr}
            end
    end.

-spec craft_updates(
    {Current :: map(), Added :: [binary()], Remove :: map()},
    Filters :: [binary()],
    MaxFilters :: non_neg_integer()
) -> noop | [update()].
craft_updates(Updates, BinFilters, MaxXorFilter) ->
    case Updates of
        {_Map, [], _Removed} ->
            noop;
        {Map, Added, Removed} ->
            case erlang:length(BinFilters) < MaxXorFilter of
                true ->
                    [{new, Added}];
                false ->
                    case smallest_first(maps:to_list(Map)) of
                        [] ->
                            [{update, 0, Added}];
                        [{Index, SmallestDevicesDevEuiAppEui} | _] ->
                            %% NOTE: we only remove from filters we're updating
                            %% with devices to add. Removes aren't as important
                            %% as adds, and can incur unnecessary costs.
                            AddedDevices = Added ++ SmallestDevicesDevEuiAppEui,
                            [{update, Index, AddedDevices -- maps:get(Index, Removed, [])}]
                    end
            end
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

-spec assign_filter_index(Index :: non_neg_integer(), list()) -> list().
assign_filter_index(Index, DeviceEuis) when is_list(DeviceEuis) ->
    [N#{filter_index => Index} || N <- DeviceEuis].

%% Return {map of IN FILTER device_dev_eui_app_eui indexed by their filter,
%%         list of added device
%%         map of REMOVED device_dev_eui_app_eui indexed by their filter}
-spec contained_in_filters(
    BinFilters :: list(binary()),
    FilterToDevices :: map(),
    DevicesDevEuiAppEui :: devices_dev_eui_app_eui()
) ->
    {
        Curent :: filter_eui_mapping(),
        Added :: devices_dev_eui_app_eui(),
        Removed :: filter_eui_mapping()
    }.
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
    {Filter, _} = xor16:new(lists:usort(IDS), ?HASH_FUN),
    Filter.

-spec new_xor_filter_and_bin(devices_dev_eui_app_eui()) ->
    {ok, Filter :: reference(), Bin :: binary()}.
new_xor_filter_and_bin(Devices) ->
    Filter = new_xor_filter(Devices),
    {Bin, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    {ok, Filter, Bin}.

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

device_deveui_appeui(Device) ->
    [D] = get_devices_deveui_app_eui([Device]),
    D.

assign_filter_index_map(Index, DeviceEui) ->
    DeviceEui#{filter_index => Index}.

new_xor_filter_bin(Devices) ->
    Filter = new_xor_filter(Devices),
    {Bin, _} = xor16:to_bin({Filter, ?HASH_FUN}),
    {ok, Bin}.

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
    meck:expect(router_console_api, get_all_devices, fun() ->
        {error, no_devices_on_purpose}
    end),

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

    {ok, BinFilter} = new_xor_filter_bin([device_deveui_appeui(Device0)]),
    Routing0 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, Routing0}
    end),

    ?assertMatch({update_cache, _}, should_update_filters(chain, OUI, #{})),

    %% ------------------------
    %% Testing if a device was added
    {ok, BinEmptyFilter} = new_xor_filter_bin([]),
    EmptyRouting = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinEmptyFilter, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, EmptyRouting}
    end),

    ExpectedNewFilter0 = [{new, get_devices_deveui_app_eui([Device0])}],
    ?assertMatch(
        {EmptyRouting, ExpectedNewFilter0, _CurrentMapping},
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

    ExpectedUpdateFilter0 = [
        {update, 0, [
            device_deveui_appeui(Device1),
            %% Already in the filter
            assign_filter_index_map(0, device_deveui_appeui(Device0))
        ]}
    ],
    ?assertMatch(
        {Routing0, ExpectedUpdateFilter0, _CurrentMapping},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Testing that we removed Device0
    meck:expect(blockchain, config, fun(_, _) -> {ok, 2} end),
    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device1]}
    end),

    %% We're not removing device0 from filter0. Need to add device1, that goes
    %% into a new filter because we have room.
    ExpectedNewFilter1 = [{new, get_devices_deveui_app_eui([Device1])}],
    ?assertMatch(
        {Routing0, ExpectedNewFilter1, _CurrentMapping},
        should_update_filters(chain, OUI, #{
            0 => assign_filter_index(0, get_devices_deveui_app_eui([Device0]))
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

    %% We're not removing device0 from filter0. Need ot add device1 and device2,
    %% that goes into a new filter because we have room.
    ExpectedNewFilter2 = [{new, get_devices_deveui_app_eui([Device1, Device2])}],
    ?assertMatch(
        {Routing0, ExpectedNewFilter2, _CurrentMapping},
        should_update_filters(chain, OUI, #{
            0 => get_devices_deveui_app_eui([Device0])
        })
    ),

    %% ------------------------
    % Testing that we removed Device0 and Device1 but from diff filters
    {ok, BinFilter0} = new_xor_filter_bin([device_deveui_appeui(Device0)]),
    RoutingRemoved0 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter0, [], 1),
    {ok, BinFilter1} = new_xor_filter_bin([device_deveui_appeui(Device1)]),
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

    % Make are the devices are in the filters
    ?assert(xor16:contain({BinFilter0, ?HASH_FUN}, deveui_appeui(Device0))),
    ?assert(xor16:contain({BinFilter1, ?HASH_FUN}, deveui_appeui(Device1))),
    ?assertMatch(
        %% NOTE: No txns for only removed devices
        %% {RoutingRemoved1, [{update, 1, []}, {update, 0, []}], _CurrentMapping},
        {update_cache, _},
        should_update_filters(chain, OUI, #{
            0 => assign_filter_index(0, get_devices_deveui_app_eui([Device0])),
            1 => assign_filter_index(1, get_devices_deveui_app_eui([Device1]))
        })
    ),

    %% Adding a device to a filter should cause the remove to go through.
    %% Only the filter that is chosen for adds removes it device.
    meck:expect(router_console_api, get_all_devices, fun() -> {ok, [Device2]} end),
    ExpectedUpdateRemoveFitler = [{update, 0, get_devices_deveui_app_eui([Device2])}],
    ?assertMatch(
        {RoutingRemoved1, ExpectedUpdateRemoveFitler, _CurrentMapping},
        should_update_filters(chain, OUI, #{
            0 => assign_filter_index(0, get_devices_deveui_app_eui([Device0])),
            1 => assign_filter_index(1, get_devices_deveui_app_eui([Device1]))
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

    ?assertMatch(
        {update_cache, _},
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

    ExpectedUpdateFilter3 = [{update, 0, get_devices_deveui_app_eui([Device4])}],
    ?assertMatch(
        {RoutingEmptyMap1, ExpectedUpdateFilter3, _CurrentMapping},
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

    {ok, BinEmptyFilter2} = new_xor_filter_bin([]),
    EmptyRouting2 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinEmptyFilter2, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, EmptyRouting}
    end),

    %% Devices with matching app/dev eui should be deduplicated
    ExpectedNewFilter3 = [{new, get_devices_deveui_app_eui([Device5, Device5Copy])}],
    ?assertMatch(
        %% NOTE: Expecting both, because we store by EUI and DeviceID for
        %% fetching later, EUIs are deduped before going into a filter though
        {EmptyRouting2, ExpectedNewFilter3, _CurrentMapping},
        should_update_filters(chain, OUI, #{})
    ),

    %% ------------------------
    % Devices already in Filter should not cause updates
    {ok, BinFilterLast} = new_xor_filter_bin([device_deveui_appeui(Device5)]),
    RoutingLast = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilterLast, [], 1),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) ->
        {ok, RoutingLast}
    end),

    meck:expect(router_console_api, get_all_devices, fun() ->
        {ok, [Device5Copy]}
    end),

    ?assertMatch(
        {update_cache, _},
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

    ExpectedUpdateFilter4 = [{update, 0, get_devices_deveui_app_eui([Device6, Device6Copy])}],
    ?assertMatch(
        %% NOTE: Expecting both, because we store by EUI and DeviceID for
        %% fetching later, EUIs are deduped before going into a filter though
        {RoutingLast, ExpectedUpdateFilter4, _CurrentMapping},
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
    {ok, BinFilter7} = new_xor_filter_bin([device_deveui_appeui(Device7)]),
    Routing7 = blockchain_ledger_routing_v1:new(OUI, <<"owner">>, [], BinFilter7, [], 1),

    meck:expect(blockchain_ledger_v1, find_routing, fun(_OUI, _Ledger) -> {ok, Routing7} end),
    meck:expect(router_console_api, get_all_devices, fun() -> {ok, [Device7, Device7, Device8]} end),
    meck:expect(blockchain, config, fun(_, _) -> {ok, 1} end),

    ExpectedUpdateFilter5 = [
        {update, 0, [
            device_deveui_appeui(Device8),
            assign_filter_index_map(0, device_deveui_appeui(Device7))
        ]}
    ],
    ?assertMatch(
        {Routing7, ExpectedUpdateFilter5, _CurrentMapping},
        should_update_filters(chain, OUI, #{})
    ),

    meck:unload(blockchain_ledger_v1),
    meck:unload(router_console_api),
    meck:unload(blockchain),
    ok.

contained_in_filters_test_() ->
    DeviceEntries = get_devices_deveui_app_eui(n_rand_devices(10)),

    {DeviceEntries1, DeviceEntries2} = lists:split(5, DeviceEntries),
    {ok, BinFilter1} = new_xor_filter_bin(DeviceEntries1),
    {ok, BinFilter2} = new_xor_filter_bin(DeviceEntries2),

    [
        ?_assertEqual(
            {
                #{
                    0 => assign_filter_index(0, DeviceEntries1),
                    1 => assign_filter_index(1, DeviceEntries2)
                },
                lists:sort([]),
                #{}
            },
            contained_in_filters([BinFilter1, BinFilter2], #{}, DeviceEntries)
        ),
        ?_assertEqual(
            {
                #{0 => assign_filter_index(0, DeviceEntries1)},
                DeviceEntries2,
                #{}
            },
            contained_in_filters([BinFilter1], #{}, DeviceEntries)
        ),
        ?_assertEqual(
            {
                #{0 => assign_filter_index(0, DeviceEntries1)},
                [],
                #{1 => assign_filter_index(1, DeviceEntries2)}
            },
            contained_in_filters([BinFilter1, BinFilter2], #{0 => DeviceEntries2}, DeviceEntries1)
        ),
        ?_assertEqual(
            {
                #{},
                DeviceEntries2,
                #{0 => assign_filter_index(0, DeviceEntries1)}
            },
            contained_in_filters([BinFilter1], #{0 => DeviceEntries1}, DeviceEntries2)
        )
    ].

n_rand_devices(N) ->
    lists:map(
        fun(Idx) ->
            Updates = [
                {app_eui, crypto:strong_rand_bytes(8)},
                {dev_eui, crypto:strong_rand_bytes(8)}
            ],
            Name = erlang:list_to_binary(io_lib:format("Device-~p", [Idx])),
            Device = router_device:update(Updates, router_device:new(Name)),
            Device
        end,
        lists:seq(1, N)
    ).

-endif.
