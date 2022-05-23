-module(router_chain_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    chain_vars/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

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
        chain_vars
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
chain_vars(_Config) ->
    ok = test_utils:wait_until(fun() ->
        undefined =/= router_chain_vars_statem:sc_version()
    end),
    ok = test_utils:wait_until(fun() ->
        undefined =/= router_chain_vars_statem:max_open_sc()
    end),
    ok = test_utils:wait_until(fun() ->
        undefined =/= router_chain_vars_statem:max_xor_filter_num()
    end),
    ok.
