-module(router_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-export([
         basic_test/1
        ]).

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).

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
     basic_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase) ++ "_data",
    ok = application:set_env(router, base_dir, BaseDir),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, staging_console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, staging_console_secret, <<"secret">>),
    {ok, Pid} = elli:start_link([{callback, console_callback}, {port, 3000}]),
    {ok, _} = application:ensure_all_started(router),
    [{elli, Pid}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(elli, Config),
    ok = elli:stop(Pid),
    ok = application:stop(router),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

basic_test(_Config) ->
    {ok, 201, _, Body0} = hackney:get(<<?CONSOLE_URL/binary, "/api/router/sessions">>, [], <<>>, [with_body]),
    ?assertEqual(#{<<"jwt">> => <<"console_callback_token">>}, ?DECODE(Body0)),
    ct:pal("MARKER ~p", [application:get_all_env(router)]),
    ?assert(false),
    ok.
