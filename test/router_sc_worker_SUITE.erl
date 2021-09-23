-module(router_sc_worker_SUITE).

-include("metrics.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    sc_worker_test/1
]).

-record(state, {
    pubkey :: libp2p_crypto:public_key(),
    sig_fun :: libp2p_crypto:sig_fun(),
    chain = undefined :: undefined | blockchain:blockchain(),
    oui = undefined :: undefined | non_neg_integer(),
    is_active = false :: boolean(),
    tref = undefined :: undefined | reference(),
    in_flight = [] :: [blockchain_txn_state_channel_open_v1:id()],
    open_sc_limit = undefined :: undefined | non_neg_integer()
}).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        sc_worker_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

sc_worker_test(Config) ->
    {ok, _} = lager:trace_console(
        [{module, blockchain_state_channels_server}],
        debug
    ),
    ConsensusMembers = proplists:get_value(consensus_member, Config),

    % Wait until sc worker ative
    test_utils:wait_until(fun() ->
        State = sys:get_state(router_sc_worker),
        State#state.is_active
    end),

    % Mock submit_txn to create/gossip block
    meck:new(blockchain_worker, [passthrough, no_history]),
    meck:expect(blockchain_worker, submit_txn, fun(Txn, Callback) ->
        case blockchain_test_utils:create_block(ConsensusMembers, [Txn]) of
            {error, _Reason} = Error ->
                Callback(Error);
            {ok, Block} ->
                _ = blockchain_test_utils:add_block(
                    Block,
                    blockchain_worker:blockchain(),
                    self(),
                    blockchain_swarm:swarm()
                ),
                Callback(ok)
        end,
        ok
    end),

    Chain = blockchain_worker:blockchain(),
    {ok, PubKey, SignFun, _} = blockchain_swarm:keys(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% Create and submit OUI txn with an empty filter
    OUI1 = 1,
    {BinFilter, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn = blockchain_txn_oui_v1:new(OUI1, PubKeyBin, [PubKeyBin], BinFilter, 8),
    OUITxnFee = blockchain_txn_oui_v1:calculate_fee(OUITxn, Chain),
    OUITxnStakingFee = blockchain_txn_oui_v1:calculate_staking_fee(OUITxn, Chain),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, OUITxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, OUITxnStakingFee),
    SignedOUITxn = blockchain_txn_oui_v1:sign(OUITxn1, SignFun),

    {ok, OUIBlock} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
    _ = blockchain_test_utils:add_block(OUIBlock, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    % Force tick to open first SC
    router_sc_worker ! '__router_sc_tick',
    ok = test_utils:wait_until(fun() -> {ok, 3} == blockchain:height(Chain) end),

    % We should have 1 SC and it should be active
    ?assertEqual(1, maps:size(blockchain_state_channels_server:state_channels())),
    ?assertEqual(1, blockchain_state_channels_server:get_active_sc_count()),

    % Force tick to open another SC
    router_sc_worker ! '__router_sc_tick',
    ok = test_utils:wait_until(fun() -> {ok, 4} == blockchain:height(Chain) end),

    % Now we should have 1 active and 2 opened SC, it gives us some room just in case
    ?assertEqual(2, maps:size(blockchain_state_channels_server:state_channels())),
    ?assertEqual(1, blockchain_state_channels_server:get_active_sc_count()),

    % Force tick again, in this case nothing should happen as we have a good number of SCs opened
    router_sc_worker ! '__router_sc_tick',
    timer:sleep(5000),

    ?assertEqual(2, maps:size(blockchain_state_channels_server:state_channels())),
    ?assertEqual(1, blockchain_state_channels_server:get_active_sc_count()),

    State = sys:get_state(router_sc_worker),
    ?assertEqual(0, erlang:length(State#state.in_flight)),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
