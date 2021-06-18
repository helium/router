%%%-------------------------------------------------------------------
%% @doc
%% == Router State Channels Worker ==
%%
%% * Responsible for state channel management
%% * Always tries to keep two state channels alive at all times, tracked via active_count
%% * If there is no OUI configured in app config, do nothing on add block events
%% * If there is an OUI configured in app config and a chain is available:
%%
%%      ** If there is no active_count, initialize two state channels
%%      ** If active_count = 1, figure out next nonce and fire off next state_channel
%%      with expiration set to twice the current max nonce state channel
%%      ** If active_count > 1, stand by
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_sc_worker).

-behavior(gen_server).

-include_lib("blockchain/include/blockchain_utils.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

%% ------------------------------------------------------------------
%% API
%% ------------------------------------------------------------------
-export([
    start_link/1,
    is_active/0
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

-export([
    init_state_channels/1,
    open_next_state_channel/1,
    get_active_count/0,
    handle_sc_result/2
]).

-define(SERVER, ?MODULE).
-define(SC_EXPIRATION, 25).
% budget 100 data credits
-define(SC_AMOUNT, 100).
% 15 seconds in millis
-define(SC_TICK_INTERVAL, 15000).
-define(SC_TICK, '__router_sc_tick').

-record(state, {
    pubkey :: libp2p_crypto:public_key(),
    sig_fun :: libp2p_crypto:sig_fun(),
    oui = undefined :: undefined | non_neg_integer(),
    chain = undefined :: undefined | blockchain:blockchain(),
    tref = undefined :: undefined | reference(),
    in_flight = [] :: [blockchain_txn_state_channel_open_v1:id()],
    tombstones = [] :: [blockchain_txn_state_channel_open_v1:id()],
    is_active = false :: boolean(),
    open_sc_limit = undefined :: undefined | non_neg_integer()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec is_active() -> boolean().
is_active() ->
    gen_server:call(?SERVER, is_active).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    %% TODO: Not really sure where exactly to install this handler at tbh...
    ok = router_handler:add_stream_handler(blockchain_swarm:swarm()),
    ok = blockchain_event:add_handler(self()),
    erlang:send_after(500, self(), post_init),
    Tref = schedule_next_tick(),
    {ok, PubKey, SigFun, _} = blockchain_swarm:keys(),
    {ok, #state{pubkey = PubKey, sig_fun = SigFun, tref = Tref}}.

handle_call(is_active, _From, State) ->
    {reply, State#state.is_active, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{chain = undefined} = State) ->
    %% No chain
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            Limit = mac_sc_open(Chain),
            case router_utils:get_oui() of
                undefined ->
                    lager:warning("OUI undefined"),
                    {noreply, State#state{chain = Chain, open_sc_limit = Limit}};
                OUI ->
                    %% We have a chain and an oui on chain
                    %% Only activate if we're on sc_version=2
                    case blockchain:config(?sc_version, blockchain:ledger(Chain)) of
                        {ok, 2} ->
                            {noreply, State#state{
                                chain = Chain,
                                oui = OUI,
                                open_sc_limit = Limit,
                                is_active = true
                            }};
                        _ ->
                            {noreply, State#state{
                                chain = Chain,
                                oui = OUI,
                                open_sc_limit = Limit,
                                is_active = false
                            }}
                    end
            end
    end;
handle_info(post_init, State) ->
    {noreply, State};
handle_info({blockchain_event, {new_chain, NC}}, State) ->
    {noreply, State#state{chain = NC}};
handle_info(
    {blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}},
    #state{chain = undefined} = State
) ->
    %% Got block without a chain, wut?
    erlang:send_after(500, self(), post_init),
    {noreply, State};
handle_info(
    {blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}},
    #state{is_active = false, chain = Chain} = State
) ->
    %% We're inactive, check if we have an oui
    case router_utils:get_oui() of
        undefined ->
            %% stay inactive
            lager:warning("OUI undefined"),
            {noreply, State};
        OUI ->
            Limit = mac_sc_open(Chain),
            %% Only activate if we're on sc_version=2
            case blockchain:config(?sc_version, blockchain:ledger(Chain)) of
                {ok, 2} ->
                    {noreply, State#state{oui = OUI, open_sc_limit = Limit, is_active = true}};
                _ ->
                    {noreply, State#state{oui = OUI, open_sc_limit = Limit, is_active = false}}
            end
    end;
handle_info({sc_open_success, Id}, #state{is_active = false} = State) ->
    lager:error(
        "Got an sc_open_success though the sc_worker is inactive." ++
            " This should never happen. txn id: ~p",
        [Id]
    ),
    {noreply, State};
handle_info({sc_open_failure, Error, Id}, #state{is_active = false} = State) ->
    lager:error(
        "Got an sc_open_failure though the sc_worker is inactive." ++
            " This should never happen. ~p txn id: ~p",
        [Error, Id]
    ),
    {noreply, State};
handle_info({sc_open_success, Id}, #state{is_active = true, tombstones = T} = State) ->
    lager:debug("sc_open_success for txn id ~p", [Id]),
    {noreply, State#state{tombstones = [Id | T]}};
handle_info({sc_open_failure, Error, Id}, #state{is_active = true, tombstones = T} = State) ->
    lager:warning("sc_open_failure ~p for txn id ~p", [Error, Id]),
    %% we're not going to immediately try to start a new channel, we will
    %% wait until the next tick to evaluate that decision.
    {noreply, State#state{tombstones = [Id | T]}};
handle_info(?SC_TICK, #state{is_active = false} = State) ->
    %% don't do anything if the server is inactive
    Tref = schedule_next_tick(),
    {noreply, State#state{tref = Tref}};
handle_info(?SC_TICK, #state{is_active = true} = State) ->
    NewState = maybe_start_state_channel(State),
    Tref = schedule_next_tick(),
    {noreply, NewState#state{tref = Tref}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Helper funs
%% ------------------------------------------------------------------

-spec mac_sc_open(Chain :: blockchain:blockchain()) -> pos_integer().
mac_sc_open(Chain) ->
    case blockchain:config(?max_open_sc, blockchain:ledger(Chain)) of
        {ok, Max} -> Max;
        _ -> 5
    end.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?SC_TICK_INTERVAL, self(), ?SC_TICK).

-spec maybe_start_state_channel(state()) -> state().
maybe_start_state_channel(#state{in_flight = F, tombstones = T, open_sc_limit = Limit} = State) ->
    NewInflight = F -- T,

    Opened = get_opened_count(),
    Active = get_active_count(),

    HaveHeadroom = Active < Opened,
    UnderLimit = Opened < Limit,

    case {HaveHeadroom, UnderLimit} of
        {false, false} ->
            %% All open channels are active, nothing we can do about it until some close
            lager:warning(
                "~p/~p [max: ~p] limit reached, cannot open more state channels",
                [Active, Opened, Limit]
            ),
            State;
        {false, true} ->
            %% All open channels are active, getting a little tight
            lager:info(
                "~p/~p [max: ~p] all active, opening next state channel",
                [Active, Opened, Limit]
            ),
            {ok, ID} = open_next_state_channel(State),
            State#state{in_flight = [ID | NewInflight], tombstones = []};
        {true, _} ->
            %% Active is less than Opened, where we want to be
            lager:info(
                "~p active of ~p [max: ~p],  standing by...",
                [Active, Opened, Limit]
            ),
            State#state{in_flight = [], tombstones = []}
    end.

-spec init_state_channels(State :: state()) ->
    {ok, blockchain_txn_open_state_channel_v1:id(), blockchain_txn_open_state_channel_v1:id()}.
init_state_channels(#state{pubkey = PubKey, sig_fun = SigFun, oui = OUI, chain = Chain}) ->
    PubkeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    Ledger = blockchain:ledger(Chain),
    Nonce = get_nonce(PubkeyBin, Ledger),
    %% XXX FIXME: there needs to be some kind of mechanism to estimate SC_AMOUNT and pass it in
    Id0 = create_and_send_sc_open_txn(
        PubkeyBin,
        SigFun,
        Nonce + 1,
        OUI,
        get_sc_expiration_interval(),
        get_sc_amount(),
        Chain
    ),
    Id1 = create_and_send_sc_open_txn(
        PubkeyBin,
        SigFun,
        Nonce + 2,
        OUI,
        get_sc_expiration_interval() * 2,
        get_sc_amount(),
        Chain
    ),
    {ok, Id0, Id1}.

-spec open_next_state_channel(State :: state()) -> {ok, blockchain_txn_state_channel_open_v1:id()}.
open_next_state_channel(#state{pubkey = PubKey, sig_fun = SigFun, oui = OUI, chain = Chain}) ->
    Ledger = blockchain:ledger(Chain),
    {ok, ChainHeight} = blockchain:height(Chain),
    NextExpiration =
        case active_sc_expiration() of
            {error, no_active_sc} ->
                %% Just set it to expiration_interval
                get_sc_expiration_interval();
            {ok, ActiveSCExpiration} ->
                %% We set the next SC expiration to the difference between
                %% current chain height and active plus the expiration_interval
                abs(ActiveSCExpiration - ChainHeight) + get_sc_expiration_interval()
        end,
    PubkeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    Nonce = get_nonce(PubkeyBin, Ledger),
    %% XXX FIXME: there needs to be some kind of mechanism to estimate SC_AMOUNT and pass it in
    Id = create_and_send_sc_open_txn(
        PubkeyBin,
        SigFun,
        Nonce + 1,
        OUI,
        NextExpiration,
        get_sc_amount(),
        Chain
    ),
    {ok, Id}.

-spec create_and_send_sc_open_txn(
    PubkeyBin :: libp2p_crypto:pubkey_bin(),
    SigFun :: libp2p_crypto:sig_fun(),
    Nonce :: pos_integer(),
    OUI :: non_neg_integer(),
    Expiration :: pos_integer(),
    Amount :: non_neg_integer(),
    Chain :: blockchain:blockchain()
) -> blockchain_txn_state_channel_open_v1:id().
create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce, OUI, Expiration, Amount, Chain) ->
    %% Create and open a new state_channel
    %% With its expiration set to 2 * Expiration of the one with max nonce
    ID = crypto:strong_rand_bytes(32),
    Txn = blockchain_txn_state_channel_open_v1:new(ID, PubkeyBin, Expiration, OUI, Nonce, Amount),
    Fee = blockchain_txn_state_channel_open_v1:calculate_fee(Txn, Chain),
    SignedTxn = blockchain_txn_state_channel_open_v1:sign(
        blockchain_txn_state_channel_open_v1:fee(Txn, Fee),
        SigFun
    ),
    lager:info("Opening state channel for router: ~p, oui: ~p, nonce: ~p, id: ~p", [
        ?TO_B58(PubkeyBin),
        OUI,
        Nonce,
        ID
    ]),
    blockchain_worker:submit_txn(SignedTxn, fun(Result) -> handle_sc_result(Result, ID) end),
    ID.

-spec get_opened_count() -> non_neg_integer().
get_opened_count() ->
    erlang:length(blockchain_state_channels_server:state_channels()).

-spec get_active_count() -> non_neg_integer().
get_active_count() ->
    blockchain_state_channels_server:get_active_sc_count().

-spec get_nonce(
    PubkeyBin :: libp2p_crypto:pubkey_bin(),
    Ledger :: blockchain_ledger_v1:ledger()
) -> non_neg_integer().
get_nonce(PubkeyBin, Ledger) ->
    case blockchain_ledger_v1:find_dc_entry(PubkeyBin, Ledger) of
        {error, _} ->
            0;
        {ok, DCEntry} ->
            blockchain_ledger_data_credits_entry_v1:nonce(DCEntry)
    end.

-spec active_sc_expiration() -> {error, no_active_sc} | {ok, pos_integer()}.
active_sc_expiration() ->
    case blockchain_state_channels_server:active_sc_ids() of
        [] ->
            {error, no_active_sc};
        ActiveSCIDs ->
            SCs = blockchain_state_channels_server:state_channels(),
            [SoonestScToExpire | _] =
                lists:sort(
                    fun(SCIDA, SCIDB) ->
                        {ActiveSCA, _} = maps:get(SCIDA, SCs),
                        {ActiveSCB, _} = maps:get(SCIDB, SCs),
                        blockchain_state_channel_v1:expire_at_block(ActiveSCA) <
                            blockchain_state_channel_v1:expire_at_block(ActiveSCB)
                    end,
                    ActiveSCIDs
                ),
            {ok, blockchain_state_channel_v1:expire_at_block(SoonestScToExpire)}
    end.

-spec get_sc_amount() -> pos_integer().
get_sc_amount() ->
    case application:get_env(router, sc_open_dc_amount, ?SC_AMOUNT) of
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        Amount -> Amount
    end.

-spec get_sc_expiration_interval() -> pos_integer().
get_sc_expiration_interval() ->
    case application:get_env(router, sc_expiration_interval, ?SC_EXPIRATION) of
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        I -> I
    end.

-spec handle_sc_result(
    ok | {error, rejected | invalid},
    blockchain_txn_state_channel_open_v1:id()
) -> {sc_open_success | sc_open_failure, blockchain_txn_state_channel_open_v1:id()}.
handle_sc_result(ok, Id) ->
    ?SERVER ! {sc_open_success, Id};
handle_sc_result(Error, Id) ->
    ?SERVER ! {sc_open_failure, Error, Id}.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
