-module(router_metrics_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    metrics_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("metrics.hrl").

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
        metrics_test
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

metrics_test(Config) ->
    StartTime = erlang:system_time(seconds),
    #{
        pubkey_bin := _PubKeyBin,
        stream := _Stream,
        hotspot_name := _HotspotName
    } = test_utils:join_device(Config),

    router_metrics ! ?METRICS_TICK,
    ok = timer:sleep(timer:seconds(1)),

    ?assertEqual(5000, prometheus_gauge:value(?METRICS_DC)),

    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_OPENED_COUNT)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_OVERSPENT_COUNT)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_ACTIVE_COUNT)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_ACTIVE_BALANCE)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_ACTIVE_ACTORS)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_CLOSE_CONFLICT)),

    {_, RoutingPacketTime} = prometheus_histogram:value(?METRICS_ROUTING_PACKET, [join, accepted, accepted, true]),
    %% Minimum of 2s per but it should not take more than 25ms
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, RoutingPacketTime]),
    ?assert(RoutingPacketTime > 1999 andalso RoutingPacketTime < 2025),

    {_, HoldTime} = prometheus_histogram:value(?METRICS_PACKET_HOLD_TIME, [join]),
    %% Hold Time is hard coded to 100ms in tests
    ?assertEqual(100, HoldTime),

    {_, ConsoleAPITime} = prometheus_histogram:value(?METRICS_CONSOLE_API_TIME, [report_status, ok]),
    ?assert(ConsoleAPITime < 100),

    ?assertEqual(true, prometheus_boolean:value(?METRICS_WS)),

    BlockAge = prometheus_gauge:value(?METRICS_CHAIN_BLOCKS),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, {StartTime, BlockAge, erlang:system_time(seconds)}]),
    ?assert(BlockAge > StartTime andalso BlockAge < erlang:system_time(seconds)),

    ?assert(prometheus_gauge:value(?METRICS_VM_CPU, [1]) > 0),
    ok.
