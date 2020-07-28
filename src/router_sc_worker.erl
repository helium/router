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
%%      ** If active_count = 2, stand by
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_sc_worker).

-behavior(gen_server).

-include_lib("blockchain/include/blockchain_utils.hrl").

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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
%% TODO: Configure via app env
-define(EXPIRATION, 45).
-define(SC_AMOUNT, 100). % budget 100 data credits

-record(state, {
                oui = undefined :: undefined | non_neg_integer(),
                chain = undefined :: undefined | blockchain:blockchain(),
                is_active = false :: boolean()
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
    {ok, #state{}}.

handle_call(is_active, _From, State) ->
    {reply, State#state.is_active, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{chain=undefined}=State) ->
    %% No chain
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            case router_utils:get_router_oui(Chain) of
                undefined ->
                    {noreply, State#state{chain=Chain}};
                OUI ->
                    %% We have a chain and an oui on chain
                    %% Only activate if we're on sc_version=2
                    case blockchain:config(sc_version, blockchain:ledger(Chain)) of
                        {ok, 2} ->
                            {noreply, State#state{chain=Chain, oui=OUI, is_active=true}};
                        _ ->
                            {noreply, State#state{chain=Chain, oui=OUI}}
                    end
            end
    end;
handle_info({blockchain_event, {new_chain, NC}}, State) ->
    {noreply, State#state{chain=NC}};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{chain=undefined}=State) ->
    %% Got block without a chain, wut?
    erlang:send_after(500, self(), post_init),
    {noreply, State};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{is_active=false, chain=Chain}=State) ->
    %% We're inactive, check if we have an oui
    case router_utils:get_router_oui(Chain) of
        undefined ->
            %% stay inactive
            {noreply, State};
        OUI ->
            %% Only activate if we're on sc_version=2
            case blockchain:config(sc_version, blockchain:ledger(Chain)) of
                {ok, 2} ->
                    {noreply, State#state{oui=OUI, is_active=true}};
                _ ->
                    {noreply, State#state{oui=OUI}}
            end
    end;

handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}},
            #state{is_active=true, chain=Chain}=State) ->
    case get_active_count(Chain) of
        0 ->
            %% initialize with two channels
            lager:info("active_count = 0, opening two state channels"),
            ok = init_state_channels(State);
        1 ->
            %% open next state channel
            lager:info("active_count = 1, opening next state channel"),
            ok = open_next_state_channel(State);
        2 ->
            %% don't do anything
            lager:info("active_count = 2, standing by..."),
            ok
    end,
    {noreply, State};
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

-spec init_state_channels(State :: state()) -> ok.
init_state_channels(#state{oui=OUI, chain=Chain}) ->
    PubkeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    Ledger = blockchain:ledger(Chain),
    Nonce = get_nonce(PubkeyBin, Ledger),
    %% XXX FIXME: there needs to be some kind of mechanism to estimate SC_AMOUNT and pass it in
    ok = create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce + 1, OUI, ?EXPIRATION, ?SC_AMOUNT, Chain),
    ok = create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce + 2, OUI, ?EXPIRATION * 3, ?SC_AMOUNT, Chain).

-spec open_next_state_channel(State :: state()) -> ok.
open_next_state_channel(#state{oui=OUI, chain=Chain}=State) ->
    Ledger = blockchain:ledger(Chain),
    {ok, ChainHeight} = blockchain:height(Chain),
    NextExpiration = case active_sc_expiration() of
                         {error, no_active_sc} ->
                             abs(previous_sc_expiration(State) - ChainHeight) + ?EXPIRATION * 3;
                         {ok, ActiveSCExpiration} ->
                             %% We set the next SC expiration to the difference between current chain height and active
                             %% expiration + default expiration * 2
                             abs(ActiveSCExpiration - ChainHeight) + ?EXPIRATION * 3
                     end,

    PubkeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    Nonce = get_nonce(PubkeyBin, Ledger),
    %% XXX FIXME: there needs to be some kind of mechanism to estimate SC_AMOUNT and pass it in
    create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce + 1, OUI, NextExpiration, ?SC_AMOUNT, Chain).

-spec create_and_send_sc_open_txn(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                                  SigFun :: libp2p_crypto:sig_fun(),
                                  Nonce :: pos_integer(),
                                  OUI :: non_neg_integer(),
                                  Expiration :: pos_integer(),
                                  Amount :: non_neg_integer(),
                                  Chain :: blockchain:blockchain()) -> ok.
create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce, OUI, Expiration, Amount, Chain) ->
    %% Create and open a new state_channel
    %% With its expiration set to 2 * Expiration of the one with max nonce
    ID = crypto:strong_rand_bytes(32),
    Txn = blockchain_txn_state_channel_open_v1:new(ID, PubkeyBin, Expiration, OUI, Nonce, Amount),
    Fee = blockchain_txn_state_channel_open_v1:calculate_fee(Txn, Chain),
    SignedTxn = blockchain_txn_state_channel_open_v1:sign(
                  blockchain_txn_state_channel_open_v1:fee(Txn, Fee),  SigFun),
    lager:info("Opening state channel for router: ~p, oui: ~p, nonce: ~p", [?TO_B58(PubkeyBin), OUI, Nonce]),
    blockchain_worker:submit_txn(SignedTxn).

-spec get_active_count(Chain :: blockchain:blockchain()) -> non_neg_integer().
get_active_count(Chain) ->
    Ledger = blockchain:ledger(Chain),
    Owner = blockchain_swarm:pubkey_bin(),
    {ok, LedgerSCMap} = blockchain_ledger_v1:find_scs_by_owner(Owner, Ledger),
    X = maps:size(LedgerSCMap),
    lager:info("LedgerSCCount: ~p, LedgerSCMap: ~p", [X, LedgerSCMap]),
    X.

-spec get_nonce(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                Ledger :: blockchain_ledger_v1:ledger()) -> non_neg_integer().
get_nonce(PubkeyBin, Ledger) ->
    case blockchain_ledger_v1:find_dc_entry(PubkeyBin, Ledger) of
        {error, _} ->
            0;
        {ok, DCEntry} ->
            blockchain_ledger_data_credits_entry_v1:nonce(DCEntry)
    end.

-spec previous_sc_expiration(State :: state()) -> pos_integer().
previous_sc_expiration(#state{chain=Chain}) ->
    Ledger = blockchain:ledger(Chain),
    Owner = blockchain_swarm:pubkey_bin(),
    {ok, LedgerSCMap} = blockchain_ledger_v1:find_scs_by_owner(Owner, Ledger),
    LedgerSCMod = get_ledger_sc_mod(Ledger),
    SortFun = fun(SC1, SC2) -> LedgerSCMod:nonce(SC1) >= LedgerSCMod:nonce(SC2) end,
    LastLedgerSC = hd(lists:sort(SortFun, maps:values(LedgerSCMap))),
    blockchain_ledger_state_channel_v2:expire_at_block(LastLedgerSC).

-spec active_sc_expiration() -> {error, no_active_sc} | {ok, pos_integer()}.
active_sc_expiration() ->
    case blockchain_state_channels_server:active_sc_id() of
        undefined ->
            {error, no_active_sc};
        ActiveSCID ->
            SCs = blockchain_state_channels_server:state_channels(),
            {ActiveSC, _} = maps:get(ActiveSCID, SCs),
            {ok, blockchain_state_channel_v1:expire_at_block(ActiveSC)}
    end.

-spec get_ledger_sc_mod(Ledger :: blockchain_ledger_v1:ledger()) -> blockchain_ledger_state_channel_v2 |
          blockchain_ledger_state_channel_v1.
get_ledger_sc_mod(Ledger) ->
    case blockchain:config(sc_version, Ledger) of
        {ok, 2} ->
            blockchain_ledger_state_channel_v2;
        _ ->
            blockchain_ledger_state_channel_v1
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

%% TODO: add some eunits here...

-endif.
