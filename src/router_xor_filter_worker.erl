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
    index = 1 :: non_neg_integer(),
    pending_txns = #{} :: #{blockchain_txn:hash() => blockchain_txn_routing_v1:txn_routing()}
}).

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
    #state{chain = Chain, oui = OUI, index = Index, pending_txns = Pendings} = State
) ->
    case create_current_filter() of
        {error, _Reason} ->
            lager:warning("failed to create_current_filter ~p", [_Reason]),
            ok = schedule_check_filters(),
            {noreply, State};
        {ok, Filter} ->
            case should_update_filters(Chain, OUI, Filter) of
                noop ->
                    lager:info("filters are still update to date"),
                    ok = schedule_check_filters(),
                    {noreply, State};
                {new, Routing} ->
                    lager:info("adding new filter"),
                    Txn = craft_new_filter_txn(Chain, OUI, Filter, Routing),
                    Hash = submit_txn(Txn),
                    lager:info("new filter txn submitted ~p", [Txn]),
                    {noreply, State#state{pending_txns = maps:put(Hash, Txn, Pendings)}};
                {update, Routing} ->
                    lager:info("updating filter @ index ~p", [Index]),
                    Txn = craft_update_filter_txn(Chain, OUI, Filter, Routing, Index),
                    Hash = submit_txn(Txn),
                    lager:info("updating filter txn submitted ~p", [Txn]),
                    {noreply, State#state{pending_txns = maps:put(Hash, Txn, Pendings)}}
            end
    end;
handle_info(
    {?SUBMIT_RESULT, Hash, Return},
    #state{index = Index0, pending_txns = Pendings} = State
) ->
    Txn = maps:get(Hash, Pendings),
    lager:info("got result: ~p from txn submit ~p", [Return, Txn]),
    case Return of
        ok ->
            %% Transaction submitted successfully so we are scheduling next check normally
            %% and incrementing Index if need bed
            ok = schedule_check_filters(),
            Index1 =
                case blockchain_txn_routing_v1:action(Txn) of
                    {update_xor, Index, _Filter} ->
                        Index + 1;
                    _ ->
                        Index0
                end,
            {noreply, State#state{index = Index1, pending_txns = maps:remove(Hash, Pendings)}};
        _ ->
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
-spec submit_txn(Txn :: blockchain_txn_routing_v1:txn_routing()) -> blockchain_txn:hash().
submit_txn(Txn) ->
    Hash = blockchain_txn_routing_v1:hash(Txn),
    Self = self(),
    Callback = fun(Return) -> Self ! {?SUBMIT_RESULT, Hash, Return} end,
    ok = blockchain_worker:submit_txn(Txn, Callback),
    Hash.

-spec craft_update_filter_txn(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference(),
    Routing :: blockchain_ledger_routing_v1:routing(),
    Index :: non_neg_integer()
) -> blockchain_txn_routing_v1:txn_routing().
craft_update_filter_txn(Chain, OUI, Filter, Routing, Index) ->
    {ok, PubKey, SignFun, _} = blockchain_swarm:keys(),
    Txn0 = blockchain_txn_routing_v1:update_xor(
        OUI,
        libp2p_crypto:pubkey_to_bin(PubKey),
        Index,
        xor16:to_bin({Filter, ?HASH_FUN}),
        blockchain_ledger_routing_v1:nonce(Routing) + 1
    ),
    Fees = blockchain_txn_routing_v1:calculate_fee(Txn0, Chain),
    Txn1 = blockchain_txn_routing_v1:fee(Txn0, Fees),
    blockchain_txn_routing_v1:sign(Txn1, SignFun).

-spec craft_new_filter_txn(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference(),
    Routing :: blockchain_ledger_routing_v1:routing()
) -> blockchain_txn_routing_v1:txn_routing().
craft_new_filter_txn(Chain, OUI, Filter, Routing) ->
    {ok, PubKey, SignFun, _} = blockchain_swarm:keys(),
    Txn0 = blockchain_txn_routing_v1:new_xor(
        OUI,
        libp2p_crypto:pubkey_to_bin(PubKey),
        xor16:to_bin({Filter, ?HASH_FUN}),
        blockchain_ledger_routing_v1:nonce(Routing) + 1
    ),
    Fees = blockchain_txn_routing_v1:calculate_fee(Txn0, Chain),
    Txn1 = blockchain_txn_routing_v1:fee(Txn0, Fees),
    blockchain_txn_routing_v1:sign(Txn1, SignFun).

-spec should_update_filters(
    Chain :: blockchain:blockchain(),
    OUI :: non_neg_integer(),
    Filter :: reference()
) ->
    noop
    | {new, blockchain_ledger_routing_v1:routing()}
    | {update, blockchain_ledger_routing_v1:routing()}.
should_update_filters(Chain, OUI, Filter) ->
    Ledger = blockchain:ledger(Chain),
    {ok, MaxXorFilter} = blockchain:config(max_xor_filter_num, Ledger),
    {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),

    BinFilters = blockchain_ledger_routing_v1:filters(Routing),
    {BinFilter, _} = xor16:to_bin({Filter, ?HASH_FUN}),

    case lists:member(BinFilter, BinFilters) of
        true ->
            noop;
        false ->
            case erlang:length(BinFilters) < MaxXorFilter of
                true -> {new, Routing};
                false -> {update, Routing}
            end
    end.

-spec create_current_filter() -> {ok, reference()} | {error, any()}.
create_current_filter() ->
    case router_console_device_api:get_all_devices() of
        {error, _Reason} = Error ->
            Error;
        {ok, Devices} ->
            {Filter, _} = xor16:new(
                [
                    <<(router_device:dev_eui(D)):64/integer-unsigned-little,
                        (router_device:app_eui(D)):64/integer-unsigned-little>>
                    || D <- Devices
                ],
                ?HASH_FUN
            ),
            Filter
    end.

-spec schedule_post_init() -> ok.
schedule_post_init() ->
    {ok, _} = timer:send_after(?POST_INIT_TIMER, self(), ?POST_INIT_TICK),
    ok.

-spec schedule_check_filters() -> ok.
schedule_check_filters() ->
    {ok, _} = timer:send_after(?CHECK_FILTERS_TIMER, self(), ?CHECK_FILTERS_TICK),
    ok.
