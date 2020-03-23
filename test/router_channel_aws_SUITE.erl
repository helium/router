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
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

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

