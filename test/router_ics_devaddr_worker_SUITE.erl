-module(router_ics_devaddr_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1,
    ignore_ranges_outside_net_id_test/1,
    server_crash_test/1
]).

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
        main_test,
        ignore_ranges_outside_net_id_test,
        server_crash_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_route_service, self()),
    ok = application:set_env(
        router,
        ics,
        #{
            devaddr_enabled => "true",

            route_id => "test_route_id"
        },
        [{persistent, true}]
    ),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config),
    ok = application:set_env(
        router,
        ics,
        #{},
        [{persistent, true}]
    ),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

main_test(_Config) ->
    Range1 = #iot_config_devaddr_range_v1_pb{
        route_id = "test_route_id",
        start_addr = binary:decode_unsigned(binary:decode_hex(<<"48000000">>)),
        end_addr = binary:decode_unsigned(binary:decode_hex(<<"48000007">>))
    },
    Range2 = #iot_config_devaddr_range_v1_pb{
        route_id = "test_route_id",
        start_addr = binary:decode_unsigned(binary:decode_hex(<<"48000020">>)),
        end_addr = binary:decode_unsigned(binary:decode_hex(<<"48000022">>))
    },

    ok = router_test_ics_route_service:devaddr_ranges([Range1, Range2]),
    timer:sleep(100),

    ?assertMatch([{get_devaddr_ranges, _Req}], rcv_loop()),

    ?assertEqual(
        {ok, [Range2, Range1]},
        router_ics_devaddr_worker:get_devaddr_ranges()
    ),

    ?assertEqual(
        {ok, lists:seq(0, 7) ++ lists:seq(32, 34)},
        router_device_devaddr:get_devaddr_bases()
    ),

    ok.

ignore_ranges_outside_net_id_test(_Config) ->
    Range1 = #iot_config_devaddr_range_v1_pb{
        route_id = "test_route_id",
        start_addr = binary:decode_unsigned(binary:decode_hex(<<"48000000">>)),
        end_addr = binary:decode_unsigned(binary:decode_hex(<<"48000007">>))
    },

    Range2 = #iot_config_devaddr_range_v1_pb{
        route_id = "test_route_id",
        start_addr = binary:decode_unsigned(binary:decode_hex(<<"72000008">>)),
        end_addr = binary:decode_unsigned(binary:decode_hex(<<"7200000F">>))
    },

    ok = router_test_ics_route_service:devaddr_ranges([Range1, Range2]),
    timer:sleep(100),

    ?assertMatch([{get_devaddr_ranges, _Req}], rcv_loop()),

    %% We keep both ranges for inspection
    ?assertEqual(
        {ok, [Range2, Range1]},
        router_ics_devaddr_worker:get_devaddr_ranges()
    ),

    %% 72000008 - 7200000F range is not sent to the allocator
    ?assertEqual(
        {ok, lists:seq(0, 7)},
        router_device_devaddr:get_devaddr_bases()
    ),

    ok.

server_crash_test(_Config) ->
    %% NOTE: The Devaddr worker is not like the other workers because it's
    %% purpose is to grab 1 bit of information on startup. Because it's not
    %% continually using the connection to the config service, it will never
    %% know if the config server went down _after_ it fetched the information it
    %% needs.

    %% RouteID = "test_route_id",
    %% ok = router_test_ics_route_service:devaddr_range(
    %%     #iot_config_devaddr_range_v1_pb{route_id = RouteID, start_addr = 1, end_addr = 2},
    %%     true
    %% ),

    %% %% Fetch the route and devaddr_ranges on startup
    %% [{Type0, _Req0}, {Type1, _Req1}] = rcv_loop(),
    %% ?assertEqual(list, Type0),
    %% ?assertEqual(get_devaddr_ranges, Type1),

    %% %% ===================================================================
    %% %% kill and restart the test server
    %% ok = gen_server:stop(proplists:get_value(ics_server, Config)),
    %% lager:notice("server stopped"),
    %% timer:sleep(250),

    %% ServerPid = start_server(8085),
    %% timer:sleep(1000),
    %% lager:notice("server started"),

    %% %% ===================================================================
    %% %% Refetch the route and devaddr ranges when the connection comes back
    %% ok = router_test_ics_route_service:devaddr_range(
    %%     #iot_config_devaddr_range_v1_pb{route_id = RouteID, start_addr = 1, end_addr = 2},
    %%     true
    %% ),

    %% [{Type2, _Req2}, {Type3, _Req3}] = rcv_loop(),
    %% ?assertEqual(list, Type2),
    %% ?assertEqual(get_devaddr_ranges, Type3),

    %% ok = gen_server:stop(ServerPid),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

rcv_loop() ->
    lists:reverse(rcv_loop([])).

rcv_loop(Acc) ->
    receive
        {router_test_ics_route_service, Type, Req} ->
            lager:notice("got router_test_ics_route_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) ->
        Acc
    end.
