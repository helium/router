-module(router_xor_filter_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    publish_xor_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(HASH_FUN, fun xxhash:hash64/1).
-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

-record(state, {
    chain :: undefined | blockchain:blockchain(),
    oui :: undefined | non_neg_integer(),
    pending_txns = #{} :: #{blockchain_txn:hash() => blockchain_txn_routing_v1:txn_routing()},
    filter_to_devices = #{} :: map(),
    check_filters_ref :: undefined | reference()
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
    [publish_xor_test].

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
publish_xor_test(Config) ->
    ConsensusMembers = proplists:get_value(consensus_member, Config),

    test_utils:wait_until(fun() ->
        blockchain_worker:blockchain() =/= undefined
    end),

    meck:new(blockchain_worker, [passthrough]),
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

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
    _ = blockchain_test_utils:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    %% Wait until xor filter worker started properly
    test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% After start xor filter worker  should have pushed a new filter to the chain
    ok = test_utils:wait_until(fun() -> {ok, 3} == blockchain:height(Chain) end),

    DeviceUpdates = [
        {dev_eui, ?DEVEUI},
        {app_eui, ?APPEUI}
    ],
    Device = router_device:update(DeviceUpdates, router_device:new(<<"ID2">>)),
    DeviceDevEuiAppEui = router_xor_filter_worker:deveui_appeui(Device),

    State0 = sys:get_state(router_xor_filter_worker),
    ?assertEqual(#{}, State0#state.pending_txns),
    ?assertEqual(#{2 => [DeviceDevEuiAppEui]}, State0#state.filter_to_devices),

    Ledger = blockchain:ledger(Chain),
    {ok, Routing} = blockchain_ledger_v1:find_routing(OUI1, Ledger),
    Filters = blockchain_ledger_routing_v1:filters(Routing),
    ?assertEqual(2, erlang:length(Filters)),

    [Filter1, Filter2] = Filters,
    ?assertNot(xor16:contain({Filter1, ?HASH_FUN}, DeviceDevEuiAppEui)),
    ?assert(xor16:contain({Filter2, ?HASH_FUN}, DeviceDevEuiAppEui)),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
