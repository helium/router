-module(router_console_dc_tracker).

-behavior(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init_ets/0,
    refill/3,
    has_enough_dc/2,
    charge/2,
    current_balance/1,
    %%
    add_unfunded/1,
    remove_unfunded/1,
    list_unfunded/0,
    reset_unfunded_from_api/0
]).

%% ------------------------------------------------------------------
%% Router CLI Exports
%% ------------------------------------------------------------------
-export([
    lookup/1,
    lookup_balance_less_than/1,
    lookup_all/0,
    fetch_and_save_org_balance/1,
    lookup_nonce/1,
    lookup_balance/1
]).

%% ets:fun2ms(fun ({_, {Balance, _}}=R) when Balance < Amount -> R end).
-define(LESS_THAN_FUN(Amount), [{{'_', {'$1', '_'}}, [{'<', '$1', Amount}], ['$_']}]).
%% ets:fun2ms(fun ({_, {Balance, _}}=R) when Balance == Amount -> R end).
-define(BALANCE_EQUALS_FUN(Balance), [{{'_', {'$1', '_'}}, [{'==', '$1', Balance}], ['$_']}]).
%% ets:fun2ms(fun ({_, {_, Nonce}}=R) when Nonce == Amount -> R end).
-define(NONCE_EQUALS_FUN(Nonce), [{{'_', {'_', '$1'}}, [{'==', '$1', Nonce}], ['$_']}]).

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
-define(ETS, router_console_dc_tracker_ets).
-define(UNFUNDED_ETS, router_console_dc_tracker_unfunded_ets).

-record(state, {
    pubkey_bin :: libp2p_crypto:pubkey_bin()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    ?UNFUNDED_ETS = ets:new(?UNFUNDED_ETS, [public, named_table, set]),
    ok.

-spec add_unfunded(OrgID :: binary()) -> ok.
add_unfunded(OrgID) ->
    true = ets:insert(?UNFUNDED_ETS, {OrgID, 0}),
    ok.

-spec remove_unfunded(OrgID :: binary()) -> ok.
remove_unfunded(OrgID) ->
    true = ets:delete(?UNFUNDED_ETS, OrgID),
    ok.

-spec list_unfunded() -> [binary()].
list_unfunded() ->
    [OrgID || {OrgID, _} <- ets:tab2list(?UNFUNDED_ETS)].

-spec reset_unfunded_from_api() -> ok.
reset_unfunded_from_api() ->
    true = ets:delete_all_objects(?UNFUNDED_ETS),
    {ok, OrgIDs} = router_console_api:get_unfunded_org_ids(),
    true = ets:insert(?UNFUNDED_ETS, [{ID, 0} || ID <- OrgIDs]),
    ok.

-spec refill(OrgID :: binary(), Nonce :: non_neg_integer(), Balance :: non_neg_integer()) -> ok.
refill(OrgID, Nonce, Balance) ->
    ok = ?MODULE:remove_unfunded(OrgID),
    case lookup(OrgID) of
        {error, not_found} ->
            lager:info("refilling ~p with ~p @ epoch ~p", [OrgID, Balance, Nonce]),
            insert(OrgID, Balance, Nonce);
        {ok, OldBalance, _OldNonce} ->
            lager:info("refiling ~p with ~p (old: ~p) @ epoch ~p (old: ~p)", [
                OrgID,
                Balance,
                OldBalance,
                Nonce,
                _OldNonce
            ]),
            insert(OrgID, Balance, Nonce)
    end.

-spec has_enough_dc(
    binary() | router_device:device(),
    non_neg_integer()
) -> {ok, binary(), non_neg_integer() | undefined, non_neg_integer()} | {error, any()}.
has_enough_dc(OrgID, PayloadSize) when is_binary(OrgID) ->
    case router_blockchain:calculate_dc_amount(PayloadSize) of
        {error, _Reason} ->
            lager:warning("failed to calculate dc amount ~p", [_Reason]),
            {error, failed_calculate_dc};
        DCAmount ->
            {Balance0, Nonce} =
                case lookup(OrgID) of
                    {error, not_found} ->
                        fetch_and_save_org_balance(OrgID);
                    {ok, 0, _N} ->
                        fetch_and_save_org_balance(OrgID);
                    {ok, B, N} ->
                        {B, N}
                end,
            Balance1 = Balance0 - DCAmount,
            case {Balance1 >= 0, Nonce > 0} of
                {false, _} ->
                    {error, {not_enough_dc, Balance0, DCAmount}};
                {_, false} ->
                    {error, bad_nonce};
                {true, true} ->
                    {ok, OrgID, Balance1, Nonce}
            end
    end;
has_enough_dc(Device, PayloadSize) ->
    Metadata0 = router_device:metadata(Device),
    case maps:get(organization_id, Metadata0, undefined) of
        undefined ->
            ok = router_device_worker:device_update(self()),
            {ok, undefined, 0, 0};
        OrgID ->
            has_enough_dc(OrgID, PayloadSize)
    end.

-spec charge(binary() | router_device:device(), non_neg_integer()) ->
    {ok, non_neg_integer(), non_neg_integer()} | {error, any()}.
charge(Device, PayloadSize) ->
    case ?MODULE:has_enough_dc(Device, PayloadSize) of
        {error, _Reason} = Error ->
            Error;
        {ok, _OrgID, _Balance, 0} ->
            {ok, _Balance, 0};
        {ok, OrgID, Balance, Nonce} ->
            ok = insert(OrgID, Balance, Nonce),
            {ok, Balance, Nonce}
    end.

-spec current_balance(OrgID :: binary()) -> {non_neg_integer(), non_neg_integer()}.
current_balance(OrgID) ->
    case lookup(OrgID) of
        {error, not_found} ->
            fetch_and_save_org_balance(OrgID);
        {ok, Balance, Nonce} ->
            {Balance, Nonce}
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {PubKey, _, _} = router_blockchain:get_key(),
    PubkeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    _ = erlang:send_after(500, self(), post_init),
    {ok, #state{pubkey_bin = PubkeyBin}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{} = State) ->
    case router_blockchain:privileged_maybe_get_blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        _Chain ->
            ok = blockchain_event:add_handler(self()),
            {noreply, State#state{}}
    end;
handle_info(
    {blockchain_event, {add_block, BlockHash, _Syncing, Ledger}},
    #state{pubkey_bin = PubkeyBin} = State
) ->
    case router_blockchain:get_blockhash(BlockHash) of
        {error, Reason} ->
            lager:error("couldn't get block with hash: ~p, reason: ~p", [BlockHash, Reason]);
        {ok, Block} ->
            BurnTxns = lists:filter(
                fun(Txn) -> txn_filter_fun(PubkeyBin, Txn) end,
                blockchain_block:transactions(Block)
            ),
            case BurnTxns of
                [] ->
                    lager:info("no burn txn found in block ~p", [BlockHash]);
                Txns ->
                    lists:foreach(
                        fun(Txn) ->
                            Memo = blockchain_txn_token_burn_v1:memo(Txn),
                            HNTAmount = blockchain_txn_token_burn_v1:amount(Txn),
                            {ok, DCAmount} = blockchain_ledger_v1:hnt_to_dc(HNTAmount, Ledger),
                            lager:info("we got a burn for: ~p ~p HNT ~p DC", [
                                Memo,
                                HNTAmount,
                                DCAmount
                            ]),
                            ok = router_console_api:organizations_burned(
                                Memo,
                                HNTAmount,
                                DCAmount
                            )
                        end,
                        Txns
                    )
            end
    end,
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    true = ets:delete(?ETS),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec txn_filter_fun(PubKeyBin :: libp2p_crypto:public_key(), Txn :: blockchain_txn:txn()) ->
    boolean().
txn_filter_fun(PubKeyBin, Txn) ->
    case blockchain_txn:type(Txn) == blockchain_txn_token_burn_v1 of
        false ->
            false;
        true ->
            Payee = blockchain_txn_token_burn_v1:payee(Txn),
            Memo = blockchain_txn_token_burn_v1:memo(Txn),
            Payee == PubKeyBin andalso Memo =/= 0
    end.

-spec fetch_and_save_org_balance(binary()) -> {non_neg_integer(), non_neg_integer()}.
fetch_and_save_org_balance(OrgID) ->
    case router_console_api:get_org(OrgID) of
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

-spec lookup_balance_less_than(non_neg_integer()) ->
    [{Org :: binary(), {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}}].
lookup_balance_less_than(Amount) ->
    ets:select(?ETS, ?LESS_THAN_FUN(Amount)).

-spec lookup_nonce(non_neg_integer()) ->
    [{Org :: binary(), {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}}].
lookup_nonce(Amount) ->
    ets:select(?ETS, ?NONCE_EQUALS_FUN(Amount)).

-spec lookup_balance(non_neg_integer()) ->
    [{Org :: binary(), {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}}].
lookup_balance(Amount) ->
    ets:select(?ETS, ?BALANCE_EQUALS_FUN(Amount)).

-spec lookup_all() ->
    [{Org :: binary(), {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}}].
lookup_all() ->
    ets:tab2list(?ETS).

-spec insert(binary(), non_neg_integer(), non_neg_integer()) -> ok.
insert(OrgID, Balance, Nonce) ->
    true = ets:insert(?ETS, {OrgID, {Balance, Nonce}}),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

refill_test() ->
    _ = ets:new(?ETS, [public, named_table, set]),
    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 100,
    ?assertEqual({error, not_found}, lookup(OrgID)),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({ok, Balance, Nonce}, lookup(OrgID)),
    ets:delete(?ETS),
    ok.

setup_meck() ->
    meck:new(router_blockchain, [passthrough]),
    meck:expect(router_blockchain, calculate_dc_amount, fun(_) -> 2 end),

    meck:new(router_console_api, [passthrough]),
    meck:expect(router_console_api, get_org, fun(_) -> {error, deal_with_it} end),

    ok.

teardown_meck() ->
    ?assert(meck:validate(router_console_api)),
    meck:unload(router_console_api),

    ?assert(meck:validate(router_blockchain)),
    meck:unload(router_blockchain),

    ok.

has_enough_dc_test() ->
    _ = ets:new(?ETS, [public, named_table, set]),
    ok = setup_meck(),

    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 2,
    PayloadSize = 48,
    ?assertEqual(
        {error, {not_enough_dc, 0, Balance}}, has_enough_dc(OrgID, PayloadSize)
    ),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({ok, OrgID, 0, 1}, has_enough_dc(OrgID, PayloadSize)),

    ets:delete(?ETS),
    ok = teardown_meck().

charge_test() ->
    _ = ets:new(?ETS, [public, named_table, set]),
    ok = setup_meck(),

    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 2,
    PayloadSize = 48,
    ?assertEqual(
        {error, {not_enough_dc, 0, Balance}}, has_enough_dc(OrgID, PayloadSize)
    ),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({ok, 0, 1}, charge(OrgID, PayloadSize)),
    ?assertEqual({error, {not_enough_dc, 0, Balance}}, charge(OrgID, PayloadSize)),

    ets:delete(?ETS),
    ok = teardown_meck().

current_balance_test() ->
    _ = ets:new(?ETS, [public, named_table, set]),
    meck:new(router_console_api, [passthrough]),
    meck:expect(router_console_api, get_org, fun(_OrgID) -> {error, 0} end),
    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 100,
    ?assertEqual({0, 0}, current_balance(OrgID)),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({100, 1}, current_balance(OrgID)),
    ?assert(meck:validate(router_console_api)),
    meck:unload(router_console_api),
    ets:delete(?ETS),
    ok.

lookup_balance_less_than_test() ->
    _ = ets:new(?ETS, [public, named_table, set]),
    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 100,
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual(ok, refill(<<"ANOTHER_ORG">>, 1, 999)),
    ?assertEqual([{OrgID, {Balance, Nonce}}], lookup_balance_less_than(500)),
    ets:delete(?ETS),
    ok.

lookup_nonce_test() ->
    _ = ets:new(?ETS, [public, named_table, set]),

    ?assertEqual(ok, refill(<<"ONE">>, 1, 1)),
    ?assertEqual(ok, refill(<<"TWO">>, 2, 2)),
    ?assertEqual(ok, refill(<<"THREE">>, 1, 2)),

    ?assertEqual([{<<"ONE">>, {1, 1}}, {<<"THREE">>, {2, 1}}], lookup_nonce(1)),
    ?assertEqual([{<<"TWO">>, {2, 2}}], lookup_nonce(2)),

    ets:delete(?ETS),
    ok.

lookup_balance_test() ->
    _ = ets:new(?ETS, [public, named_table, set]),

    ?assertEqual(ok, refill(<<"ONE">>, 1, 1)),
    ?assertEqual(ok, refill(<<"TWO">>, 2, 2)),
    ?assertEqual(ok, refill(<<"THREE">>, 1, 2)),

    ?assertEqual([{<<"ONE">>, {1, 1}}], lookup_balance(1)),
    ?assertEqual([{<<"TWO">>, {2, 2}}, {<<"THREE">>, {2, 1}}], lookup_balance(2)),

    ets:delete(?ETS),
    ok.

-endif.
