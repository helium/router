-module(router_device_api_console_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([ws_test/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("utils/console_test.hrl").

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
    [ws_test].

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

ws_test(_Config) ->
    Url = "ws://" ++ binary_to_list(?CONSOLE_IP_PORT) ++ "/websocket",
    router_console_ws_handler:start_link(#{url => Url,
                                           auto_join => [<<"device:all">>],
                                           forward => self()}),
    receive
        {ws_message, <<"device:all">>,<<"device:all:debug:devices">>,#{<<"devices">> := [?CONSOLE_DEVICE_ID]}} ->
            ok;
        {ws_message, _Other} ->
            ct:fail(_Other)
    after 10000 ->
        ct:fail(timeout)
    end,
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

