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
    server_crash_test/1,
    multiple_routes_test/1,
    route_id_from_env_test/1
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
        server_crash_test,
        multiple_routes_test,
        route_id_from_env_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_route_service, self()),
    Port = 8085,
    ServerPid = start_server(Port),
    ok = application:set_env(
        router,
        ics,
        #{devaddr_enabled => "true", host => "localhost", port => Port},
        [{persistent, true}]
    ),
    ok =
        case TestCase of
            multiple_routes_test ->
                application:set_env(router, test_route_list, [
                    #iot_config_route_v1_pb{id = "route-id-1"},
                    #iot_config_route_v1_pb{id = "route-id-2"}
                ]),
                ok;
            route_id_from_env_test ->
                ok = application:set_env(
                    router,
                    ics,
                    #{
                        devaddr_enabled => "true",
                        host => "localhost",
                        port => Port,
                        route_id => "route-id-from-env"
                    },
                    [{persistent, true}]
                );
            _ ->
                ok
        end,

    test_utils:init_per_testcase(TestCase, [{ics_server, ServerPid} | Config]).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config),
    ServerPid = proplists:get_value(ics_server, Config),
    case erlang:is_process_alive(ServerPid) of
        true -> gen_server:stop(ServerPid);
        false -> ok
    end,
    _ = application:stop(grpcbox),
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
    RouteID = "test_route_id",
    ok = router_test_ics_route_service:devaddr_range(
        #iot_config_devaddr_range_v1_pb{route_id = RouteID, start_addr = 1, end_addr = 2},
        true
    ),

    [{Type0, _Req0}, {Type1, _Req1}] = rcv_loop(),
    ?assertEqual(list, Type0),
    ?assertEqual(get_devaddr_ranges, Type1),

    ?assertEqual(
        {ok, [#iot_config_devaddr_range_v1_pb{route_id = RouteID, start_addr = 1, end_addr = 2}]},
        router_ics_devaddr_worker:get_devaddr_ranges()
    ),

    ok.

multiple_routes_test(_Config) ->
    RouteID = "route-id-1",
    ok = router_test_ics_route_service:devaddr_range(
        #iot_config_devaddr_range_v1_pb{route_id = RouteID, start_addr = 1, end_addr = 2},
        true
    ),

    [{Type0, _Req0}, {Type1, Req1}] = rcv_loop(),
    ?assertEqual(list, Type0),
    ?assertEqual(get_devaddr_ranges, Type1),
    %% Make sure we requested devaddr ranges for the first route in the list.
    ?assertEqual(RouteID, Req1#iot_config_route_get_devaddr_ranges_req_v1_pb.route_id),

    ?assertEqual(
        {ok, [#iot_config_devaddr_range_v1_pb{route_id = RouteID, start_addr = 1, end_addr = 2}]},
        router_ics_devaddr_worker:get_devaddr_ranges()
    ),

    ok.

route_id_from_env_test(_Config) ->
    RouteID = "route-id-from-env",
    ok = router_test_ics_route_service:devaddr_range(
        #iot_config_devaddr_range_v1_pb{route_id = RouteID, start_addr = 1, end_addr = 2},
        true
    ),

    [{Type0, Req0}] = rcv_loop(),
    ?assertNotEqual(list, Type0),
    ?assertEqual(get_devaddr_ranges, Type0),
    %% Make sure we requested devaddr ranges for the first route in the list.
    ?assertEqual(RouteID, Req0#iot_config_route_get_devaddr_ranges_req_v1_pb.route_id),

    ?assertEqual(
        {ok, [#iot_config_devaddr_range_v1_pb{route_id = RouteID, start_addr = 1, end_addr = 2}]},
        router_ics_devaddr_worker:get_devaddr_ranges()
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

start_server(Port) ->
    _ = application:ensure_all_started(grpcbox),
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [iot_config_pb],
            services => #{
                'helium.iot_config.route' => router_test_ics_route_service
            }
        },
        listen_opts => #{port => Port, ip => {0, 0, 0, 0}}
    }),
    ServerPid.

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
