-module(router_channel_aws_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([aws_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).
-define(ETS, ?MODULE).

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
    [].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(router, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, router_device_api_module, router_device_api_console),
    ok = application:set_env(router, console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, console_secret, <<"secret">>),
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    Tab = ets:new(?ETS, [public, set]),
    AppKey = crypto:strong_rand_bytes(16),
    ElliOpts = [
                {callback, console_callback},
                {callback_args, #{forward => self(), ets => Tab,
                                  app_key => AppKey, app_eui => ?APPEUI, dev_eui => ?DEVEUI}},
                {port, 3000}
               ],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),
    [{app_key, AppKey}, {ets, Tab}, {elli, Pid}, {base_dir, BaseDir}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(500),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    e2qc:teardown(console_cache),
    ok = application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
aws_test(_Config) ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    UUID = list_to_binary(io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                                        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E])),
    DeviceID = <<"TEST_", UUID/binary>>,
    AWSArgs = #{aws_access_key => os:getenv("aws_access_key"),
                aws_secret_key => os:getenv("aws_secret_key"),
                aws_region => "us-west-1",
                topic => <<"helium">>},
    Channel = router_channel:new(<<"channel_id">>, router_aws_channel, <<"aws">>, AWSArgs, DeviceID, self()),
    {ok, DeviceWorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),
    timer:sleep(250),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Channel]),
    {ok, EventMgrRef} = router_channel:start_link(),
    Device = router_device:new(DeviceID),
    ok = router_channel:add(EventMgrRef, Channel, Device),
    timer:sleep(5000),
    gen_event:stop(EventMgrRef),
    gen_server:stop(DeviceWorkerPid),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

