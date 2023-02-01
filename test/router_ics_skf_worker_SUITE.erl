-module(router_ics_skf_worker_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").
-include("console_test.hrl").
-include("lorawan_vars.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1
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
        main_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_skf_service, self()),
    Port = 8085,
    ServerPid = start_server(Port),
    ok = application:set_env(
        router,
        ics,
        #{skf_enabled => "true", host => "localhost", port => Port},
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

main_test(Config) ->
    meck:new(router_console_api, [passthrough]),
    meck:new(router_device_cache, [passthrough]),

    %% creating couple devices for testing
    Devices = lists:map(
        fun(X) ->
            ID = router_utils:uuid_v4(),
            router_device:update(
                [
                    {devaddrs, [<<X:32/integer-unsigned-big>>]},
                    {keys, [{crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(16)}]}
                ],
                router_device:new(ID)
            )
        end,
        lists:seq(1, 2)
    ),

    %% Add a device without any devaddr or session, it should be filtered out
    meck:expect(router_device_cache, get, fun() ->
        lager:notice("router_device_cache:get()"),
        BadDevice = router_device:new(<<"bad_device">>),
        [BadDevice | Devices]
    end),

    %% Add a fake device to config service, as it is not in Router's cache it should get removed
    router_test_ics_skf_service:send_list(
        #iot_config_session_key_filter_v1_pb{
            oui = 0,
            devaddr = 0,
            session_key = <<>>
        },
        true
    ),

    %% Check after reconcile, we should get the list and then 3 updates, (1 remove and 2 adds)
    [{Type3, Req3}, {Type2, Req2}, {Type1, Req1}, {Type0, _Req0}] = rcv_loop([]),
    [Device1, Device2] = Devices,

    ?assertEqual(list, Type0),
    ?assertEqual(update, Type1),
    ?assertEqual(remove, Req1#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = 0, devaddr = 0, session_key = <<>>
        },
        Req1#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type2),
    ?assertEqual(add, Req2#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = 1,
            session_key = router_device:nwk_s_key(Device1)
        },
        Req2#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type3),
    ?assertEqual(add, Req3#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = 2,
            session_key = router_device:nwk_s_key(Device2)
        },
        Req3#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Join a device to test device_worker code, we should see 1 add
    #{
        stream := Stream1,
        pubkey_bin := PubKeyBin1
    } = test_utils:join_device(Config),

    [{Type4, Req4}] = rcv_loop([]),
    ?assertEqual(update, Type4),
    ?assertEqual(add, Req4#iot_config_session_key_filter_update_req_v1_pb.action),

    {ok, JoinedDevice1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    <<JoinedDevAddr1:32/integer-unsigned-big>> = lorawan_utils:reverse(
        router_device:devaddr(JoinedDevice1)
    ),

    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr1,
            session_key = router_device:nwk_s_key(JoinedDevice1)
        },
        Req4#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Send first packet it should trigger another add (just in case)
    Stream1 !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin1,
                router_device:nwk_s_key(JoinedDevice1),
                router_device:app_s_key(JoinedDevice1),
                0
            )},

    [{Type5, Req5}] = rcv_loop([]),
    ?assertEqual(update, Type5),
    ?assertEqual(add, Req5#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr1,
            session_key = router_device:nwk_s_key(JoinedDevice1)
        },
        Req5#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Join device again
    #{
        stream := Stream2,
        pubkey_bin := PubKeyBin2
    } = test_utils:join_device(Config),

    [{Type6, Req6}] = rcv_loop([]),
    ?assertEqual(update, Type6),
    ?assertEqual(add, Req6#iot_config_session_key_filter_update_req_v1_pb.action),

    {ok, JoinedDevice2} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    <<JoinedDevAddr2:32/integer-unsigned-big>> = lorawan_utils:reverse(
        router_device:devaddr(JoinedDevice2)
    ),

    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr2,
            session_key = router_device:nwk_s_key(JoinedDevice2)
        },
        Req6#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Send first packet again, we should see add and remove this time
    Stream2 !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin2,
                router_device:nwk_s_key(JoinedDevice1),
                router_device:app_s_key(JoinedDevice1),
                0
            )},

    [{Type7, Req7}, {Type8, Req8}] = rcv_loop([]),
    ?assertEqual(update, Type7),
    ?assertEqual(remove, Req7#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr2,
            session_key = router_device:nwk_s_key(JoinedDevice2)
        },
        Req7#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type8),
    ?assertEqual(add, Req8#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr1,
            session_key = router_device:nwk_s_key(JoinedDevice1)
        },
        Req8#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    meck:unload(router_console_api),
    meck:unload(router_device_cache),
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
                'helium.iot_config.session_key_filter' => router_test_ics_skf_service
            }
        },
        listen_opts => #{port => Port, ip => {0, 0, 0, 0}}
    }),
    ServerPid.

rcv_loop(Acc) ->
    receive
        {router_test_ics_skf_service, Type, Req} ->
            lager:notice("got router_test_ics_skf_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.
