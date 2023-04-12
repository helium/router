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
    StartTime = erlang:system_time(seconds),
    #{
        pubkey_bin := _PubKeyBin,
        stream := _Stream,
        hotspot_name := _HotspotName
    } = test_utils:join_device(Config),

    router_metrics ! ?METRICS_TICK,
    ok = timer:sleep(timer:seconds(1)),

    case router_blockchain:is_chain_dead() of
        false ->
            ?assertEqual(5000, prometheus_gauge:value(?METRICS_DC)),
            BlockAge = prometheus_gauge:value(?METRICS_CHAIN_BLOCKS),
            ct:pal("[~p:~p:~p] MARKER ~p~n", [
                ?MODULE,
                ?FUNCTION_NAME,
                ?LINE,
                {StartTime, BlockAge, erlang:system_time(seconds)}
            ]),
            ?assert(BlockAge > StartTime andalso BlockAge < erlang:system_time(seconds));
        true ->
            ?assertEqual(0, prometheus_gauge:value(?METRICS_DC))
    end,

    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_OPENED_COUNT)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_OVERSPENT_COUNT)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_ACTIVE_COUNT)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_ACTIVE_BALANCE)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_ACTIVE_ACTORS)),
    ?assertEqual(0, prometheus_gauge:value(?METRICS_SC_CLOSE_CONFLICT)),

    {_, RoutingPacketTime} = prometheus_histogram:value(?METRICS_ROUTING_PACKET, [
        join,
        accepted,
        accepted,
        true
    ]),
    %% Minimum of 2s per but it should not take more than 25ms
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, RoutingPacketTime]),
    ?assert(RoutingPacketTime > 1999 andalso RoutingPacketTime < 2025),

    {_, HoldTime} = prometheus_histogram:value(?METRICS_PACKET_HOLD_TIME, [join]),
    %% Hold Time is hard coded to 100ms in tests
    ?assertEqual(100, HoldTime),

    {_, ConsoleAPITime} = prometheus_histogram:value(?METRICS_CONSOLE_API_TIME, [report_status, ok]),
    ?assert(ConsoleAPITime < 100),

    ?assertEqual(true, prometheus_boolean:value(?METRICS_WS)),

    ?assert(prometheus_gauge:value(?METRICS_VM_CPU, [1]) > 0),

    %% When run with the grpc suite this value will be 1. When running tests
    %% without that suite, it will be 0.
    GRPCCount = prometheus_gauge:value(?METRICS_GRPC_CONNECTION_COUNT),
    ?assert(GRPCCount == 0 orelse GRPCCount == 1),

    ok = router_sc_worker:sc_hook_close_submit(ok, txn),
    ?assert(prometheus_counter:value(?METRICS_SC_CLOSE_SUBMIT, [ok]) > 0),

    ok = router_sc_worker:sc_hook_close_submit(error, txn),
    ?assert(prometheus_counter:value(?METRICS_SC_CLOSE_SUBMIT, [error]) > 0),
    ok.
