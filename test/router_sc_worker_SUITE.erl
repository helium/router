-module(router_sc_worker_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    mocked_sc_worker_test/1
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
        mocked_sc_worker_test
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

mocked_sc_worker_test(_Config) ->
    % Wait until sc worker ative
    test_utils:wait_until(fun() ->
        State = sys:get_state(router_sc_worker),
        State#state.is_active
    end),

    % Mock submit_txn to clear in_flight txns
    meck:new(blockchain_worker, [passthrough]),
    meck:new(blockchain_state_channels_server, [passthrough]),
    meck:expect(blockchain_worker, submit_txn, fun(Txn) ->
        router_sc_worker ! {sc_open_success, blockchain_txn_state_channel_open_v1:id(Txn)}
    end),

    % Force tick
    router_sc_worker ! '__router_sc_tick',

    % wait until we got a txn submitted
    test_utils:wait_until(fun() ->
        State = sys:get_state(router_sc_worker),
        erlang:length(State#state.in_flight) == 1
    end),

    % mock server to act like a SC was opened correctly
    meck:expect(blockchain_state_channels_server, state_channels, fun() ->
        #{sc1 => sc1}
    end),
    meck:expect(blockchain_state_channels_server, get_active_sc_count, fun() -> 1 end),

    % Force tick another tick
    router_sc_worker ! '__router_sc_tick',

    % By then last inflight txn should have cleared and we should still be at 1
    test_utils:wait_until(fun() ->
        State = sys:get_state(router_sc_worker),
        erlang:length(State#state.in_flight) == 1
    end),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(blockchain_state_channels_server)),
    meck:unload(blockchain_state_channels_server),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
