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
                    self(),
                    blockchain_swarm:tid()
                ),
                Callback(ok)
        end,
        ok
    end),

    _ = test_utils:add_oui(Config),

    % Force tick to open first SC
    router_sc_worker ! '__router_sc_tick',
    ok = test_utils:wait_until(fun() -> {ok, 3} == router_blockchain:height() end),

    % We should have 1 SC and it should be active
    ?assertEqual(1, maps:size(blockchain_state_channels_server:get_all())),
    ?assertEqual(1, blockchain_state_channels_server:get_actives_count()),

    % Force tick to open another SC
    router_sc_worker ! '__router_sc_tick',
    ok = test_utils:wait_until(fun() -> {ok, 4} == router_blockchain:height() end),

    % Now we should have 1 active and 2 opened SC, it gives us some room just in case
    ?assertEqual(2, maps:size(blockchain_state_channels_server:get_all())),
    ?assertEqual(1, blockchain_state_channels_server:get_actives_count()),

    % Force tick again, the first SC is getting close to expire so lets open more
    router_sc_worker ! '__router_sc_tick',
    ok = test_utils:wait_until(fun() -> {ok, 5} == router_blockchain:height() end),

    ?assertEqual(3, maps:size(blockchain_state_channels_server:get_all())),
    ?assertEqual(1, blockchain_state_channels_server:get_actives_count()),

    % Force tick again, nothing should happen now
    router_sc_worker ! '__router_sc_tick',
    timer:sleep(1000),

    ?assertEqual(3, maps:size(blockchain_state_channels_server:get_all())),
    ?assertEqual(1, blockchain_state_channels_server:get_actives_count()),
    State = sys:get_state(router_sc_worker),
    ?assertEqual(0, erlang:length(State#state.in_flight)),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
