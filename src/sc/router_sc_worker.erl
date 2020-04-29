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
         state/0
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

-record(state, {
                oui = undefined :: undefined | pos_integer(),
                chain = undefined :: undefined | blockchain:blockchain(),
                active_count = 0 :: 0 | 1 | 2
               }).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec state() -> state().
state() ->
    gen_server:call(?SERVER, state, infinity).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ok = blockchain_event:add_handler(self()),
    OUI = application:get_env(router, oui, undefined),
    erlang:send_after(500, self(), post_init),
    {ok, #state{oui=OUI}}.

handle_call(state, _From, State) ->
    {reply, State, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_, #state{oui=undefined}=State) ->
    %% Ignore all messages if OUI is undefined
    %% However, keep running post_init just in case it gets configured later
    erlang:send_after(500, self(), post_init),
    {noreply, State};
handle_info(post_init, #state{chain=undefined}=State) ->
    %% No chain
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            OUI = application:get_env(router, oui, undefined),
            {noreply, #state{chain=Chain, oui=OUI}}
    end;
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{chain=undefined}=State) ->
    %% Got block without a chain, wut?
    erlang:send_after(500, self(), post_init),
    {noreply, State};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{active_count=0}=State) ->
    lager:info("active_count = 0, initializing two state_channels"),
    ok = init_state_channels(State),
    {noreply, State#state{active_count=get_active_count()}};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, Ledger}}, #state{active_count=1}=State) ->
    lager:info("active_count = 1, opening next state_channel"),
    ok = open_next_state_channel(State, Ledger),
    {noreply, State#state{active_count=get_active_count()}};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{active_count=2}=State) ->
    %% Don't do anything
    lager:info("active_count = 2, standing by"),
    {noreply, State#state{active_count=get_active_count()}};
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
init_state_channels(#state{oui=OUI}) ->
    %% We have no state channels at all on the ledger
    PubkeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),

    ok = create_and_send_sc_open_txn(PubkeyBin, SigFun, 1, OUI, ?EXPIRATION),
    ok = create_and_send_sc_open_txn(PubkeyBin, SigFun, 2, OUI, ?EXPIRATION * 2),
    ok.

-spec open_next_state_channel(State :: state(), Ledger :: blockchain_ledger_v1:ledger()) -> ok.
open_next_state_channel(#state{oui=OUI}, Ledger) ->
    %% Get my pubkey_bin and sigfun
    PubkeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    MaxNonceSC = find_max_nonce_sc(PubkeyBin, Ledger),
    Nonce = blockchain_ledger_state_channel_v1:nonce(MaxNonceSC),
    ExpireAtBlock = blockchain_ledger_state_channel_v1:expire_at_block(MaxNonceSC),
    create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce + 1, OUI, ExpireAtBlock * 2).

-spec create_and_send_sc_open_txn(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                                  SigFun :: libp2p_crypto:sig_fun(),
                                  Nonce :: pos_integer(),
                                  OUI :: pos_integer(),
                                  Expiration :: pos_integer()) -> ok.
create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce, OUI, Expiration) ->
    %% Create and open a new state_channel
    %% With its expiration set to 2 * Expiration of the one with max nonce
    ID = crypto:strong_rand_bytes(32),
    Txn = blockchain_txn_state_channel_open_v1:new(ID, PubkeyBin, Expiration, OUI, Nonce),
    SignedTxn = blockchain_txn_state_channel_open_v1:sign(Txn, SigFun),
    lager:info("Opening state channel for router: ~p, oui: ~p, nonce: ~p", [?TO_B58(PubkeyBin), OUI, Nonce]),
    blockchain_worker:submit_txn(SignedTxn).

-spec get_active_count() -> non_neg_integer().
get_active_count() ->
    map_size(blockchain_state_channels_server:state_channels()).

-spec find_max_nonce_sc(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                        Ledger :: blockchain_ledger_v1:ledger()) -> blockchain_ledger_state_channel_v1:state_channel().
find_max_nonce_sc(PubkeyBin, Ledger) ->
    %% Sort currently active state_channels by nonce to fire the next one
    SCSortFun = fun({_ID1, SC1}, {_ID2, SC2}) ->
                        blockchain_ledger_state_channel_v1:nonce(SC1) >= blockchain_ledger_state_channel_v1:nonce(SC2)
                end,

    %% Find the sc with the max nonce currently
    {ok, LedgerSCs} = blockchain_ledger_v1:find_scs_by_owner(PubkeyBin, Ledger),
    {_, SC} = hd(lists:sort(SCSortFun, maps:to_list(LedgerSCs))),
    SC.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

%% TODO: add some eunits here...

-endif.
