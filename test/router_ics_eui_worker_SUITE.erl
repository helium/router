-module(router_ics_eui_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    all/0,
    groups/0,
    init_per_testcase/2,
    end_per_testcase/2,
    init_per_group/2,
    end_per_group/2
]).

-export([
    main_test/1,
    reconcile_test/1,
    server_crash_test/1,
    ignore_start_when_no_route_id/1
]).

-define(ROUTE_ID, "test_route_id").

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
        main_test,
        reconcile_test,
        server_crash_test,
        ignore_start_when_no_route_id
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_group(GroupName, Config) ->
    test_utils:init_per_group(GroupName, Config).

init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_route_service, self()),
    ICSOpts0 = #{
        eui_enabled => "true",
        route_id => ?ROUTE_ID
    },
    ICSOpts1 =
        case TestCase of
            ignore_start_when_no_route_id -> maps:put(route_id, "", ICSOpts0);
            _ -> ICSOpts0
        end,
    ok = application:set_env(
        router,
        ics,
        ICSOpts1,
        [{persistent, true}]
    ),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_group(GroupName, Config) ->
    test_utils:end_per_group(GroupName, Config).

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
    meck:new(router_console_api, [passthrough]),
    meck:new(router_device_cache, [passthrough]),

    RouteID = ?ROUTE_ID,
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

    [{Type3, Req3}, {Type2, Req2}, {Type1, _Req1}] = rcv_loop([]),
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

    ok =
        receive
            {console_filter_update, _Added, _Removed} ->
                ct:print("adding: ~p removing: ~p", [length(_Added), length(_Removed)]),
                ok
        after 2150 -> ct:fail("No console message about adding devices")
        end,

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

    %% Simulate server side processsing by telling the test service to wait
    %% before closing it's side of the stream after the client has signaled it
    %% is done sending updates.

    %% NOTE: Settting this value over the number of TimeoutAttempt will wait for
    %% a tream close will cause this test to fail, it will look like the worker
    %% has tried to reconcile again.
    ok = application:set_env(router, test_eui_update_eos_timeout, timer:seconds(2)),

    RouteID = ?ROUTE_ID,
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

    [{Type3, Req3}, {Type2, Req2}, {Type1, _Req1}] = rcv_loop([]),
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

    ok = router_ics_eui_worker:reconcile(self(), true),

    ok = router_test_ics_route_service:eui_pair(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0}, true
    ),

    ToBeAdded = lists:map(
        fun(X) ->
            #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = X, dev_eui = X}
        end,
        lists:seq(1, 20)
    ),
    ToBeRemoved = [#iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0}],
    receive
        {router_ics_eui_worker, Result} ->
            %% We added 20 and removed 1
            ?assertEqual({ok, ToBeAdded, ToBeRemoved}, Result)
    after 5000 ->
        ct:fail(timeout)
    end,

    meck:unload(router_console_api),
    meck:unload(router_device_cache),
    ok.

server_crash_test(_Config) ->
    meck:new(router_console_api, [passthrough]),
    meck:new(router_device_cache, [passthrough]),

    RouteID = ?ROUTE_ID,
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

    [{Type3, Req3}, {Type2, Req2}, {Type1, _Req1}] = rcv_loop([]),
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

    %% ok = gen_server:stop(proplists:get_value(ics_server, Config)),
    ok = application:stop(grpcbox),

    lager:notice("server stoppped"),
    timer:sleep(250),

    %% TODO: Kill single grpcbox server rather than entire app.
    %% ?assertEqual({error, {shutdown, econnrefused}}, router_ics_eui_worker:add([ID1])),
    ?assertEqual({error, undefined_channel}, router_ics_eui_worker:add([ID1])),

    %% ServerPid = start_server(8085),
    {ok, _} = application:ensure_all_started(grpcbox),

    timer:sleep(1000),
    lager:notice("server started"),

    ok = router_test_ics_route_service:eui_pair(
        #iot_config_eui_pair_v1_pb{route_id = RouteID, app_eui = 0, dev_eui = 0}, true
    ),

    [{Type7, Req7}, {Type6, Req6}, {Type5, _Req5}] = rcv_loop([]),
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

    %% ok = gen_server:stop(ServerPid),
    meck:unload(router_console_api),
    meck:unload(router_device_cache),
    ok.

ignore_start_when_no_route_id(_Config) ->
    ?assertEqual(undefined, whereis(router_ics_eui_worker)),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

rcv_loop(Acc) ->
    receive
        {router_test_ics_route_service, get_devaddr_ranges, _Req} ->
            rcv_loop(Acc);
        {router_test_ics_route_service, Type, Req} ->
            lager:notice("got router_test_ics_route_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.
