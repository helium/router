-module(router_console_dc_tracker).

-behavior(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         refill/3,
         has_enough_dc/3,
         current_balance/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS, router_console_dc_tracker_ets).

-record(state, {chain = undefined :: undefined | blockchain:blockchain()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec refill(OrgID :: binary(), Nonce :: non_neg_integer(), Balance :: non_neg_integer()) -> ok.
refill(OrgID, Nonce, Balance) ->
    case lookup(OrgID) of
        {error, not_found} ->
            lager:info("refiling ~p with ~p @ epoch ~p", [OrgID, Balance, Nonce]),
            insert(OrgID, Balance, Nonce);
        {ok, OldBalance, _OldNonce} ->
            lager:info("refiling ~p with ~p (old: ~p) @ epoch ~p (old: ~p)", [OrgID, Balance, OldBalance, Nonce, _OldNonce]),
            insert(OrgID, Balance, Nonce)
    end.

-spec has_enough_dc(binary() | router_device:device(), non_neg_integer(), blockchain:blockchain()) ->
          {true, non_neg_integer(), non_neg_integer()} | false.
has_enough_dc(OrgID, PayloadSize, Chain) when is_binary(OrgID) ->
    case enabled() of
        false ->
            case lookup(OrgID) of
                {error, not_found} ->
                    {B, N} = fetch_and_save_org_balance(OrgID),
                    {true, B, N};
                {ok, B, N} ->
                    {true, B, N}
            end;
        true ->
            Ledger = blockchain:ledger(Chain),
            case blockchain_utils:calculate_dc_amount(Ledger, PayloadSize) of
                {error, _Reason} ->
                    lager:warning("failed to calculate dc amount ~p", [_Reason]),
                    false;
                DCAmount ->
                    {Balance0, Nonce} = 
                        case lookup(OrgID) of
                            {error, not_found} ->
                                fetch_and_save_org_balance(OrgID);
                            {ok, B, N} ->
                                {B, N}
                        end,
                    Balance1 = Balance0-DCAmount,
                    case Balance1 >= 0 andalso Nonce > 0 of
                        false ->
                            false;
                        true ->
                            ok = insert(OrgID, Balance1, Nonce),
                            {true, Balance1, Nonce}
                    end
            end
    end;
%% TODO: (this needs to be reviewed) During upgrade phase (going from no DC to DC) 
%%       devices stored in router will not have an orgID this should force
%%       a device refresh an allow the 1st packet to go threw
has_enough_dc(Device, PayloadSize, Chain) ->
    Metadata0 = router_device:metadata(Device),
    case maps:get(organization_id, Metadata0, undefined) of
        undefined ->
            ok = router_device_worker:device_update(self()),
            true;
        OrgID ->
            has_enough_dc(OrgID, PayloadSize, Chain)
    end.

-spec current_balance(OrgID :: binary()) -> {non_neg_integer(), non_neg_integer()}.
current_balance(OrgID) ->
    case lookup(OrgID) of
        {error, not_found} -> {0, 0};
        {ok, Balance, Nonce} -> {Balance, Nonce}
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ets:new(?ETS, [public, named_table, set]),
    ok = blockchain_event:add_handler(self()),
    _ = erlang:send_after(500, self(), post_init),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{chain=undefined}=State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            {noreply, State#state{chain=Chain}}
    end;
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{chain=undefined}=State) ->
    {noreply, State};
handle_info({blockchain_event, {add_block, BlockHash, _Syncing, Ledger}}, #state{chain=Chain}=State) ->
    case blockchain:get_block(BlockHash, Chain) of
        {error, Reason} ->
            lager:error("couldn't get block with hash: ~p, reason: ~p", [BlockHash, Reason]);
        {ok, Block} ->
            BurnTxns = lists:filter(fun txn_filter_fun/1, blockchain_block:transactions(Block)),
            case BurnTxns of
                [] ->
                    lager:info("no valid txn burn found in block ~p", [BlockHash]);
                Txns ->
                    lists:foreach(
                      fun(Txn) ->
                              Memo = blockchain_txn_token_burn_v1:memo(Txn),
                              HNTAmount = blockchain_txn_token_burn_v1:amount(Txn),
                              {ok, DCAmount} = blockchain_ledger_v1:hnt_to_dc(HNTAmount, Ledger),
                              ok = router_device_api_console:organizations_burned(Memo, HNTAmount, DCAmount)
                      end,
                      Txns)
            end
    end,
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec enabled() -> boolean().
enabled() ->
    case application:get_env(router, dc_tracker) of
        {ok, "enabled"} -> true;
        _ -> false
    end.

-spec txn_filter_fun(blockchain_txn:txn()) -> boolean().
txn_filter_fun(Txn) ->
    case blockchain_txn:type(Txn) == blockchain_txn_token_burn_v1 of
        false ->
            false;
        true ->
            Payee = blockchain_txn_token_burn_v1:payee(Txn),
            Memo = blockchain_txn_token_burn_v1:memo(Txn),
            Payee == blockchain_swarm:pubkey_bin() andalso Memo =/= 0
    end.

-spec fetch_and_save_org_balance(binary()) -> {non_neg_integer(), non_neg_integer()}.
fetch_and_save_org_balance(OrgID) ->
    case router_device_api_console:get_org(OrgID) of
        {error, _} ->
            {0, 0};
        {ok, Map} ->
            Balance = maps:get(<<"dc_balance">>, Map, 0),
            case maps:get(<<"dc_balance_nonce">>, Map, 0) of
                0 ->
                    {0, 0};
                Nonce ->
                    ok = insert(OrgID, Balance, Nonce),
                    {Balance, Nonce}
            end
    end.

-spec lookup(binary()) -> {ok, non_neg_integer(), non_neg_integer()} | {error, not_found}.
lookup(OrgID) ->
    case ets:lookup(?ETS, OrgID) of
        [] -> {error, not_found};
        [{OrgID, {Balance, Nonce}}] -> {ok, Balance, Nonce}
    end.

-spec insert(binary(), non_neg_integer(), non_neg_integer()) -> ok.
insert(OrgID, Balance, Nonce) ->
    true = ets:insert(?ETS, {OrgID, {Balance, Nonce}}),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

refill_test() ->
    _  = ets:new(?ETS, [public, named_table, set]),
    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 100,
    ?assertEqual({error, not_found}, lookup(OrgID)),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({ok, Balance, Nonce}, lookup(OrgID)),
    ets:delete(?ETS),
    ok.

has_enough_dc_test() ->
    ok = application:set_env(router, dc_tracker, "enabled"),
    _  = ets:new(?ETS, [public, named_table, set]),
    meck:new(blockchain, [passthrough]),
    meck:expect(blockchain, ledger, fun(_) -> undefined end),
    meck:new(blockchain_utils, [passthrough]),
    meck:expect(blockchain_utils, calculate_dc_amount, fun(_, _) -> 2 end),
    meck:new(router_device_api_console, [passthrough]),
    meck:expect(router_device_api_console, get_org, fun(_) -> {error, deal_with_it} end),

    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 2,
    ?assertEqual(false, has_enough_dc(OrgID, 48, chain)),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({true, 0, 1}, has_enough_dc(OrgID, 48, chain)),
    ?assertEqual(false, has_enough_dc(OrgID, 48, chain)),

    ets:delete(?ETS),
    ?assert(meck:validate(router_device_api_console)),
    meck:unload(router_device_api_console),
    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain),
    ?assert(meck:validate(blockchain_utils)),
    meck:unload(blockchain_utils),
    ok.

current_balance_test() ->
    _  = ets:new(?ETS, [public, named_table, set]),
    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 100,
    ?assertEqual({0, 0}, current_balance(OrgID)),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({100, 1}, current_balance(OrgID)),
    ets:delete(?ETS),
    ok.


-endif.
