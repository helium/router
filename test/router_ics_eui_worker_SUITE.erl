-module(router_ics_eui_worker_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1,
    reconcile_test/1,
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
        reconcile_test,
        server_crash_test
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
        #{eui_enabled => "true", host => "localhost", port => Port},
        [{persistent, true}]
    ),
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
    meck:new(router_console_api, [passthrough]),
    meck:new(router_device_cache, [passthrough]),

    RouteID = "test_route_id",
    ID1 = router_utils:uuid_v4(),
    Device1 = router_device:update(
        [
            {app_eui, <<1:64/integer-unsigned-big>>},
            {dev_eui, <<1:64/integer-unsigned-big>>}
        ],
        router_device:new(ID1)
    ),
    ID2 = router_utils:uuid_v4(),
    Device2 = router_device:update(
        [
            {app_eui, <<1:64/integer-unsigned-big>>},
            {dev_eui, <<2:64/integer-unsigned-big>>}
        ],
        router_device:new(ID2)
    ),
    Devices = #{
        ID1 => Device1,
        ID2 => Device2
    },

    meck:expect(router_console_api, get_device, fun(DeviceID) ->
        lager:notice("router_console_api:get_device(~p)", [DeviceID]),
        {ok, maps:get(DeviceID, Devices)}
    end),

    meck:expect(router_device_cache, get, fun(DeviceID) ->
        lager:notice("router_device_cache:get(~p)", [DeviceID]),
        {ok, maps:get(DeviceID, Devices)}
    end),

    ok = router_test_ics_route_service:eui_pair(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0}, true
    ),

    [{Type3, Req3}, {Type2, Req2}, {Type1, _Req1}, {Type0, _Req0}] = rcv_loop([]),
    ?assertEqual(list, Type0),
    ?assertEqual(get_euis, Type1),
    ?assertEqual(update_euis, Type2),
    ?assertEqual(remove, Req2#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0},
        Req2#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),
    ?assertEqual(update_euis, Type3),
    ?assertEqual(add, Req3#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 8589934593, dev_eui = 1},
        Req3#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),

    ok = router_ics_eui_worker:add([ID1]),

    [{Type4, Req4}] = rcv_loop([]),
    ?assertEqual(update_euis, Type4),
    ?assertEqual(add, Req4#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 1, dev_eui = 1},
        Req4#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),

    ok = router_ics_eui_worker:remove([ID2]),

    [{Type5, Req5}] = rcv_loop([]),
    ?assertEqual(update_euis, Type5),
    ?assertEqual(remove, Req5#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 1, dev_eui = 2},
        Req5#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),

    meck:expect(router_console_api, get_device, fun(DeviceID) ->
        lager:notice("router_console_api:get_device(~p)", [DeviceID]),
        case DeviceID of
            ID1 -> {error, not_found};
            ID2 -> {ok, maps:get(ID2, Devices)}
        end
    end),

    meck:expect(router_device_cache, get, fun(DeviceID) ->
        lager:notice("router_console_api:get_device(~p)", [DeviceID]),
        case DeviceID of
            ID1 -> {ok, maps:get(ID1, Devices)};
            ID2 -> {error, not_found}
        end
    end),

    ok = router_ics_eui_worker:update([ID1, ID2]),

    [{Type7, Req7}, {Type6, Req6}] = rcv_loop([]),
    ?assertEqual(update_euis, Type6),
    ?assertEqual(remove, Req6#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 1, dev_eui = 1},
        Req6#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),

    ?assertEqual(update_euis, Type7),
    ?assertEqual(add, Req7#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 1, dev_eui = 2},
        Req7#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),

    meck:unload(router_console_api),
    meck:unload(router_device_cache),
    ok.

reconcile_test(_Config) ->
    meck:new(router_console_api, [passthrough]),
    meck:new(router_device_cache, [passthrough]),

    RouteID = "test_route_id",
    ID1 = router_utils:uuid_v4(),
    Device1 = router_device:update(
        [
            {app_eui, <<1:64/integer-unsigned-big>>},
            {dev_eui, <<1:64/integer-unsigned-big>>}
        ],
        router_device:new(ID1)
    ),
    ID2 = router_utils:uuid_v4(),
    Device2 = router_device:update(
        [
            {app_eui, <<1:64/integer-unsigned-big>>},
            {dev_eui, <<2:64/integer-unsigned-big>>}
        ],
        router_device:new(ID2)
    ),
    Devices = #{
        ID1 => Device1,
        ID2 => Device2
    },

    meck:expect(router_console_api, get_device, fun(DeviceID) ->
        lager:notice("router_console_api:get_device(~p)", [DeviceID]),
        {ok, maps:get(DeviceID, Devices)}
    end),

    meck:expect(router_device_cache, get, fun(DeviceID) ->
        lager:notice("router_device_cache:get(~p)", [DeviceID]),
        {ok, maps:get(DeviceID, Devices)}
    end),

    ok = router_test_ics_route_service:eui_pair(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0}, true
    ),

    [{Type3, Req3}, {Type2, Req2}, {Type1, _Req1}, {Type0, _Req0}] = rcv_loop([]),
    ?assertEqual(list, Type0),
    ?assertEqual(get_euis, Type1),
    ?assertEqual(update_euis, Type2),
    ?assertEqual(remove, Req2#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0},
        Req2#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),
    ?assertEqual(update_euis, Type3),
    ?assertEqual(add, Req3#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 8589934593, dev_eui = 1},
        Req3#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),

    meck:expect(router_console_api, get_json_devices, fun() ->
        lager:notice("router_console_api:get_json_devices()"),
        JSONDevices = lists:map(
            fun(X) ->
                #{
                    <<"app_eui">> => lorawan_utils:binary_to_hex(<<X:64/integer-unsigned-big>>),
                    <<"dev_eui">> => lorawan_utils:binary_to_hex(<<X:64/integer-unsigned-big>>)
                }
            end,
            lists:seq(1, 20)
        ),
        {ok, JSONDevices}
    end),

    ok = router_ics_eui_worker:reconcile(self()),

    ok = router_test_ics_route_service:eui_pair(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0}, true
    ),

    receive
        {router_ics_eui_worker, Result} ->
            %% We added 20 and removed 1
            ?assertEqual({ok, 20, 1}, Result)
    after 5000 ->
        ct:fail(timeout)
    end,

    meck:unload(router_console_api),
    meck:unload(router_device_cache),
    ok.

server_crash_test(Config) ->
    meck:new(router_console_api, [passthrough]),
    meck:new(router_device_cache, [passthrough]),

    RouteID = "test_route_id",
    ID1 = router_utils:uuid_v4(),
    Device1 = router_device:update(
        [
            {app_eui, <<1:64/integer-unsigned-big>>},
            {dev_eui, <<1:64/integer-unsigned-big>>}
        ],
        router_device:new(ID1)
    ),
    ID2 = router_utils:uuid_v4(),
    Device2 = router_device:update(
        [
            {app_eui, <<1:64/integer-unsigned-big>>},
            {dev_eui, <<2:64/integer-unsigned-big>>}
        ],
        router_device:new(ID2)
    ),
    Devices = #{
        ID1 => Device1,
        ID2 => Device2
    },

    meck:expect(router_console_api, get_device, fun(DeviceID) ->
        lager:notice("router_console_api:get_device(~p)", [DeviceID]),
        {ok, maps:get(DeviceID, Devices)}
    end),

    meck:expect(router_device_cache, get, fun(DeviceID) ->
        lager:notice("router_device_cache:get(~p)", [DeviceID]),
        {ok, maps:get(DeviceID, Devices)}
    end),

    ok = router_test_ics_route_service:eui_pair(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0}, true
    ),

    [{Type3, Req3}, {Type2, Req2}, {Type1, _Req1}, {Type0, _Req0}] = rcv_loop([]),
    ?assertEqual(list, Type0),
    ?assertEqual(get_euis, Type1),
    ?assertEqual(update_euis, Type2),
    ?assertEqual(remove, Req2#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0},
        Req2#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),
    ?assertEqual(update_euis, Type3),
    ?assertEqual(add, Req3#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 8589934593, dev_eui = 1},
        Req3#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),

    ok = gen_server:stop(proplists:get_value(ics_server, Config)),

    lager:notice("server stoppped"),
    timer:sleep(250),

    ?assertEqual({error, {shutdown, econnrefused}}, router_ics_eui_worker:add([ID1])),

    ServerPid = start_server(8085),

    timer:sleep(1000),
    lager:notice("server started"),

    ok = router_test_ics_route_service:eui_pair(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0}, true
    ),

    [{Type7, Req7}, {Type6, Req6}, {Type5, _Req5}, {Type4, _Req4}] = rcv_loop([]),
    ?assertEqual(list, Type4),
    ?assertEqual(get_euis, Type5),
    ?assertEqual(update_euis, Type6),
    ?assertEqual(remove, Req6#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0},
        Req6#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),
    ?assertEqual(update_euis, Type7),
    ?assertEqual(add, Req7#iot_config_route_update_euis_req_v1_pb.action),
    ?assertEqual(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 8589934593, dev_eui = 1},
        Req7#iot_config_route_update_euis_req_v1_pb.eui_pair
    ),

    ok = gen_server:stop(ServerPid),
    meck:unload(router_console_api),
    meck:unload(router_device_cache),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

rcv_loop(Acc) ->
    receive
        {router_test_ics_route_service, Type, Req} ->
            lager:notice("got router_test_ics_route_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.

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
