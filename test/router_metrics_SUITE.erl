-module(router_metrics_SUITE).

-export([
    all/0,
    groups/0,
    init_per_testcase/2,
    end_per_testcase/2,
    init_per_group/2,
    end_per_group/2
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
        {group, chain_alive},
        {group, chain_dead}
    ].

groups() ->
    [
        {chain_alive, all_tests()},
        {chain_dead, all_tests()}
    ].

all_tests() ->
    [
        metrics_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_group(GroupName, Config) ->
    test_utils:init_per_group(GroupName, Config).

init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_group(GroupName, Config) ->
    test_utils:end_per_group(GroupName, Config).

end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

metrics_test(Config) ->
    #{
        pubkey_bin := _PubKeyBin,
        stream := _Stream,
        hotspot_name := _HotspotName
    } = test_utils:join_device(Config),

    router_metrics ! ?METRICS_TICK,
    ok = timer:sleep(timer:seconds(1)),

    {_, RoutingPacketTime} = prometheus_histogram:value(?METRICS_ROUTING_PACKET, [
        join,
        accepted,
        accepted,
        true
    ]),
    %% Minimum of 2s per but it should not take more than 25ms
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, RoutingPacketTime]),
    ?assert(RoutingPacketTime > 1999 andalso RoutingPacketTime < 2025),

    {_, ConsoleAPITime} = prometheus_histogram:value(?METRICS_CONSOLE_API, [
        report_status, ok
    ]),
    ?assert(ConsoleAPITime < 100),

    ?assertEqual(true, prometheus_boolean:value(?METRICS_WS)),

    ?assert(prometheus_gauge:value(?METRICS_VM_CPU, [1]) > 0),

    ok.
