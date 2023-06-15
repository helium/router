-module(router_device_worker_SUITE).

-export([
    all/0,
    groups/0,
    init_per_testcase/2,
    end_per_testcase/2,
    init_per_group/2,
    end_per_group/2
]).

-export([
    device_update_test/1,
    device_update_app_eui_reset_devaddr_test/1,
    device_update_dev_eui_reset_devaddr_test/1,
    drop_downlink_test/1,
    replay_joins_test/1,
    ddos_joins_test/1,
    replay_uplink_test/1,
    device_worker_stop_children_test/1,
    device_worker_late_packet_double_charge_test/1,
    offer_cache_test/1,
    load_offer_cache_test/1,
    hotspot_bad_region_test/1,
    uplink_bad_mtype/1,
    evict_keys_join_test/1
]).

-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

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
        device_worker_stop_children_test,
        device_update_test,
        device_update_app_eui_reset_devaddr_test,
        device_update_dev_eui_reset_devaddr_test,
        drop_downlink_test,
        replay_joins_test,
        ddos_joins_test,
        replay_uplink_test,
        device_worker_late_packet_double_charge_test,
        offer_cache_test,
        load_offer_cache_test,
        hotspot_bad_region_test,
        uplink_bad_mtype,
        evict_keys_join_test
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
device_worker_late_packet_double_charge_test(Config) ->
    #{
        stream := Stream,
        pubkey_bin := PubKeyBin1,
        hotspot_name := HotspotName1
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache
    {ok, DB, CF} = router_db:get_devices(),
    WorkerId = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device} = router_device:get_by_id(DB, CF, WorkerId),

    SendPacketFun = fun(PubKeyBin, Fcnt) ->
        Stream !
            {send,
                test_utils:frame_packet(
                    ?UNCONFIRMED_UP,
                    PubKeyBin,
                    router_device:nwk_s_key(Device),
                    router_device:app_s_key(Device),
                    Fcnt
                )}
    end,

    {StartingBalance, StartingNonce} = router_console_dc_tracker:current_balance(?CONSOLE_ORG_ID),

    %% NOTE: multi-buy is 1 by default
    %% multi-buy is only in routing. This test does not exercise that code.

    %% make another hotspot
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    {ok, _HotspotName2} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin2)),

    %% Simulate multiple hotspots sending data
    SendPacketFun(PubKeyBin1, 0),
    test_utils:wait_until(fun() ->
        %% Wait until our device has handled the previous frame.
        %% We know because it will update it's fcnt
        %% And the next packet we send will be "late"
        test_utils:get_device_last_seen_fcnt(?CONSOLE_DEVICE_ID) == 0
    end),
    SendPacketFun(PubKeyBin2, 0),

    %% Waiting for data from HTTP channel with 1 hotspots
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => fun erlang:is_integer/1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0,
            <<"preferred_hotspots">> => fun erlang:is_list/1
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"port">> => 1,
        <<"devaddr">> => '_',

        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName1),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
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
        <<"dc">> => #{
            <<"balance">> => fun erlang:is_integer/1,
            <<"nonce">> => fun erlang:is_integer/1
        }
    }),

    {ok, #{<<"id">> := UplinkUUID}} = test_utils:wait_for_console_event_sub(
        <<"uplink_unconfirmed">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"dc">> => #{<<"balance">> => 98, <<"nonce">> => 1, <<"used">> => 1},
                <<"fcnt">> => fun erlang:is_integer/1,
                <<"payload_size">> => fun erlang:is_integer/1,
                <<"payload">> => fun erlang:is_binary/1,
                <<"raw_packet">> => fun erlang:is_binary/1,
                <<"port">> => fun erlang:is_integer/1,
                <<"devaddr">> => fun erlang:is_binary/1,
                <<"hotspot">> => #{
                    <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                    <<"name">> => erlang:list_to_binary(HotspotName1),
                    <<"rssi">> => 0.0,
                    <<"snr">> => 0.0,
                    <<"spreading">> => <<"SF8BW125">>,
                    <<"frequency">> => fun erlang:is_float/1,
                    <<"channel">> => fun erlang:is_number/1,
                    <<"lat">> => fun erlang:is_float/1,
                    <<"long">> => fun erlang:is_float/1
                },
                <<"mac">> => [],
                <<"hold_time">> => fun erlang:is_integer/1
            }
        }
    ),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_req">>, #{
        <<"id">> => UplinkUUID,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_req">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Request sent to ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"method">> => <<"POST">>,
                <<"url">> => <<?CONSOLE_URL/binary, "/channel">>,
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1,
                <<"url_params">> => fun test_utils:is_jsx_encoded_map/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{
                <<"body">> => <<"success">>,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => 200
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"downlink_unconfirmed">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_unconfirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => fun erlang:is_integer/1,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName1),
                <<"rssi">> => 30,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW500">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            },
            <<"integration">> => #{
                <<"id">> => fun erlang:is_binary/1,
                <<"name">> => fun erlang:is_binary/1,
                <<"status">> => <<"success">>
            },
            <<"mac">> => [
                #{
                    <<"channel_mask">> => 0,
                    <<"channel_mask_control">> => 7,
                    <<"command">> => <<"link_adr_req">>,
                    <<"data_rate">> => 2,
                    <<"number_of_transmissions">> => 0,
                    <<"tx_power">> => 0
                },
                #{
                    <<"channel_mask">> => 65280,
                    <<"channel_mask_control">> => 0,
                    <<"command">> => <<"link_adr_req">>,
                    <<"data_rate">> => 2,
                    <<"number_of_transmissions">> => 0,
                    <<"tx_power">> => 0
                }
            ]
        }
    }),

    %% Make sure no extra messages are being sent to console for the late packet
    receive
        {channel_data, Data} ->
            ct:fail("Unexpected Channel Data ~p", [Data]);
        {console_event, Cat, Event} ->
            ct:fail("Unexpected Console Event ~p ~n~p", [Cat, Event])
    after 1250 -> ok
    end,

    %% Make sure DC is not being charged for the late packet.
    {EndingBalance, EndingNonce} = router_console_dc_tracker:current_balance(?CONSOLE_ORG_ID),

    ?assertEqual(EndingBalance, StartingBalance - 1),
    ?assertEqual(EndingNonce, StartingNonce),

    ok.

device_worker_stop_children_test(Config) ->
    #{} = test_utils:join_device(Config),

    GetPids = fun() ->
        {ok, DeviceWorkerPid} = router_devices_sup:lookup_device_worker(?CONSOLE_DEVICE_ID),

        ChannelsWorkerPid = test_utils:get_device_channels_worker(?CONSOLE_DEVICE_ID),
        EventManagerPid = test_utils:get_channel_worker_event_manager(?CONSOLE_DEVICE_ID),

        {DeviceWorkerPid, ChannelsWorkerPid, EventManagerPid}
    end,

    {DeviceWorkerPid, ChannelsWorkerPid, EventManagerPid} = GetPids(),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    ?assert(erlang:is_process_alive(DeviceWorkerPid)),
    ?assert(erlang:is_process_alive(ChannelsWorkerPid)),
    ?assert(erlang:is_process_alive(EventManagerPid)),
    gen_server:stop(DeviceWorkerPid),

    test_utils:wait_until(fun() ->
        erlang:is_process_alive(DeviceWorkerPid) == false andalso
            erlang:is_process_alive(ChannelsWorkerPid) == false andalso
            erlang:is_process_alive(EventManagerPid)
    end),

    ok.

device_update_test(Config) ->
    #{} = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% We're going to make sure removes were sent.
    ok = persistent_term:put(router_test_ics_route_service, self()),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, Device0} = router_device:get_by_id(DB, CF, DeviceID),

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

    test_utils:wait_until(fun() -> erlang:is_process_alive(DeviceWorkerID) == false end),
    ?assertMatch({error, not_found}, router_device:get_by_id(DB, CF, DeviceID)),

    %% Make sure the device has removed itself from the config service after being deleted in Console.
    receive
        {router_test_ics_route_service, update_euis, Req} ->
            AppEui = binary:decode_unsigned(router_device:app_eui(Device0), big),
            DevEui = binary:decode_unsigned(router_device:dev_eui(Device0), big),

            ?assertEqual(remove, Req#iot_config_route_update_euis_req_v1_pb.action),

            EuiPair = Req#iot_config_route_update_euis_req_v1_pb.eui_pair,
            ?assertEqual(AppEui, EuiPair#iot_config_eui_pair_v1_pb.app_eui),
            ?assertEqual(DevEui, EuiPair#iot_config_eui_pair_v1_pb.dev_eui),
            ok
    after timer:seconds(2) -> ct:fail(expected_update_euis)
    end,

    receive
        {router_test_ics_route_service, update_skfs, Req1} ->
            {DevAddrInt, NwkKey} = router_ics_skf_worker:device_to_devaddr_nwk_key(Device0),
            SessionKey = erlang:binary_to_list(binary:encode_hex(NwkKey)),
            [Update] = Req1#iot_config_route_skf_update_req_v1_pb.updates,

            ?assertEqual(remove, Update#iot_config_route_skf_update_v1_pb.action),
            ?assertEqual(DevAddrInt, Update#iot_config_route_skf_update_v1_pb.devaddr),
            ?assertEqual(SessionKey, Update#iot_config_route_skf_update_v1_pb.session_key),
            ok
    after timer:seconds(2) -> ct:fail(expected_skf_update)
    end,

    ok.

device_update_app_eui_reset_devaddr_test(Config) ->
    #{} = test_utils:join_device(Config),
    {ok, WSPid} = test_utils:ws_init(),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    DeviceID = ?CONSOLE_DEVICE_ID,
    D1 = test_utils:get_device_worker_device(DeviceID),

    %% Make sure joined device has a session
    ?assertNotEqual(undefined, router_device:devaddr(D1)),

    %% Setup for next fetch to return a new value
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {app_eui, crypto:strong_rand_bytes(8)}),

    %% Update devices, wait for update to go through
    WSPid ! {device_update, <<"device:all">>},
    timer:sleep(100),

    %% Devaddr has been reset because the join credentials changed
    D2 = test_utils:get_device_worker_device(DeviceID),
    ?assertEqual(undefined, router_device:devaddr(D2)),

    ok.

device_update_dev_eui_reset_devaddr_test(Config) ->
    #{} = test_utils:join_device(Config),
    {ok, WSPid} = test_utils:ws_init(),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    DeviceID = ?CONSOLE_DEVICE_ID,
    D1 = test_utils:get_device_worker_device(DeviceID),

    %% Make sure joined device has a session
    ?assertNotEqual(undefined, router_device:devaddr(D1)),

    %% Setup for next fetch to return a new value
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {dev_eui, crypto:strong_rand_bytes(8)}),

    %% Update devices, wait for update to go through
    WSPid ! {device_update, <<"device:all">>},
    timer:sleep(100),

    %% Devaddr has been reset because the join credentials changed
    D2 = test_utils:get_device_worker_device(DeviceID),
    ?assertEqual(undefined, router_device:devaddr(D2)),

    ok.

drop_downlink_test(Config) ->
    #{} = test_utils:join_device(Config),

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
    ok = router_device_worker:queue_downlink(DeviceWorkerPid, Msg),

    Plan = lora_plan:region_to_plan('US915'),
    DatarateDown = lora_plan:up_to_down_datarate(Plan, 2, 0),
    MaxSize = lora_plan:max_downlink_payload_size(Plan, DatarateDown),
    Description = erlang:list_to_binary(
        io_lib:format("Payload too big for DR~p max size is ~p (payload was 243)", [
            DatarateDown,
            MaxSize
        ])
    ),

    test_utils:wait_for_console_event_sub(<<"downlink_dropped_payload_size_exceeded">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink_dropped">>,
        <<"sub_category">> => <<"downlink_dropped_payload_size_exceeded">>,
        <<"description">> => Description,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"integration">> => #{
                <<"id">> => <<"fake">>,
                <<"name">> => <<"fake">>,
                <<"status">> => <<"error">>
            }
        }
    }),

    ok.

evict_keys_join_test(Config) ->
    %% If a device get's stuck in a join loop, we will only keep the last 25
    %% devaddrs and key sets. When there is a successful uplink after joining,
    %% all the keys not used will be removed. But if there were more than 25
    %% attempts, we cannot remove keys that have been cycled out.
    #{} = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, Device0} = router_device_cache:get(DeviceID),

    Device1 = router_device:update(
        [
            {keys, [
                {crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(16)}
             || _ <- lists:seq(1, 25)
            ]},
            {devaddrs, [crypto:strong_rand_bytes(4) || _ <- lists:seq(1, 25)]}
        ],
        Device0
    ),
    {ok, DB, CF} = router_db:get_devices(),
    {ok, Device1} = router_device_cache:save(Device1),
    {ok, Device1} = router_device:save(DB, CF, Device1),

    {ok, DeviceWorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    %% Stop the device worker so it will pick up the newly saved device from the cache.
    ok = gen_server:stop(DeviceWorkerPid),

    %% Joining the device should evict 1 of the keys and devaddrs.

    ok = meck:new(router_ics_skf_worker, [passthrough]),

    #{} = test_utils:join_device(Config),

    [
        {_Pid0, {router_ics_skf_worker, update, [Updates] = _Args0}, ok},
        {_Pid1, {router_ics_skf_worker, handle_cast, _Args1}, _Return1}
    ] = meck:history(router_ics_skf_worker),

    %% Expected updates
    %% 1 Add
    %% 1 Remove {EvictedKey, EvictedDevaddr}
    %% 25 Remove {EvictedKey, RemainingDevaddr}
    %% 25 Remove {RemainingKey, EvictedDevaddr}
    ?assertEqual(1 + 1 + 25 + 25, length(Updates)),

    ok = meck:unload(router_ics_skf_worker),
    ok.

replay_joins_test(Config) ->
    #{
        app_key := AppKey,
        dev_nonce := DevNonce1,
        hotspot_name := HotspotName,
        stream := Stream,
        pubkey_bin := PubKeyBin
    } = test_utils:join_device(Config),

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
    {ok, #{<<"id">> := UplinkUUID1}} = test_utils:wait_for_console_event_sub(
        <<"uplink_unconfirmed">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"dc">> => #{<<"balance">> => 98, <<"nonce">> => 1, <<"used">> => 1},
                <<"fcnt">> => fun erlang:is_integer/1,
                <<"payload_size">> => fun erlang:is_integer/1,
                <<"payload">> => fun erlang:is_binary/1,
                <<"raw_packet">> => fun erlang:is_binary/1,
                <<"port">> => fun erlang:is_integer/1,
                <<"devaddr">> => fun erlang:is_binary/1,
                <<"hotspot">> => #{
                    <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                    <<"name">> => erlang:list_to_binary(HotspotName),
                    <<"rssi">> => 0.0,
                    <<"snr">> => 0.0,
                    <<"spreading">> => <<"SF8BW125">>,
                    <<"frequency">> => fun erlang:is_float/1,
                    <<"channel">> => fun erlang:is_number/1,
                    <<"lat">> => fun erlang:is_float/1,
                    <<"long">> => fun erlang:is_float/1
                },
                <<"mac">> => [],
                <<"hold_time">> => fun erlang:is_integer/1
            }
        }
    ),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_req">>, #{
        <<"id">> => UplinkUUID1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_req">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Request sent to ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"method">> => <<"POST">>,
                <<"url">> => <<?CONSOLE_URL/binary, "/channel">>,
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1,
                <<"url_params">> => fun test_utils:is_jsx_encoded_map/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{
                <<"body">> => <<"success">>,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => 200
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
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
    ?assertEqual(
        router_device:devaddr(Device0),
        router_device:devaddr(Device1)
    ),

    %% We ignore the channel correction and down messages
    ok = test_utils:ignore_messages(),

    %% This will act as an old valid nonce cause we have the right app key
    DevNonce2 = crypto:strong_rand_bytes(2),
    %% we are sending another join with an already used nonce to try to DOS the device
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce2)},
    timer:sleep(router_utils:join_timeout() + 1000),

    %% We are now making sure that we maintain multiple keys and nonce in
    %% device just in case last join was valid
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
        router_device:devaddr(Device0),
        router_device:devaddr(Device2)
    ),

    %% We repeat again to add a second "bad" attempt

    %% This will act as an old valid nonce cause we have the right app key
    DevNonce3 = crypto:strong_rand_bytes(2),
    %% we are sending another join with an already used nonce to try to DOS the device
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce3)},
    timer:sleep(router_utils:join_timeout() + 1000),

    %% We are not making sure that we maintain multiple keys and
    %% nonce in device just in case last join was valid
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
    {ok, #{<<"id">> := UplinkUUID2}} = test_utils:wait_for_console_event_sub(
        <<"uplink_unconfirmed">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"dc">> => #{<<"balance">> => 95, <<"nonce">> => 1, <<"used">> => 1},
                <<"fcnt">> => fun erlang:is_integer/1,
                <<"payload_size">> => fun erlang:is_integer/1,
                <<"payload">> => fun erlang:is_binary/1,
                <<"raw_packet">> => fun erlang:is_binary/1,
                <<"port">> => fun erlang:is_integer/1,
                <<"devaddr">> => fun erlang:is_binary/1,
                <<"hotspot">> => #{
                    <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                    <<"name">> => erlang:list_to_binary(HotspotName),
                    <<"rssi">> => 0.0,
                    <<"snr">> => 0.0,
                    <<"spreading">> => <<"SF8BW125">>,
                    <<"frequency">> => fun erlang:is_float/1,
                    <<"channel">> => fun erlang:is_number/1,
                    <<"lat">> => fun erlang:is_float/1,
                    <<"long">> => fun erlang:is_float/1
                },
                <<"mac">> => [],
                <<"hold_time">> => fun erlang:is_integer/1
            }
        }
    ),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_req">>, #{
        <<"id">> => UplinkUUID2,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_req">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Request sent to ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"method">> => <<"POST">>,
                <<"url">> => <<?CONSOLE_URL/binary, "/channel">>,
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1,
                <<"url_params">> => fun test_utils:is_jsx_encoded_map/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID2,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{
                <<"body">> => <<"success">>,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => 200
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
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

    ok.

ddos_joins_test(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),
    _ = test_utils:add_oui(Config),

    #{
        app_key := AppKey,
        dev_nonce := DevNonce1,
        stream := Stream,
        pubkey_bin := PubKeyBin
    } = test_utils:join_device(Config),

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
                0,
                #{devaddr => router_device:devaddr(Device0)}
            )},

    %% Waiting for report channel status
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => fun erlang:is_map/1,
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => fun erlang:is_list/1,
        <<"dc">> => fun erlang:is_map/1
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
    ?assertEqual(
        router_device:devaddr(Device0),
        router_device:devaddr(Device1)
    ),

    %% We ignore the channel correction and down messages
    ok = test_utils:ignore_messages(),

    %% Sending 2 joins where one  of them is the right one and the other one
    %% (DevNonce3) coming right after should act as the attacker.
    DevNonce2 = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce2)},

    timer:sleep(10),
    DevNonce3 = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce3)},

    timer:sleep(router_utils:join_timeout() + 1000),

    %% We are now making sure that we maintain multiple keys and nonce in
    %% device just in case last join was valid
    {ok, Device2} = router_device_cache:get(DeviceID),
    ?assertEqual(
        [DevNonce1],
        router_device:dev_nonces(Device2)
    ),
    ?assertEqual(
        3,
        erlang:length(router_device:devaddrs(Device2))
    ),
    ?assertEqual(
        3,
        erlang:length(router_device:keys(Device2))
    ),

    [_, GoodDevAddr, _] = router_device:devaddrs(Device2),
    [_, {GoodNwkSKey, GoodAppSKey}, _] = router_device:keys(Device2),
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                GoodNwkSKey,
                GoodAppSKey,
                0,
                #{devaddr => GoodDevAddr}
            )},

    %% Waiting for report channel status
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => fun erlang:is_map/1,
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => fun erlang:is_list/1,
        <<"dc">> => fun erlang:is_map/1
    }),

    {ok, Device3} = router_device_cache:get(DeviceID),
    ?assertEqual(
        1,
        erlang:length(router_device:devaddrs(Device3))
    ),
    ?assertEqual([GoodDevAddr], router_device:devaddrs(Device3)),
    ?assertEqual(
        1,
        erlang:length(router_device:keys(Device3))
    ),
    ?assertEqual([{GoodNwkSKey, GoodAppSKey}], router_device:keys(Device3)),

    ok.

replay_uplink_test(Config) ->
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    Stream !
        {send,
            test_utils:frame_packet(
                ?CONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0
            )},

    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> =>
            <<?CONSOLE_URL/binary, "/api/v1/down/", ?CONSOLE_HTTP_CHANNEL_ID/binary, "/",
                ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN/binary, "/", ?CONSOLE_DEVICE_ID/binary>>,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => fun erlang:is_integer/1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0,
            <<"preferred_hotspots">> => fun erlang:is_list/1
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
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
        <<"dc">> => #{
            <<"balance">> => fun erlang:is_integer/1,
            <<"nonce">> => fun erlang:is_integer/1
        }
    }),

    timer:sleep(2000 + 100),

    Stream !
        {send,
            test_utils:frame_packet(
                ?CONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0
            )},

    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => true,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> =>
            <<?CONSOLE_URL/binary, "/api/v1/down/", ?CONSOLE_HTTP_CHANNEL_ID/binary, "/",
                ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN/binary, "/", ?CONSOLE_DEVICE_ID/binary>>,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => fun erlang:is_integer/1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0,
            <<"preferred_hotspots">> => fun erlang:is_list/1
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
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
        <<"dc">> => #{
            <<"balance">> => fun erlang:is_integer/1,
            <<"nonce">> => fun erlang:is_integer/1
        }
    }),

    ok.

offer_cache_test(Config) ->
    #{
        pubkey_bin := PubKeyBin1
    } = test_utils:join_device(Config),

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, Device0} = router_device_cache:get(DeviceID),

    %% First, we need the device's FCnt to be 0.
    SCPacket0 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin1,
        router_device:nwk_s_key(Device0),
        router_device:app_s_key(Device0),
        0,
        #{
            dont_encode => true,
            routing => true
        }
    ),
    ?assertEqual(
        ok, router_device_routing:handle_packet(SCPacket0, erlang:system_time(millisecond), self())
    ),

    %% Now we can test...

    %% Testing with 2 offers / packets
    SCPacket1 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin1,
        router_device:nwk_s_key(Device0),
        router_device:app_s_key(Device0),
        1,
        #{
            dont_encode => true,
            routing => true
        }
    ),
    SCPacket2 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin2,
        router_device:nwk_s_key(Device0),
        router_device:app_s_key(Device0),
        1,
        #{
            dont_encode => true,
            routing => true
        }
    ),
    Offer1 = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket1),
        blockchain_state_channel_packet_v1:hotspot(SCPacket1),
        blockchain_state_channel_packet_v1:region(SCPacket1)
    ),
    Offer2 = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket2),
        blockchain_state_channel_packet_v1:hotspot(SCPacket2),
        blockchain_state_channel_packet_v1:region(SCPacket2)
    ),

    {ok, DeviceWorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    router_device_worker:handle_offer(DeviceWorkerPid, Offer1),
    router_device_worker:handle_offer(DeviceWorkerPid, Offer2),

    OfferCache1 = test_utils:get_device_worker_offer_cache(DeviceID),
    ?assert(
        maps:is_key(
            {PubKeyBin1, blockchain_state_channel_offer_v1:packet_hash(Offer1)},
            OfferCache1
        )
    ),
    ?assert(
        maps:is_key(
            {PubKeyBin2, blockchain_state_channel_offer_v1:packet_hash(Offer2)},
            OfferCache1
        )
    ),
    ?assert(
        router_device_worker:accept_uplink(
            DeviceWorkerPid,
            1,
            blockchain_state_channel_packet_v1:packet(SCPacket1),
            1,
            2,
            PubKeyBin1
        )
    ),
    ?assert(
        router_device_worker:accept_uplink(
            DeviceWorkerPid,
            1,
            blockchain_state_channel_packet_v1:packet(SCPacket2),
            1,
            2,
            PubKeyBin2
        )
    ),

    %% Now testing with a late packet (SCPacket4) we set fcnt to 0
    SCPacket3 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin1,
        router_device:nwk_s_key(Device0),
        router_device:app_s_key(Device0),
        0,
        #{
            dont_encode => true,
            routing => true
        }
    ),
    ?assert(
        router_device_worker:accept_uplink(
            DeviceWorkerPid,
            0,
            blockchain_state_channel_packet_v1:packet(SCPacket3),
            1,
            2,
            PubKeyBin1
        )
    ),

    SCPacket4 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin1,
        router_device:nwk_s_key(Device0),
        router_device:app_s_key(Device0),
        0,
        #{
            dont_encode => true,
            routing => true
        }
    ),
    Offer4 = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket4),
        blockchain_state_channel_packet_v1:hotspot(SCPacket4),
        blockchain_state_channel_packet_v1:region(SCPacket4)
    ),
    router_device_worker:handle_offer(DeviceWorkerPid, Offer4),
    timer:sleep(4000),

    ?assertNot(
        router_device_worker:accept_uplink(
            DeviceWorkerPid,
            0,
            blockchain_state_channel_packet_v1:packet(SCPacket4),
            1,
            2,
            PubKeyBin1
        )
    ),

    test_utils:wait_for_console_event_sub(<<"uplink_dropped_late">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink_dropped">>,
        <<"sub_category">> => <<"uplink_dropped_late">>,
        <<"description">> => <<"Late packet">>,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 0,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(blockchain_utils:addr2name(PubKeyBin1))
            },
            <<"hold_time">> => fun erlang:is_integer/1
        }
    }),

    %% Now testing with a late packet (SCPacket5) we set fcnt to 1 > current device fcnt
    SCPacket5 = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin1,
        router_device:nwk_s_key(Device0),
        router_device:app_s_key(Device0),
        1,
        #{
            dont_encode => true,
            routing => true
        }
    ),
    Offer5 = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket5),
        blockchain_state_channel_packet_v1:hotspot(SCPacket5),
        blockchain_state_channel_packet_v1:region(SCPacket5)
    ),
    router_device_worker:handle_offer(DeviceWorkerPid, Offer5),
    timer:sleep(4000),

    ?assert(
        router_device_worker:accept_uplink(
            DeviceWorkerPid,
            1,
            blockchain_state_channel_packet_v1:packet(SCPacket5),
            1,
            2,
            PubKeyBin1
        )
    ),

    ok.

load_offer_cache_test(Config) ->
    ok = application:set_env(router, offer_cache_timeout, timer:seconds(5)),
    _ = test_utils:join_device(Config),

    test_utils:wait_state_channel_message(1250),
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, Device0} = router_device_cache:get(DeviceID),
    {ok, DeviceWorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),

    Offers = lists:foldl(
        fun(_I, Acc) ->
            #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
            PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

            SCPacket = test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                1,
                #{
                    dont_encode => true,
                    routing => true
                }
            ),
            Offer = blockchain_state_channel_offer_v1:from_packet(
                blockchain_state_channel_packet_v1:packet(SCPacket),
                blockchain_state_channel_packet_v1:hotspot(SCPacket),
                blockchain_state_channel_packet_v1:region(SCPacket)
            ),
            router_device_worker:handle_offer(DeviceWorkerPid, Offer),
            maps:put(PubKeyBin, Offer, Acc)
        end,
        #{},
        lists:seq(1, 100)
    ),

    OfferCache1 = test_utils:get_device_worker_offer_cache(DeviceID),

    ?assertEqual(100, maps:size(OfferCache1)),

    lists:foreach(
        fun({PubKeyBin, Offer}) ->
            ?assert(
                maps:is_key(
                    {PubKeyBin, blockchain_state_channel_offer_v1:packet_hash(Offer)},
                    OfferCache1
                )
            )
        end,
        maps:to_list(Offers)
    ),

    timer:sleep(timer:seconds(5)),

    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    SCPacket = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin,
        router_device:nwk_s_key(Device0),
        router_device:app_s_key(Device0),
        1,
        #{
            dont_encode => true,
            routing => true
        }
    ),
    Offer = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket),
        blockchain_state_channel_packet_v1:hotspot(SCPacket),
        blockchain_state_channel_packet_v1:region(SCPacket)
    ),
    router_device_worker:handle_offer(DeviceWorkerPid, Offer),

    OfferCache2 = test_utils:get_device_worker_offer_cache(DeviceID),

    ?assertEqual(1, maps:size(OfferCache2)),
    ok.

hotspot_bad_region_test(Config) ->
    %% JOINING IN EU REGION
    EURegion = 'EU868',
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream
    } = test_utils:join_device(Config, #{region => EURegion}),
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(?CONSOLE_DEVICE_ID),

    %% Check that device is in cache now
    {ok, Device0} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    ?assertEqual(EURegion, router_device:region(Device0)),

    %% THis is an EU868 Datarate
    DataRate = <<"SF12BW125">>,
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{datarate => DataRate, region => 'US915'}
            )},

    timer:sleep(router_utils:frame_timeout()),
    ?assertEqual(true, erlang:is_process_alive(WorkerPid)),

    {ok, Device1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    ?assertEqual(EURegion, router_device:region(Device1)),
    ok.

uplink_bad_mtype(Config) ->
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, Device} = router_device_cache:get(?CONSOLE_DEVICE_ID),

    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_DOWN,
                PubKeyBin,
                router_device:nwk_s_key(Device),
                router_device:app_s_key(Device),
                1
            )},
    ok = rcv_loop(),
    ok.
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

rcv_loop() ->
    receive
        {websocket_init, _} ->
            rcv_loop()
    after 1000 ->
        ok
    end.
