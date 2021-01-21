-module(router_device_worker_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    device_update_test/1,
    drop_downlink_test/1,
    replay_joins_test/1,
    device_worker_stop_children_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

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
    [device_worker_stop_children_test, device_update_test, drop_downlink_test, replay_joins_test].

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

device_worker_stop_children_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    DevNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for report device status on that join request
    test_utils:wait_for_console_event(<<"activation">>, #{
        <<"category">> => <<"activation">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => 0,
        <<"frame_down">> => 0,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"selected">> => true,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => []
    }),

    GetPids = fun() ->
        {ok, DevicePid} = router_devices_sup:lookup_device_worker(?CONSOLE_DEVICE_ID),
        DeviceState = sys:get_state(DevicePid),

        ChannelWorkerPid = element(8, DeviceState),
        ChannelWorkerState = sys:get_state(ChannelWorkerPid),

        EventManagerPid = element(3, ChannelWorkerState),

        {DevicePid, ChannelWorkerPid, EventManagerPid}
    end,

    {DPid, CPid, EPid} = GetPids(),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    Report = fun(One, Two, Three) ->
        ct:print(
            "Before:~n"
            "Device    PID: ~p [alive: ~p]~n"
            "Channel   PID: ~p [alive: ~p]~n"
            "Event MGR PID: ~p [alive: ~p]~n",
            [
                One,
                erlang:is_process_alive(One),
                Two,
                erlang:is_process_alive(Two),
                Three,
                erlang:is_process_alive(Three)
            ]
        )
    end,

    Report(DPid, CPid, EPid),
    true = erlang:is_process_alive(DPid),
    true = erlang:is_process_alive(CPid),
    true = erlang:is_process_alive(EPid),
    gen_server:stop(DPid),
    Report(DPid, CPid, EPid),
    false = erlang:is_process_alive(DPid),
    false = erlang:is_process_alive(CPid),
    false = erlang:is_process_alive(EPid),

    ok.

device_update_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    DevNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for report device status on that join request
    test_utils:wait_for_console_event(<<"activation">>, #{
        <<"category">> => <<"activation">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => 0,
        <<"frame_down">> => 0,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"selected">> => true,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => []
    }),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    DeviceID = ?CONSOLE_DEVICE_ID,
    ?assertMatch({ok, _}, router_device:get_by_id(DB, CF, DeviceID)),

    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {device_not_found, true}),

    %% Sending debug event from websocket
    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    WSPid ! {device_update, <<"device:all">>},

    {ok, DeviceWorkerID} = router_devices_sup:lookup_device_worker(DeviceID),

    timer:sleep(500),
    ?assertNot(erlang:is_process_alive(DeviceWorkerID)),
    ?assertMatch({error, not_found}, router_device:get_by_id(DB, CF, DeviceID)),

    ok.

drop_downlink_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    DevNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for report device status on that join request
    test_utils:wait_for_console_event(<<"activation">>, #{
        <<"category">> => <<"activation">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => 0,
        <<"frame_down">> => 0,
        <<"payload_size">> => 0,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"selected">> => true,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => []
    }),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),
    DeviceID = ?CONSOLE_DEVICE_ID,

    {ok, DeviceWorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    Payload = crypto:strong_rand_bytes(243),
    Channel = router_channel:new(
        <<"fake">>,
        device_worker,
        <<"fake">>,
        #{},
        0,
        self()
    ),
    Msg = #downlink{confirmed = true, port = 2, payload = Payload, channel = Channel},
    ok = router_device_worker:queue_message(DeviceWorkerPid, Msg),

    test_utils:wait_for_console_event(<<"packet_dropped">>, #{
        <<"category">> => <<"packet_dropped">>,
        <<"description">> => <<"Packet request exceeds maximum 242 bytes">>,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => 0,
        <<"frame_down">> => 0,
        <<"payload_size">> => 243,
        <<"port">> => 2,
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [],
        <<"channels">> => []
    }),

    ok.

replay_joins_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    DevNonce1 = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce1)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for report device status on that join request
    test_utils:wait_for_console_event(<<"activation">>, #{
        <<"category">> => <<"activation">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => 0,
        <<"frame_down">> => 0,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"selected">> => true,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => []
    }),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, Device0} = router_device_cache:get(DeviceID),

    ?assertEqual(
        DevNonce1,
        test_utils:get_last_dev_nonce(DeviceID)
    ),

    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0
            )},

    %% Waiting for report channel status
    test_utils:wait_for_console_event(<<"up">>, #{
        <<"category">> => <<"up">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => fun erlang:is_integer/1,
        <<"frame_down">> => fun erlang:is_integer/1,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => [
            #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"description">> => '_'
            }
        ]
    }),

    {ok, Device1} = router_device_cache:get(DeviceID),
    ?assertEqual(
        [DevNonce1],
        router_device:dev_nonces(Device1)
    ),
    ?assertEqual(
        1,
        erlang:length(router_device:keys(Device1))
    ),
    ?assertEqual(
        router_device:nwk_s_key(Device0),
        router_device:nwk_s_key(Device1)
    ),
    ?assertEqual(
        router_device:app_s_key(Device0),
        router_device:app_s_key(Device1)
    ),
    ?assertEqual(
        undefined,
        test_utils:get_last_dev_nonce(DeviceID)
    ),

    %% We ignore the channel correction  and down messages
    ok = test_utils:ignore_messages(),

    %% This will act as an old valid nonce cause we have the right app key
    DevNonce2 = crypto:strong_rand_bytes(2),
    %% we are sending another join with an already used nonce to try to DOS the device
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce2)},
    timer:sleep(?JOIN_DELAY),

    %% We are not making sure that we maintain multiple keys and nonce in device just in case last join was valid
    {ok, Device2} = router_device_cache:get(DeviceID),
    ?assertEqual(
        [DevNonce1],
        router_device:dev_nonces(Device2)
    ),
    ?assertEqual(
        2,
        erlang:length(router_device:keys(Device2))
    ),
    ?assertNotEqual(
        router_device:nwk_s_key(Device0),
        router_device:nwk_s_key(Device2)
    ),
    ?assertNotEqual(
        router_device:app_s_key(Device0),
        router_device:app_s_key(Device2)
    ),
    ?assertEqual(
        DevNonce2,
        test_utils:get_last_dev_nonce(DeviceID)
    ),

    %% We repeat again to add a second "bad" attempt

    %% This will act as an old valid nonce cause we have the right app key
    DevNonce3 = crypto:strong_rand_bytes(2),
    %% we are sending another join with an already used nonce to try to DOS the device
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce3)},
    timer:sleep(?JOIN_DELAY),

    %% We are not making sure that we maintain multiple keys and nonce in device just in case last join was valid
    {ok, Device3} = router_device_cache:get(DeviceID),
    ?assertEqual(
        [DevNonce1],
        router_device:dev_nonces(Device3)
    ),
    ?assertEqual(
        3,
        erlang:length(router_device:keys(Device3))
    ),
    ?assertNotEqual(
        router_device:nwk_s_key(Device0),
        router_device:nwk_s_key(Device3)
    ),
    ?assertNotEqual(
        router_device:app_s_key(Device0),
        router_device:app_s_key(Device3)
    ),
    ?assertEqual(
        DevNonce3,
        test_utils:get_last_dev_nonce(DeviceID)
    ),

    %% The device then sends another normal packet linked to dev nonce 1
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                1
            )},

    %% Waiting for report channel status
    test_utils:wait_for_console_event(<<"up">>, #{
        <<"category">> => <<"up">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => fun erlang:is_integer/1,
        <<"frame_down">> => fun erlang:is_integer/1,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => [
            #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"description">> => '_'
            }
        ]
    }),

    %% We are not making sure that we nuke those fake join keys
    {ok, Device4} = router_device_cache:get(DeviceID),
    ?assertEqual(
        [DevNonce1],
        router_device:dev_nonces(Device4)
    ),
    ?assertEqual(
        1,
        erlang:length(router_device:keys(Device4))
    ),
    ?assertEqual(
        router_device:nwk_s_key(Device0),
        router_device:nwk_s_key(Device4)
    ),
    ?assertEqual(
        router_device:app_s_key(Device0),
        router_device:app_s_key(Device4)
    ),
    ?assertEqual(
        undefined,
        test_utils:get_last_dev_nonce(DeviceID)
    ),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
