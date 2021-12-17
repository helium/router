-module(router_channel_mqtt_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([mqtt_test/1, mqtt_update_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").

-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).
-define(MQTT_TIMEOUT, timer:seconds(2)).

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
    [mqtt_test, mqtt_update_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    ok = file:write_file("acl.conf", <<"{allow, all}.">>),
    application:set_env(emqx, acl_file, "acl.conf"),
    application:set_env(emqx, allow_anonymous, true),
    application:set_env(emqx, listeners, [{tcp, 1883, []}]),
    {ok, _} = application:ensure_all_started(emqx),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    application:stop(emqx),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

mqtt_test(Config) ->
    %% Set console to MQTT channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, mqtt}),

    %% Connect and subscribe to MQTT Server
    MQTTChannel = ?CONSOLE_MQTT_CHANNEL,
    {ok, MQTTConn} = connect(
        kvc:path([<<"credentials">>, <<"endpoint">>], MQTTChannel),
        <<"mqtt_test">>,
        undefined
    ),
    UplinkTemplate = kvc:path([<<"credentials">>, <<"uplink">>, <<"topic">>], MQTTChannel),
    DownlinkTemplate = kvc:path([<<"credentials">>, <<"downlink">>, <<"topic">>], MQTTChannel),
    DeviceUpdates = [
        {dev_eui, ?DEVEUI},
        {app_eui, ?APPEUI},
        {metadata, #{organization_id => ?CONSOLE_ORG_ID}}
    ],
    DeviceForTemplate = router_device:update(DeviceUpdates, router_device:new(?CONSOLE_DEVICE_ID)),
    UplinkTopic = render_topic(UplinkTemplate, DeviceForTemplate),
    DownlinkTopic = render_topic(DownlinkTemplate, DeviceForTemplate),
    {ok, _, _} = emqtt:subscribe(MQTTConn, UplinkTopic, 0),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send UNCONFIRMED_UP frame packet
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0
            )},

    %% We should receive the channel data via the MQTT server here
    receive
        {publish, #{payload := Payload0}} ->
            self() ! {channel_data, jsx:decode(Payload0, [return_maps])}
    after ?MQTT_TIMEOUT -> ct:fail("Payload0 timeout")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        %% Not all metadata is populated here:
        <<"metadata">> => fun erlang:is_map/1,
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
        ]
    }),

    %% Waiting for report channel status from MQTT channel
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
            io_lib:format("Request sent to ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"endpoint">> => fun erlang:is_binary/1,
                <<"topic">> => fun erlang:is_binary/1,
                <<"qos">> => 0,
                <<"body">> => fun erlang:is_binary/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{},
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% We ignore the channel correction messages
    ok = test_utils:ignore_messages(),

    %% Publish a downlink packet via MQTT server
    DownlinkPayload = <<"mqttpayload">>,
    emqtt:publish(
        MQTTConn,
        DownlinkTopic,
        jsx:encode(#{<<"payload_raw">> => base64:encode(DownlinkPayload)}),
        0
    ),

    %% Send UNCONFIRMED_UP frame packet
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                1
            )},

    %% We should receive the channel data via the MQTT server here
    receive
        {publish, #{payload := Payload1}} ->
            self() ! {channel_data, jsx:decode(Payload1, [return_maps])}
    after ?MQTT_TIMEOUT -> ct:fail("Payload1 timeout")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_timing_ans_device_ack">> => false,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 1,
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
        ]
    }),

    %% Waiting for report channel status from MQTT channel
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
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => 27,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW500">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            },
            <<"integration">> => #{
                <<"id">> => <<"56789">>,
                <<"name">> => <<"fake_mqtt">>,
                <<"status">> => <<"success">>
            },
            <<"mac">> => fun erlang:is_list/1
        }
    }),

    %% Waiting for report channel status from MQTT channel
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
                <<"dc">> => #{<<"balance">> => 97, <<"nonce">> => 1, <<"used">> => 1},
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
            io_lib:format("Request sent to ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"endpoint">> => fun erlang:is_binary/1,
                <<"topic">> => fun erlang:is_binary/1,
                <<"qos">> => 0,
                <<"body">> => fun erlang:is_binary/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID2,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{},
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% Waiting for donwlink message on the hotspot
    Msg0 = {false, 1, DownlinkPayload},
    {ok, _} = test_utils:wait_state_channel_message(
        Msg0,
        Device0,
        erlang:element(3, Msg0),
        ?UNCONFIRMED_DOWN,
        0,
        0,
        1,
        1
    ),

    %% We ignore the report status down
    ok = test_utils:ignore_messages(),

    ok = emqtt:disconnect(MQTTConn),
    ok.

mqtt_update_test(Config) ->
    %% Set console to MQTT channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, mqtt}),

    %% Connect and subscribe to MQTT Server
    MQTTChannel = ?CONSOLE_MQTT_CHANNEL,
    {ok, MQTTConn} = connect(
        kvc:path([<<"credentials">>, <<"endpoint">>], MQTTChannel),
        <<"mqtt_test">>,
        undefined
    ),
    UplinkTemplate = kvc:path([<<"credentials">>, <<"uplink">>, <<"topic">>], MQTTChannel),
    DeviceUpdates = [
        {dev_eui, ?DEVEUI},
        {app_eui, ?APPEUI},
        {metadata, #{organization_id => ?CONSOLE_ORG_ID}}
    ],
    DeviceForTemplate = router_device:update(DeviceUpdates, router_device:new(?CONSOLE_DEVICE_ID)),
    UplinkTopic = render_topic(UplinkTemplate, DeviceForTemplate),
    {ok, _, _} = emqtt:subscribe(MQTTConn, UplinkTopic, 0),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send UNCONFIRMED_UP frame packet
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0
            )},

    %% We should receive the channel data via the MQTT server here
    receive
        {publish, #{payload := Payload0, topic := UplinkTopic}} ->
            self() ! {channel_data, jsx:decode(Payload0, [return_maps])}
    after ?MQTT_TIMEOUT -> ct:fail("timeout Payload0")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        %% Not all metadata is populated here, but see next "metadata" below.
        <<"metadata">> => fun erlang:is_map/1,
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
        ]
    }),

    %% Waiting for report channel status from MQTT channel
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
            io_lib:format("Request sent to ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"endpoint">> => fun erlang:is_binary/1,
                <<"topic">> => fun erlang:is_binary/1,
                <<"qos">> => 0,
                <<"body">> => fun erlang:is_binary/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{},
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% We ignore the channel correction messages
    ok = test_utils:ignore_messages(),

    %% Switching topic channel should update but no restart
    Tab = proplists:get_value(ets, Config),

    UplinkTemplate1 = <<"uplink/{{app_eui}}/{{device_eui}}">>,
    UplinkTopic1 = render_topic(UplinkTemplate1, DeviceForTemplate),
    MQTTChannel0 = #{
        <<"type">> => <<"mqtt">>,
        <<"credentials">> => #{
            <<"endpoint">> => <<"mqtt://127.0.0.1:1883">>,
            <<"uplink">> => #{<<"topic">> => UplinkTemplate1},
            <<"downlink">> => #{<<"topic">> => <<"downlink/{{org_id}}/{{device_id}}">>}
        },
        <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
        <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME
    },
    ets:insert(Tab, {channels, [MQTTChannel0]}),
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(WorkerID, #{}),
    {ok, _, _} = emqtt:unsubscribe(MQTTConn, UplinkTopic),
    {ok, _, _} = emqtt:subscribe(MQTTConn, UplinkTopic1, 0),

    %% Force device_worker refresh channels
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),

    %% Send UNCONFIRMED_UP frame packet
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                1
            )},

    %% We should receive the channel data via the MQTT server here with NEW SUB TOPIC (SubTopic1)
    receive
        {publish, #{payload := Payload1, topic := UplinkTopic1}} ->
            self() ! {channel_data, jsx:decode(Payload1, [return_maps])}
    after ?MQTT_TIMEOUT -> ct:fail("timeout Payload1")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_timing_ans_device_ack">> => false,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 1,
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
        ]
    }),

    %% Waiting for report channel status from MQTT channel
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
                <<"dc">> => #{<<"balance">> => 97, <<"nonce">> => 1, <<"used">> => 1},
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
            io_lib:format("Request sent to ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"endpoint">> => fun erlang:is_binary/1,
                <<"topic">> => fun erlang:is_binary/1,
                <<"qos">> => 0,
                <<"body">> => fun erlang:is_binary/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID2,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{},
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% Ignore down messages updates
    ok = test_utils:ignore_messages(),

    %% Switching endpoint channel should restart (back to sub topic 0)
    MQTTChannel1 = #{
        <<"type">> => <<"mqtt">>,
        <<"credentials">> => #{
            <<"endpoint">> => <<"mqtt://localhost:1883">>,
            <<"uplink">> => #{<<"topic">> => <<"uplink/{{org_id}}/{{device_id}}">>},
            <<"downlink">> => #{<<"topic">> => <<"downlink/{{org_id}}/{{device_id}}">>}
        },
        <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
        <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME
    },
    ets:insert(Tab, {channels, [MQTTChannel1]}),
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(WorkerID, #{}),
    {ok, _, _} = emqtt:unsubscribe(MQTTConn, UplinkTopic1),
    {ok, _, _} = emqtt:subscribe(MQTTConn, UplinkTopic, 0),

    %% Force device_worker refresh channels
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),

    %% Send UNCONFIRMED_UP frame packet
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                2
            )},

    %% We should receive the channel data via the MQTT server here with OLD SUB TOPIC (SubTopic0)
    receive
        {publish, #{payload := Payload2, topic := UplinkTopic}} ->
            self() ! {channel_data, jsx:decode(Payload2, [return_maps])}
    after ?MQTT_TIMEOUT -> ct:fail("timeout Payload2")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_timing_ans_device_ack">> => false,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 2,
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
        ]
    }),

    %% Waiting for report channel status from MQTT channel
    {ok, #{<<"id">> := UplinkUUID3}} = test_utils:wait_for_console_event_sub(
        <<"uplink_unconfirmed">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"dc">> => #{<<"balance">> => 96, <<"nonce">> => 1, <<"used">> => 1},
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
        <<"id">> => UplinkUUID3,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_req">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Request sent to ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"endpoint">> => fun erlang:is_binary/1,
                <<"topic">> => fun erlang:is_binary/1,
                <<"qos">> => 0,
                <<"body">> => fun erlang:is_binary/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID3,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_MQTT_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{},
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% Ignore down messages updates
    ok = test_utils:ignore_messages(),

    ok = emqtt:disconnect(MQTTConn),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec render_topic(binary(), router_device:device()) -> binary().
render_topic(Template, Device) ->
    Metadata = router_device:metadata(Device),
    Map = #{
        "device_id" => router_device:id(Device),
        "device_eui" => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
        "app_eui" => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
        "organization_id" => maps:get(organization_id, Metadata, <<>>)
    },
    bbmustache:render(Template, Map).

-spec connect(binary(), binary(), any()) -> {ok, pid()} | {error, term()}.
connect(URI, DeviceID, Name) ->
    Opts = [
        {scheme_defaults, [{mqtt, 1883}, {mqtts, 8883} | http_uri:scheme_defaults()]},
        {fragment, false}
    ],
    case http_uri:parse(URI, Opts) of
        {ok, {Scheme, UserInfo, Host, Port, _Path, _Query}} when
            Scheme == mqtt orelse
                Scheme == mqtts
        ->
            {Username, Password} =
                case binary:split(UserInfo, <<":">>) of
                    [Un, <<>>] -> {Un, undefined};
                    [Un, Pw] -> {Un, Pw};
                    [<<>>] -> {undefined, undefined};
                    [Un] -> {Un, undefined}
                end,
            EmqttOpts =
                [
                    {host, erlang:binary_to_list(Host)},
                    {port, Port},
                    {clientid, DeviceID}
                ] ++
                    [{username, Username} || Username /= undefined] ++
                    [{password, Password} || Password /= undefined] ++
                    [
                        {clean_start, false},
                        {keepalive, 30},
                        {ssl, Scheme == mqtts}
                    ],
            {ok, C} = emqtt:start_link(EmqttOpts),
            case emqtt:connect(C) of
                {ok, _Props} ->
                    lager:info("connect returned ~p", [_Props]),
                    {ok, C};
                {error, Reason} ->
                    lager:info("Failed to connect to ~p ~p : ~p", [
                        Host,
                        Port,
                        Reason
                    ]),
                    {error, Reason}
            end;
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s ~p", [URI, Name]),
            {error, invalid_mqtt_uri}
    end.
