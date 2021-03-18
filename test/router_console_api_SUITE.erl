-module(router_console_api_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([ws_get_address_test/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("utils/console_test.hrl").
-include("lorawan_vars.hrl").

-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

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
    [ws_get_address_test].

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

ws_get_address_test(_Config) ->
    _WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    receive
        {websocket_msg, Map} ->
            PubKeyBin = blockchain_swarm:pubkey_bin(),
            B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
            ?assertEqual(
                #{
                    ref => <<"0">>,
                    topic => <<"organization:all">>,
                    event => <<"router:address">>,
                    jref => <<"0">>,
                    payload => #{<<"address">> => B58}
                },
                Map
            )
    after 2500 -> ct:fail(websocket_msg_timeout)
    end,
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
