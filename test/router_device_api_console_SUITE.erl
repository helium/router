-module(router_device_api_console_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([ws_test/1]).

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
    {ok, ConnPid} = gun:open("127.0.0.1", 3000),
    {ok, _Protocol} = gun:await_up(ConnPid),
    gun:ws_upgrade(ConnPid, "/websocket"),

    receive
        {gun_upgrade, ConnPid, _, [<<"websocket">>], _Headers} ->
            ok;
        {gun_response, ConnPid, _, _, Status, Headers} ->
            ct:fail({ws_upgrade_failed, Status, Headers});
        {gun_error, ConnPid, _, Reason} ->
            ct:fail({ws_upgrade_failed, Reason})
    after 1000 ->
            ct:fail(timeout)
    end,

    receive
        {websocket_init, Pid} ->
            Pid ! {debug, <<"debug">>}
    after 1000 ->
            ct:fail(timeout2)
    end,

    receive
        {gun_ws, ConnPid, _, {text, <<"debug">>}} ->
            ok
    after 1000 ->
            ct:fail(timeout3)
    end,
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

