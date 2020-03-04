-module(router_aws_SUITE).


-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").


-export([
         all/0,
         init_per_testcase/2,
         end_per_testcase/2
        ]).

-export([
         aws_test/1
        ]).

-define(CONSOLE_URL, <<"http://localhost:3000">>).

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
     aws_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(router, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, console_secret, <<"secret">>),
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    {ok, _} = application:ensure_all_started(router),
    [{base_dir, BaseDir}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, _Config) ->
    ok = application:stop(router),
    ok = application:stop(lager),
    e2qc:teardown(console_cache),
    ok = application:stop(e2qc),
    ok = application:stop(throttle),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

aws_test(_Config) ->
    Args = #{
             aws_access_key => "XX",
             aws_secret_key => "XX",
             aws_region => "us-west-1",
             device_id => <<"PeterTestThing">>
            },
    {ok, P} = router_aws_worker:start_link(Args),

    timer:sleep(600),

    gen_server:stop(P),
    ?assert(false),

    ok.
