-module(router_channel_azure_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    azure_test/1
]).

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
    [
        azure_test
    ].

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

azure_test(Config) ->
    meck:new(router_azure_connection, [passthrough]),
    meck:expect(router_azure_connection, fetch_device, fun(_) ->
        {ok, device_map_would_go_here}
    end),
    meck:expect(router_azure_connection, connection_information, fun(_HubName, DeviceID) ->
        %% This allows us ot skip over the crazy nonsense that is contructing
        %% msft's credentials.
        #{
            http_sas_uri => <<"unused">>,
            http_url => <<"unused">>,
            mqtt_sas_uri => <<"unused">>,
            mqtt_host => <<"127.0.0.1">>,
            mqtt_port => 1883,
            mqtt_username => DeviceID
        }
    end),

    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, azure}),

    {ok, Conn} = connect(<<"mqtt://127.0.0.1:1883">>, <<"azure-test">>, undefined),

    DownlinkPayload = <<"azure_mqtt_payload">>,
    SendDownlink = fun() ->
        emqtt:publish(
            Conn,
            <<"devices/yolo_id/messages/devicebound">>,
            jsx:encode(#{<<"payload_raw">> => base64:encode(DownlinkPayload)}),
            0
        ),
        ok
    end,

    %% Subscribe to events published by azure channel
    UplinkTopic = <<"devices/yolo_id/messages/events/#">>,
    {ok, _, _} = emqtt:subscribe(Conn, UplinkTopic, 0),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
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
    after ?MQTT_TIMEOUT -> ct:fail("payload timeout")
    end,

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
            <<"rx_delay">> => 0
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
            io_lib:format("Request sent to ~p", [?CONSOLE_AZURE_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"qos">> => 0,
                <<"body">> => fun erlang:is_binary/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_AZURE_CHANNEL_ID,
                <<"name">> => ?CONSOLE_AZURE_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_AZURE_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{},
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_AZURE_CHANNEL_ID,
                <<"name">> => ?CONSOLE_AZURE_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% We ignore the channel correction messages
    ok = test_utils:ignore_messages(),

    %% Publish a downlink packet via MQTT server
    ok = SendDownlink(),

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
                <<"id">> => ?CONSOLE_AZURE_CHANNEL_ID,
                <<"name">> => ?CONSOLE_AZURE_CHANNEL_NAME,
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
            io_lib:format("Request sent to ~p", [?CONSOLE_AZURE_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"qos">> => 0,
                <<"body">> => fun erlang:is_binary/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_AZURE_CHANNEL_ID,
                <<"name">> => ?CONSOLE_AZURE_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => UplinkUUID2,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_AZURE_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{},
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_AZURE_CHANNEL_ID,
                <<"name">> => ?CONSOLE_AZURE_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% Waiting for donwlink message on the hotspot
    Msg0 = {false, 1, <<"azure_mqtt_payload">>},
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

    ok = emqtt:disconnect(Conn),
    meck:unload(router_azure_connection),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

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
