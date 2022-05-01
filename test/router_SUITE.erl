-module(router_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    mac_commands_test/1,
    mac_command_link_check_req_test/1,
    dupes_test/1,
    dupes2_test/1,
    join_test/1,
    us915_join_enabled_cf_list_test/1,
    us915_join_disabled_cf_list_test/1,
    us915_link_adr_req_timing_test/1,
    adr_test/1,
    adr_downlink_timing_test/1,
    rx_delay_join_test/1,
    rx_delay_downlink_default_test/1,
    rx_delay_change_ignored_by_device_downlink_test/1,
    rx_delay_accepted_by_device_downlink_test/1,
    rx_delay_continue_session_test/1,
    rx_delay_change_during_session_test/1
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
-define(ETS, ?MODULE).

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
        mac_commands_test,
        mac_command_link_check_req_test,
        % dupes_test,
        % join_test,
        us915_join_enabled_cf_list_test,
        us915_join_disabled_cf_list_test,
        % us915_link_adr_req_timing_test,
        % adr_test,
        % adr_downlink_timing_test,
        % rx_delay_join_test,
        rx_delay_downlink_default_test,
        rx_delay_change_ignored_by_device_downlink_test,
        rx_delay_accepted_by_device_downlink_test,
        rx_delay_continue_session_test,
        rx_delay_change_during_session_test
    ].

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

mac_command_link_check_req_test(Config) ->
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
                0,
                #{
                    fopts => [link_check_req]
                }
            )},

    %% Waiting for report channel status from HTTP channel
    {ok, _} = test_utils:wait_for_console_event(<<"uplink">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_unconfirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => fun erlang:is_map/1,
            <<"fcnt">> => 0,
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
            <<"mac">> => [#{<<"command">> => <<"link_check_req">>}],
            <<"hold_time">> => fun erlang:is_integer/1
        }
    }),

    {ok, _} = test_utils:wait_for_console_event(<<"downlink">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_unconfirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"data">> =>
            #{
                <<"devaddr">> => fun erlang:is_binary/1,
                <<"fcnt">> => 0,
                <<"hotspot">> => fun erlang:is_map/1,
                <<"integration">> => fun erlang:is_map/1,
                <<"mac">> =>
                    [
                        #{
                            <<"command">> => <<"link_check_ans">>,
                            <<"gateway_count">> => 1,
                            <<"margin">> => 10
                        },
                        %% These come as part of the first downlink
                        #{
                            <<"channel_mask">> => fun erlang:is_integer/1,
                            <<"channel_mask_control">> => fun erlang:is_integer/1,
                            <<"command">> => <<"link_adr_req">>,
                            <<"data_rate">> => fun erlang:is_integer/1,
                            <<"number_of_transmissions">> => fun erlang:is_integer/1,
                            <<"tx_power">> => fun erlang:is_integer/1
                        },
                        #{
                            <<"channel_mask">> => fun erlang:is_integer/1,
                            <<"channel_mask_control">> => fun erlang:is_integer/1,
                            <<"command">> => <<"link_adr_req">>,
                            <<"data_rate">> => fun erlang:is_integer/1,
                            <<"number_of_transmissions">> => fun erlang:is_integer/1,
                            <<"tx_power">> => fun erlang:is_integer/1
                        }
                    ],
                <<"payload">> => fun erlang:is_binary/1,
                <<"payload_size">> => fun erlang:is_integer/1,
                <<"port">> => 0
            }
    }),

    %% Ignore down messages updates
    ok = test_utils:ignore_messages(),

    ok.

mac_commands_test(Config) ->
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

    Fopts = [
        link_check_req,
        {link_adr_ans, 1, 1, 1},
        duty_cycle_ans,
        {rx_param_setup_ans, 1, 1, 1},
        {dev_status_ans, 100, -1},
        {new_channel_ans, 1, 1},
        rx_timing_setup_ans,
        tx_param_setup_ans,
        {di_channel_ans, 1, 1},
        device_time_req
    ],

    lists:foreach(
        fun({Index, Fopt}) ->
            %% Send UNCONFIRMED_UP frame packet
            Stream !
                {send,
                    test_utils:frame_packet(
                        ?UNCONFIRMED_UP,
                        PubKeyBin,
                        router_device:nwk_s_key(Device0),
                        router_device:app_s_key(Device0),
                        Index,
                        #{
                            fopts => [Fopt]
                        }
                    )},

            ExpectedFopts = parse_fopts([lists:nth(Index, Fopts)]),

            %% Waiting for report channel status from HTTP channel
            {ok, _} = test_utils:wait_for_console_event(<<"uplink">>, #{
                <<"id">> => fun erlang:is_binary/1,
                <<"category">> => <<"uplink">>,
                <<"sub_category">> => <<"uplink_unconfirmed">>,
                <<"description">> => fun erlang:is_binary/1,
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"device_id">> => ?CONSOLE_DEVICE_ID,
                <<"data">> => #{
                    <<"dc">> => fun erlang:is_map/1,
                    <<"fcnt">> => Index,
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
                    <<"mac">> => ExpectedFopts,
                    <<"hold_time">> => fun erlang:is_integer/1
                }
            })
        end,
        lists:zip(lists:seq(1, length(Fopts)), Fopts)
    ),

    %% Ignore down messages updates
    ok = test_utils:ignore_messages(),

    ok.

dupes_test(Config) ->
    #{
        pubkey_bin := PubKeyBin1,
        stream := Stream,
        hotspot_name := HotspotName1
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Channel = router_channel:new(
        <<"fake">>,
        websocket,
        <<"fake">>,
        #{},
        0,
        self()
    ),
    Msg0 = #downlink{confirmed = false, port = 1, payload = <<"somepayload">>, channel = Channel},
    router_device_worker:queue_downlink(WorkerPid, Msg0),

    %% Send 4 similar packets to make it look like it's coming from 2 diff hotspots
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin1,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{rssi => -50.0}
            )},
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin1,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{rssi => -25.0}
            )},
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey),
    {ok, HotspotName2} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin2)),
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin2,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{rssi => -30.0}
            )},
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin2,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{rssi => -60.0}
            )},

    %% Waiting for data from HTTP channel with 2 hotspots
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
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
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName1),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => -25.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            },
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin2)),
                <<"name">> => erlang:list_to_binary(HotspotName2),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => -30.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => <<"unknown">>,
                <<"long">> => <<"unknown">>
            }
        ],
        <<"dc">> => #{
            <<"balance">> => fun erlang:is_integer/1,
            <<"nonce">> => fun erlang:is_integer/1
        }
    }),

    %% Waiting for report channel status from HTTP channel
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
            <<"port">> => Msg0#downlink.port,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName1),
                <<"rssi">> => 27,
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
            <<"mac">> => fun erlang:is_list/1
        }
    }),

    %% NOTE: Order of the packets in the mailbox is finicky. And the hotspots are
    %% different enough that the can cause matching problems for each other if
    %% we directly target either uplink first.
    IsFirstCouplePacketsFun = fun
        (Balance) when Balance == 98 orelse Balance == 97 -> true;
        (_) -> false
    end,

    HSID1 = erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
    HSID2 = erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin2)),
    HSName1 = erlang:list_to_binary(HotspotName1),
    HSName2 = erlang:list_to_binary(HotspotName2),

    HotspotBinIdFun = fun
        (Bin) when Bin == HSID1 orelse Bin == HSID2 -> true;
        (_) -> false
    end,

    HotspotBinNameFun = fun
        (Bin) when Bin == HSName1 orelse Bin == HSName2 -> true;
        (_) -> false
    end,

    IsFloatOrBinary = fun
        (Value) when is_float(Value) -> true;
        (Value) when is_binary(Value) -> true;
        (_) -> false
    end,

    %% Waiting for report channel status from HTTP channel
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
                <<"dc">> => #{
                    <<"balance">> => IsFirstCouplePacketsFun,
                    <<"nonce">> => 1,
                    <<"used">> => 1
                },
                <<"fcnt">> => fun erlang:is_integer/1,
                <<"payload_size">> => fun erlang:is_integer/1,
                <<"payload">> => fun erlang:is_binary/1,
                <<"raw_packet">> => fun erlang:is_binary/1,
                <<"port">> => fun erlang:is_integer/1,
                <<"devaddr">> => fun erlang:is_binary/1,
                <<"hotspot">> => #{
                    <<"id">> => HotspotBinIdFun,
                    <<"name">> => HotspotBinNameFun,
                    <<"rssi">> => fun erlang:is_float/1,
                    <<"snr">> => fun erlang:is_float/1,
                    <<"spreading">> => <<"SF8BW125">>,
                    <<"frequency">> => fun erlang:is_float/1,
                    <<"channel">> => fun erlang:is_number/1,
                    <<"lat">> => IsFloatOrBinary,
                    <<"long">> => IsFloatOrBinary
                },
                <<"mac">> => [],
                <<"hold_time">> => fun erlang:is_integer/1
            }
        }
    ),
    {ok, #{<<"id">> := _UplinkUUID2}} = test_utils:wait_for_console_event_sub(
        <<"uplink_unconfirmed">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                %% <<"dc">> => #{<<"balance">> => 97, <<"nonce">> => 1, <<"used">> => 1},
                <<"dc">> => fun erlang:is_map/1,
                <<"fcnt">> => fun erlang:is_integer/1,
                <<"payload_size">> => fun erlang:is_integer/1,
                <<"payload">> => fun erlang:is_binary/1,
                <<"raw_packet">> => fun erlang:is_binary/1,
                <<"port">> => fun erlang:is_integer/1,
                <<"devaddr">> => fun erlang:is_binary/1,
                <<"hotspot">> => #{
                    <<"id">> => HotspotBinIdFun,
                    %% <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin2)),
                    <<"name">> => HotspotBinNameFun,
                    <<"rssi">> => fun erlang:is_float/1,
                    <<"snr">> => fun erlang:is_float/1,
                    <<"spreading">> => <<"SF8BW125">>,
                    <<"frequency">> => fun erlang:is_float/1,
                    <<"channel">> => fun erlang:is_number/1,
                    <<"lat">> => IsFloatOrBinary,
                    <<"long">> => IsFloatOrBinary
                },
                <<"mac">> => [],
                <<"hold_time">> => fun erlang:is_integer/1
            }
        }
    ),
    %% ct:print("Waiting for uplink_integration_req for ~p", [UplinkUUID1]),
    %% ct:print("Or for uplink_integration_req for ~p", [_UplinkUUID2]),
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
                <<"method">> => fun erlang:is_binary/1,
                <<"url">> => fun erlang:is_binary/1,
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
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => fun erlang:is_integer/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    {ok, Reply1} = test_utils:wait_state_channel_message(
        Msg0,
        Device0,
        Msg0#downlink.payload,
        ?UNCONFIRMED_DOWN,
        0,
        0,
        1,
        0
    ),
    ct:pal("Reply ~p", [Reply1]),
    true = lists:keymember(link_adr_req, 1, Reply1#frame.fopts),

    %% Make sure we did not get a duplicate
    receive
        {client_data, _, _Data2} ->
            ct:fail("double_reply ~p", [
                blockchain_state_channel_v1_pb:decode_msg(
                    _Data2,
                    blockchain_state_channel_message_v1_pb
                )
            ])
    after 0 -> ok
    end,
    ok.

dupes2_test(Config) ->
    #{
        pubkey_bin := PubKeyBin1,
        stream := Stream,
        hotspot_name := HotspotName1
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send 4 similar packets to make it look like it's coming from 2 diff hotspots
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin1,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{rssi => -25.0}
            )},
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin1,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{rssi => -50.0}
            )},

    %% Waiting for data from HTTP channel with 2 hotspots
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
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
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName1),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => -25.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ]
    }),

    test_utils:wait_for_console_event_sub(
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
                <<"payload_size">> => 0,
                <<"payload">> => fun erlang:is_binary/1,
                <<"raw_packet">> => fun erlang:is_binary/1,
                <<"port">> => fun erlang:is_integer/1,
                <<"devaddr">> => fun erlang:is_binary/1,
                <<"hotspot">> => #{
                    <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                    <<"name">> => erlang:list_to_binary(HotspotName1),
                    <<"rssi">> => -25.0,
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

    receive
        {console_event, <<"uplink">>, <<"uplink_unconfirmed">>, Map} ->
            ct:pal("[~p:~p:~p] ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Map]),
            ct:fail(extra_uplink_unconfirmed)
    after 1000 -> ok
    end,
    ok.

join_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm0, _} = test_utils:start_swarm(BaseDir, join_test_swarm_0, 0),
    {Swarm1, _} = test_utils:start_swarm(BaseDir, join_test_swarm_1, 0),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),
    PubKeyBin1 = libp2p_swarm:pubkey_bin(Swarm1),
    {ok, Stream0} = libp2p_swarm:dial_framed_stream(
        Swarm0,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self(), PubKeyBin0]
    ),
    {ok, Stream1} = libp2p_swarm:dial_framed_stream(
        Swarm1,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self(), PubKeyBin1]
    ),
    {ok, HotspotName0} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin0)),
    {ok, HotspotName1} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    %% Send bad join message we should not get any data back
    Stream0 !
        {send,
            test_utils:join_packet(
                PubKeyBin0,
                crypto:strong_rand_bytes(16),
                crypto:strong_rand_bytes(2),
                #{rssi => -100}
            )},
    receive
        {client_data, _, _Data3} ->
            ct:fail("join didn't fail")
    after 0 -> ok
    end,

    %% Send join packets where PubKeyBin1 has better rssi
    DevNonce = crypto:strong_rand_bytes(2),
    Stream0 ! {send, test_utils:join_packet(PubKeyBin0, AppKey, DevNonce, #{rssi => -100})},
    timer:sleep(500),
    Stream1 ! {send, test_utils:join_packet(PubKeyBin1, AppKey, DevNonce, #{rssi => -80})},
    timer:sleep(router_utils:join_timeout()),

    %% Waiting for console repor status sent (it should select PubKeyBin1 cause better rssi)
    {ok, #{<<"id">> := JoinUUID}} = test_utils:wait_for_console_event(<<"join_request">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"join_request">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => fun erlang:is_map/1,
            <<"fcnt">> => 0,
            <<"payload_size">> => 0,
            <<"payload">> => <<>>,
            <<"raw_packet">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                <<"name">> => erlang:list_to_binary(HotspotName0),
                <<"rssi">> => -100.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => <<"unknown">>,
                <<"long">> => <<"unknown">>
            }
        }
    }),
    test_utils:wait_for_console_event(<<"join_request">>, #{
        <<"id">> => JoinUUID,
        <<"category">> => <<"join_request">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => fun erlang:is_map/1,
            <<"fcnt">> => 0,
            <<"payload_size">> => 0,
            <<"payload">> => <<>>,
            <<"raw_packet">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName1),
                <<"rssi">> => -80.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => <<"unknown">>,
                <<"long">> => <<"unknown">>
            }
        }
    }),

    test_utils:wait_for_console_event(<<"join_accept">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"join_accept">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 0,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName1),
                <<"rssi">> => 27,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW500">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => <<"unknown">>,
                <<"long">> => <<"unknown">>
            }
        }
    }),

    %% Waiting for reply resp form router
    {_NetID, _DevAddr, _DLSettings, _RxDelay, NwkSKey, AppSKey, CFList} = test_utils:wait_for_join_resp(
        PubKeyBin1,
        AppKey,
        DevNonce
    ),
    ?assertEqual(CFList, <<>>),
    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    Stream0 !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin0,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0
            )},

    %% Waiting for report channel status
    test_utils:wait_for_console_event(<<"uplink">>, #{
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
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                <<"name">> => erlang:list_to_binary(HotspotName0),
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => <<"unknown">>,
                <<"long">> => <<"unknown">>
            },
            <<"mac">> => [],
            <<"hold_time">> => fun erlang:is_integer/1
        }
    }),

    {ok, Device1} = router_device:get_by_id(DB, CF, WorkerID),

    ?assertEqual(NwkSKey, router_device:nwk_s_key(Device1)),
    ?assertEqual(AppSKey, router_device:app_s_key(Device1)),
    %% ?assertEqual([DevNonce], router_device:dev_nonces(Device1)),

    libp2p_swarm:stop(Swarm0),
    libp2p_swarm:stop(Swarm1),
    ok.

us915_join_enabled_cf_list_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    HotspotDir = proplists:get_value(base_dir, Config) ++ "/us915_join_enabled_cf_list_test",
    filelib:ensure_dir(HotspotDir),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    %% Tell the device to enable join-accept cflist when it starts up
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {cf_list_enabled, true}),

    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self(), PubKeyBin]
    ),

    %% Send join packet
    DevNonce1 = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce1, #{rssi => -100})},
    timer:sleep(router_utils:join_timeout()),

    %% Waiting for reply resp form router
    {_NetID1, _DevAddr1, _DLSettings1, _RxDelay1, _NwkSKey1, _AppSKey1, CFList1} = test_utils:wait_for_join_resp(
        PubKeyBin,
        AppKey,
        DevNonce1
    ),
    %% CFList should not be empty.
    %% Has a channel mask setup
    ?assertNotEqual(<<>>, CFList1),

    %% Send another join to get a different cflist
    DevNonce2 = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce2, #{rssi => -100})},
    timer:sleep(router_utils:join_timeout()),

    {_NetID2, _DevAddr2, _DLSettings2, _RxDelay2, _NwkSKey2, _AppSKey2, CFList2} = test_utils:wait_for_join_resp(
        PubKeyBin,
        AppKey,
        DevNonce2
    ),
    ?assertNotEqual(<<>>, CFList2),

    %% Send one more just to make sure it wasn't a fluke
    DevNonce3 = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce3, #{rssi => -100})},
    timer:sleep(router_utils:join_timeout()),

    {_NetID3, _DevAddr3, _DLSettings3, _RxDelay3, NwkSKey3, AppSKey3, CFList3} = test_utils:wait_for_join_resp(
        PubKeyBin,
        AppKey,
        DevNonce3
    ),
    ?assertNotEqual(<<>>, CFList3),

    %% Send a first packet not request ADR to make sure we still get a channel
    %% correction message on the first packet.
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                NwkSKey3,
                AppSKey3,
                0,
                #{wants_adr => false}
            )},

    {ok, Reply} = test_utils:wait_state_channel_message(
        1250,
        PubKeyBin,
        AppSKey3
    ),

    <<CFListChannelMask:16/little-integer, _/binary>> = CFList3,
    ?assertMatch(
        [
            %% LinkADRReq shape:
            %% {link_adr_req, DataRate, TXPower, ChMask, ChMaskCntl, NbTrans}
            {link_adr_req, _, _, _NoActiveChannels = 0, _All125kHzOFF = 7, _},
            {link_adr_req, _, _, CFListChannelMask, _ApplyChannels0to15 = 0, _}
        ],
        proplists:lookup_all(link_adr_req, Reply#frame.fopts),
        "Downlink turns on same channels as join cflist"
    ),
    ok.

us915_join_disabled_cf_list_test(Config) ->
    %% NOTE: Disabled is default for cflist per device

    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    HotspotDir = proplists:get_value(base_dir, Config) ++ "/us915_join_disabled_cf_list_test",
    filelib:ensure_dir(HotspotDir),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),

    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    %% Tell the device to disable join-accept cflist when it starts up
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {cf_list_enabled, false}),

    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self(), PubKeyBin]
    ),

    SendJoinWaitForCFListFun = fun() ->
        %% Send join packet
        DevNonce = crypto:strong_rand_bytes(2),
        Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce, #{rssi => -100})},
        timer:sleep(router_utils:join_timeout()),

        %% Waiting for reply resp from router
        {_NetID, _DevAddr, _DLSettings, _RxDelay, _NwkSKey, _AppSKey, CFList} = test_utils:wait_for_join_resp(
            PubKeyBin,
            AppKey,
            DevNonce
        ),
        CFList
    end,
    %% CFList should always be empty when toggle is turned false
    ?assertEqual(<<>>, SendJoinWaitForCFListFun()),
    ?assertEqual(<<>>, SendJoinWaitForCFListFun()),
    ?assertEqual(<<>>, SendJoinWaitForCFListFun()),
    ?assertEqual(<<>>, SendJoinWaitForCFListFun()),

    ok.

us915_link_adr_req_timing_test(Config) ->
    ok = application:set_env(router, testing, false),

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

    DefaultFrameTimeout = timer:seconds(2),

    %% ========================================================================
    %% Sending the first packet [fcnt: 0] expecting LNS to send link_adr_req
    %% commands with downlink.
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0
            )},

    {ok, #{<<"reported_at">> := UplinkReportedAt0}} = test_utils:wait_for_console_event(
        <<"uplink">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"dc">> => fun erlang:is_map/1,
                <<"fcnt">> => 0,
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

    {ok, #{<<"reported_at">> := DownlinkReportedAt0}} = test_utils:wait_for_console_event_sub(
        <<"downlink_unconfirmed">>,
        #{
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
                    <<"id">> => fun erlang:is_binary/1,
                    <<"name">> => fun erlang:is_binary/1,
                    <<"status">> => <<"success">>
                },
                <<"mac">> => [
                    #{
                        <<"command">> => <<"link_adr_req">>,
                        <<"data_rate">> => fun erlang:is_integer/1,
                        <<"tx_power">> => fun erlang:is_integer/1,
                        <<"channel_mask">> => fun erlang:is_integer/1,
                        <<"channel_mask_control">> => fun erlang:is_integer/1,
                        <<"number_of_transmissions">> => fun erlang:is_integer/1
                    },
                    #{
                        <<"command">> => <<"link_adr_req">>,
                        <<"data_rate">> => fun erlang:is_integer/1,
                        <<"tx_power">> => fun erlang:is_integer/1,
                        <<"channel_mask">> => fun erlang:is_integer/1,
                        <<"channel_mask_control">> => fun erlang:is_integer/1,
                        <<"number_of_transmissions">> => fun erlang:is_integer/1
                    }
                ]
            }
        }
    ),

    Time0 = DownlinkReportedAt0 - UplinkReportedAt0,
    ?assert(Time0 < DefaultFrameTimeout, "Downlink delivered before default timeout"),
    ?assert(Time0 < (DefaultFrameTimeout / 3), "Downlink delivered within reasonable window"),

    ok = test_utils:ignore_messages(),

    %% ========================================================================
    %% Sending the second packet [fcnt: 1] acknowledging the link_adr_req with
    %% link_adr_ans command. Nothing should be going down to the device, so we
    %% use the uplink_integration_req event to do our frame timeout calculation.
    %% NOTE: The frame timeout for this frame is still much shorter than we
    %% expect because the devices channel_correction does not get set until
    %% after the frame acknowledging the settings has been processed.

    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                1,
                #{fopts => [{link_adr_ans, 1, 1, 1}]}
            )},

    {ok, #{<<"id">> := UplinkUUID1, <<"reported_at">> := UplinkReportedAt1}} = test_utils:wait_for_console_event(
        <<"uplink">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"dc">> => fun erlang:is_map/1,
                <<"fcnt">> => 1,
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
                <<"mac">> => [
                    #{
                        <<"command">> => <<"link_adr_ans">>,
                        <<"channel_mask_ack">> => 1,
                        <<"data_rate_ack">> => 1,
                        <<"power_ack">> => 1
                    }
                ],
                <<"hold_time">> => fun erlang:is_integer/1
            }
        }
    ),

    {ok, #{<<"reported_at">> := DownlinkReportedAt1}} = test_utils:wait_for_console_event_sub(
        <<"uplink_integration_req">>,
        #{
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
        }
    ),

    Time1 = DownlinkReportedAt1 - UplinkReportedAt1,
    ?assert(
        Time1 < DefaultFrameTimeout,
        "No downlink to be sent, adr not acknowledged, still short window"
    ),

    ok = test_utils:ignore_messages(),

    %% ========================================================================
    %% Sending the third packet [fcnt: 2], just a basic packet. Nothing is going
    %% down the device, so we use the uplink_integration_req event to do our
    %% frame timeout calculation. By this time the device has recognized that
    %% its channels haven been corrected, and it should use a longer frame
    %% timeout to increase our chances of multi-buy packets.

    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                2
            )},

    {ok, #{<<"id">> := UplinkUUID2, <<"reported_at">> := UplinkReportedAt2}} = test_utils:wait_for_console_event(
        <<"uplink">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"dc">> => fun erlang:is_map/1,
                <<"fcnt">> => 2,
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

    {ok, #{<<"reported_at">> := DownlinkReportedAt2}} = test_utils:wait_for_console_event_sub(
        <<"uplink_integration_req">>,
        #{
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
        }
    ),

    Time2 = DownlinkReportedAt2 - UplinkReportedAt2,
    ?assert(
        DefaultFrameTimeout < Time2,
        "No downlink content waiting to be sent, waited for longer window"
    ),

    ok.

adr_downlink_timing_test(Config) ->
    %% During regular unconfirmed uplink operation, Router will wait extra time to
    %% have a better chance of getting packets. At some point in time, the ADREngine
    %% may determine that it can adjust something for a device and send a downlink.
    %% WHen that happens we need to make sure we're not missing the downlink window.

    %% Tell the device to enable adr
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {adr_allowed, true}),
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    ok = application:set_env(router, testing, false),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send up to min-adr-history-len # of packets to get off 'hold'.
    FrameCount = 20,
    ok = lists:foreach(
        fun(_Idx) ->
            FrameOptions =
                case _Idx of
                    1 ->
                        #{
                            wants_adr => true,
                            snr => 20.0,
                            fopts => [{link_adr_ans, 1, 1, 1}]
                        };
                    _ ->
                        #{wants_adr => true, snr => 20.0}
                end,

            %% Device sends unconfirmed up
            Stream !
                {send,
                    test_utils:frame_packet(
                        ?UNCONFIRMED_UP,
                        PubKeyBin,
                        router_device:nwk_s_key(Device0),
                        router_device:app_s_key(Device0),
                        _Idx,
                        FrameOptions
                    )},

            %% Unconfirmed uplink from device
            test_utils:wait_for_console_event_sub(<<"uplink_unconfirmed">>, #{
                <<"id">> => fun erlang:is_binary/1,
                <<"category">> => <<"uplink">>,
                <<"sub_category">> => <<"uplink_unconfirmed">>,
                <<"description">> => fun erlang:is_binary/1,
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"device_id">> => ?CONSOLE_DEVICE_ID,
                <<"data">> => #{
                    <<"dc">> => fun erlang:is_map/1,
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
                        <<"snr">> => 20.0,
                        <<"spreading">> => fun erlang:is_binary/1,
                        <<"frequency">> => fun erlang:is_float/1,
                        <<"channel">> => fun erlang:is_number/1,
                        <<"lat">> => fun erlang:is_float/1,
                        <<"long">> => fun erlang:is_float/1
                    },
                    <<"mac">> => fun erlang:is_list/1,
                    <<"hold_time">> => fun erlang:is_integer/1
                }
            })
        end,
        lists:seq(0, FrameCount)
    ),

    %% Clear old messages to ensure we're not picking up any other type of downlink.
    ok = test_utils:ignore_messages(),

    %% -------------------------------------------------------------------
    %% Now we should be getting adr adjustment
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                FrameCount + 1,
                #{
                    wants_adr => true,
                    snr => 20.0
                }
            )},

    %% Unconfirmed uplink from device
    {ok, #{<<"id">> := _UplinkUUID1, <<"reported_at">> := UplinkTime}} = test_utils:wait_for_console_event_sub(
        <<"uplink_unconfirmed">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_unconfirmed">>,
            <<"description">> => fun erlang:is_binary/1,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"dc">> => fun erlang:is_map/1,
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
                    <<"snr">> => 20.0,
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

    %% Unconfirmed downlink sent to device containing ADR adjustment
    {ok, #{<<"reported_at">> := DownlinkTime}} = test_utils:wait_for_console_event_sub(
        <<"downlink_unconfirmed">>,
        #{
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
                    <<"id">> => fun erlang:is_binary/1,
                    <<"name">> => fun erlang:is_binary/1,
                    <<"status">> => <<"success">>
                },
                <<"mac">> => [
                    %% Note these commands are not the same as sub-band 2 configuration.
                    #{
                        <<"channel_mask">> => 0,
                        <<"channel_mask_control">> => 7,
                        <<"command">> => <<"link_adr_req">>,
                        <<"data_rate">> => 3,
                        <<"number_of_transmissions">> => 0,
                        <<"tx_power">> => 7
                    },
                    #{
                        <<"channel_mask">> => 65280,
                        <<"channel_mask_control">> => 0,
                        <<"command">> => <<"link_adr_req">>,
                        <<"data_rate">> => 3,
                        <<"number_of_transmissions">> => 0,
                        <<"tx_power">> => 7
                    }
                ]
            }
        }
    ),
    Time = DownlinkTime - UplinkTime,
    %% ct:print("[up: ~p] [down: ~p] [diff: ~p]", [UplinkTime, DownlinkTime, Time]),
    ?assert(Time =< 250, "Missed the downlink window"),
    ?assert(0 < Time, "Downlinks cannot happen in the past"),

    ok.

adr_test(Config) ->
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

    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Channel = router_channel:new(
        <<"fake">>,
        websocket,
        <<"fake">>,
        #{},
        0,
        self()
    ),

    %%
    %% Device can join
    %% ---------------------------------------------------------------

    %% Queue unconfirmed downlink message for device
    Msg0 = #downlink{confirmed = false, port = 1, payload = <<"somepayload">>, channel = Channel},
    router_device_worker:queue_downlink(WorkerPid, Msg0),

    test_utils:wait_for_console_event_sub(<<"downlink_queued">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_queued">>,
        <<"description">> => <<"Downlink queued in last place">>,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => fun erlang:is_integer/1,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => lorawan_utils:binary_to_hex(router_device:devaddr(Device0)),
            <<"hotspot">> => #{},
            <<"integration">> => #{
                <<"id">> => router_channel:id(Msg0#downlink.channel),
                <<"name">> => router_channel:name(Msg0#downlink.channel),
                <<"status">> => <<"success">>
            }
        }
    }),

    %% Queue confirmed downlink message for device
    Msg1 = #downlink{
        confirmed = true,
        port = 2,
        payload = <<"someotherpayload">>,
        channel = Channel
    },
    router_device_worker:queue_downlink(WorkerPid, Msg1),

    test_utils:wait_for_console_event_sub(<<"downlink_queued">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_queued">>,
        <<"description">> => <<"Downlink queued in last place">>,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => fun erlang:is_integer/1,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => lorawan_utils:binary_to_hex(router_device:devaddr(Device0)),
            <<"hotspot">> => #{},
            <<"integration">> => #{
                <<"id">> => router_channel:id(Msg1#downlink.channel),
                <<"name">> => router_channel:name(Msg1#downlink.channel),
                <<"status">> => <<"success">>
            }
        }
    }),

    %% Device sends unconfirmed up
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{
                    wants_adr => true,
                    datarate => <<"SF10BW125">>,
                    snr => 20.0
                }
            )},

    %% Wait HTTP channel data
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
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
                <<"snr">> => 20.0,
                <<"spreading">> => <<"SF10BW125">>,
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

    %% Unconfirmed downlink sent to device
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
            <<"port">> => Msg0#downlink.port,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => 27,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF10BW500">>,
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
            <<"mac">> => fun erlang:is_list/1
        }
    }),

    %% Unconfirmed uplink from device
    {ok, #{<<"id">> := UplinkUUID1}} = test_utils:wait_for_console_event(<<"uplink">>, #{
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
                <<"snr">> => 20.0,
                <<"spreading">> => <<"SF10BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            },
            <<"mac">> => [],
            <<"hold_time">> => fun erlang:is_integer/1
        }
    }),

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

    %% Device received unconfirmed down
    {ok, Reply1} = test_utils:wait_state_channel_message(
        Msg0,
        Device0,
        Msg0#downlink.payload,
        ?UNCONFIRMED_DOWN,
        1,
        0,
        1,
        0
    ),
    ct:pal("Reply ~p", [Reply1]),
    true = lists:keymember(link_adr_req, 1, Reply1#frame.fopts),
    %% "ADR bit normally must be set if MAC ADR command is downlinked"
    ?assertEqual(1, Reply1#frame.adr),

    %% Send CONFIRMED_UP frame packet
    Stream !
        {send,
            test_utils:frame_packet(
                ?CONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                1,
                #{
                    wants_adr => true,
                    snr => 20.0
                }
            )},

    %% ---------------------------------------------------------------
    %% Waiting for data from HTTP channel
    %% ---------------------------------------------------------------
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => <<"rx_delay_established">>,
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
                <<"snr">> => 20.0,
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

    %% ---------------------------------------------------------------
    %% Waiting for ack cause we sent a CONFIRMED_UP
    %% ---------------------------------------------------------------
    test_utils:wait_for_console_event_sub(<<"downlink_ack">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_ack">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 1,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => Msg1#downlink.port,
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
            }
        }
    }),

    %% Waiting for report channel status from HTTP channel
    {ok, #{<<"id">> := UplinkUUID2}} = test_utils:wait_for_console_event(<<"uplink">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_confirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => #{<<"balance">> => 97, <<"nonce">> => 1, <<"used">> => 1},
            <<"fcnt">> => 1,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"raw_packet">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => 0.0,
                <<"snr">> => 20.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            },
            <<"mac">> => [],
            <<"hold_time">> => fun erlang:is_integer/1
        }
    }),

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
                <<"method">> => fun erlang:is_binary/1,
                <<"url">> => fun erlang:is_binary/1,
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
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => fun erlang:is_integer/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% ---------------------------------------------------------------
    %% Device received confirmed down
    %% ---------------------------------------------------------------
    {ok, Reply2} = test_utils:wait_state_channel_message(
        Msg1,
        Device0,
        Msg1#downlink.payload,
        ?CONFIRMED_DOWN,
        0,
        1,
        Msg1#downlink.port,
        1
    ),
    %% check we're still getting ADR commands
    true = lists:keymember(link_adr_req, 1, Reply2#frame.fopts),

    %% ---------------------------------------------------------------
    %% check we get the second downlink again because we didn't ACK it
    %% also ack the ADR adjustments
    %% ---------------------------------------------------------------
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                2,
                #{
                    wants_adr => true,
                    snr => 20.0,
                    fopts => [{link_adr_ans, 1, 1, 1}]
                }
            )},

    %% Waiting for data from HTTP channel
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
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
                <<"snr">> => 20.0,
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

    %% Sending Msg1 again because it was not acknowledged by the device
    %% Waiting for report channel status down message
    test_utils:wait_for_console_event_sub(<<"downlink_confirmed">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_confirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 1,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => Msg1#downlink.port,
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
                <<"id">> => fun erlang:is_binary/1,
                <<"name">> => fun erlang:is_binary/1,
                <<"status">> => <<"success">>
            },
            <<"mac">> => fun erlang:is_list/1
        }
    }),

    %% Waiting for report channel status from HTTP channel
    {ok, #{<<"id">> := UplinkUUID3}} = test_utils:wait_for_console_event(<<"uplink">>, #{
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
                <<"snr">> => 20.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            },
            <<"mac">> => [
                #{
                    <<"channel_mask_ack">> => 1,
                    <<"command">> => <<"link_adr_ans">>,
                    <<"data_rate_ack">> => 1,
                    <<"power_ack">> => 1
                }
            ],
            <<"hold_time">> => fun erlang:is_integer/1
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_req">>, #{
        <<"id">> => UplinkUUID3,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_req">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Request sent to ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"method">> => fun erlang:is_binary/1,
                <<"url">> => fun erlang:is_binary/1,
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
        <<"id">> => UplinkUUID3,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => fun erlang:is_integer/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% Device received confirmed down from Msg1
    {ok, Reply3} = test_utils:wait_state_channel_message(
        Msg1,
        Device0,
        Msg1#downlink.payload,
        ?CONFIRMED_DOWN,
        0,
        0,
        2,
        1
    ),
    %% check NOT we're still getting ADR commands
    false = lists:keymember(link_adr_req, 1, Reply3#frame.fopts),

    %% ack resent Msg1 packet, not requesting a reply
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                3,
                #{
                    wants_adr => true,
                    snr => 20.0,
                    wants_ack => true
                }
            )},

    %% Waiting for data from HTTP channel
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 3,
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
                <<"snr">> => 20.0,
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

    %% Waiting for report channel status from HTTP channel
    {ok, #{<<"id">> := UplinkUUID4}} = test_utils:wait_for_console_event(<<"uplink">>, #{
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
                <<"snr">> => 20.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            },
            <<"mac">> => [],
            <<"hold_time">> => fun erlang:is_integer/1
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_req">>, #{
        <<"id">> => UplinkUUID4,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_req">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Request sent to ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"method">> => fun erlang:is_binary/1,
                <<"url">> => fun erlang:is_binary/1,
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
        <<"id">> => UplinkUUID4,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => fun erlang:is_integer/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    receive
        {client_data, _, _Data3} ->
            Decoded = {response, Response} = blockchain_state_channel_message_v1:decode(_Data3),
            case blockchain_state_channel_response_v1:downlink(Response) of
                undefined ->
                    ok;
                _ ->
                    ct:fail("unexpected_reply ~p", [Decoded])
            end
    after 2000 -> ok
    end,

    %% send a confimed up to provoke a 'bare ack'
    Stream !
        {send,
            test_utils:frame_packet(
                ?CONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                4,
                #{
                    snr => 20.0,
                    wants_adr => false
                }
            )},

    %% Waiting for data from HTTP channel
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 4,
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
                <<"snr">> => 20.0,
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

    %% Waiting for report channel status from HTTP channel
    {ok, #{<<"id">> := UplinkUUID5}} = test_utils:wait_for_console_event(<<"uplink">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_confirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => #{<<"balance">> => 94, <<"nonce">> => 1, <<"used">> => 1},
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
                <<"snr">> => 20.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            },
            <<"mac">> => [],
            <<"hold_time">> => fun erlang:is_integer/1
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_req">>, #{
        <<"id">> => UplinkUUID5,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_req">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Request sent to ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"method">> => fun erlang:is_binary/1,
                <<"url">> => fun erlang:is_binary/1,
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
        <<"id">> => UplinkUUID5,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => fun erlang:is_integer/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    %% Wait for device status ack message
    %% Downlinks have been exhausted
    test_utils:wait_for_console_event_sub(<<"downlink_ack">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_ack">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 2,
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
            }
        }
    }),

    %% Device received unconfirmed down, no longer contains adr commands
    {ok, Reply4} = test_utils:wait_state_channel_message(
        Msg1,
        Device0,
        <<>>,
        ?UNCONFIRMED_DOWN,
        0,
        1,
        undefined,
        2
    ),

    %% Router requests device to set ADR parameters.
    %%
    %% NOTE: this will fail in the future when we implement the
    %%       ability to set `should_adr' in `#router_device.metadata'
    false = lists:keymember(link_adr_req, 1, Reply4#frame.fopts),
    ok.

rx_delay_join_test(Config) ->
    ExpectedRxDelay = 5,
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {rx_delay, ExpectedRxDelay}),

    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm, _} = test_utils:start_swarm(BaseDir, join_test_swarm_0, 0),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self(), PubKeyBin]
    ),
    {ok, _HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packets
    DevNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce, #{})},
    timer:sleep(router_utils:join_timeout()),

    %% Waiting for console report status sent
    {ok, _} = test_utils:wait_for_console_event(<<"join_request">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"join_request">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => fun erlang:is_map/1,
            <<"fcnt">> => 0,
            <<"payload_size">> => 0,
            <<"payload">> => <<>>,
            <<"raw_packet">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => fun erlang:is_binary/1,
                <<"name">> => fun erlang:is_binary/1,
                <<"rssi">> => fun erlang:is_number/1,
                <<"snr">> => 0.0,
                <<"spreading">> => fun erlang:is_binary/1,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => <<"unknown">>,
                <<"long">> => <<"unknown">>
            }
        }
    }),

    test_utils:wait_for_console_event(<<"join_accept">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"join_accept">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 0,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => fun erlang:is_binary/1,
                <<"name">> => fun erlang:is_binary/1,
                <<"rssi">> => 27,
                <<"snr">> => 0.0,
                <<"spreading">> => fun erlang:is_binary/1,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => <<"unknown">>,
                <<"long">> => <<"unknown">>
            }
        }
    }),

    %% Waiting for reply resp form router
    {_NetID, _DevAddr, _DLSettings, RxDelay, _NwkSKey, _AppSKey, _CFList} = test_utils:wait_for_join_resp(
        PubKeyBin,
        AppKey,
        DevNonce
    ),
    ?assertEqual(ExpectedRxDelay, RxDelay),

    libp2p_swarm:stop(Swarm),
    ok.

rx_delay_downlink_default_test(Config) ->
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := _HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),

    %% TODO uncomment if testing against other regions.
    %% Channel = router_channel:new(
    %%     <<"fake">>,
    %%     websocket,
    %%     <<"fake">>,
    %%     #{},
    %%     0,
    %%     self()
    %% ),
    %% Msg = #downlink{confirmed = false, port = 1, payload = <<"somepayload">>, channel = Channel},
    %% router_device_worker:queue_downlink(WorkerPid, Msg),

    Metadata0 = router_device:metadata(Device0),
    ?assertEqual(rx_delay_established, maps:get(rx_delay_state, Metadata0)),
    %% Test lib console_callback:handle('GET', [<<"api">>,...]) injects `rx_delay`,
    %% but real Console/API might not send it unless changed from default value of 0.
    ?assertEqual(0, maps:get(rx_delay, Metadata0)),
    ?assertEqual(false, maps:is_key(rx_delay_actual, Metadata0)),

    test_utils:ignore_messages(),
    Send = fun(Fcnt, FOpts) ->
        Stream !
            {send,
                test_utils:frame_packet(
                    ?CONFIRMED_UP,
                    PubKeyBin,
                    router_device:nwk_s_key(Device0),
                    router_device:app_s_key(Device0),
                    Fcnt,
                    #{fopts => FOpts}
                )},
        timer:sleep(router_utils:frame_timeout())
    end,
    Send(0, []),

    {ok, Packet0} = test_utils:wait_state_channel_packet(1000),

    %% check that the timestamp of the packet_pb is our default (1 second in the future)
    ?assertEqual(1000000, Packet0#packet_pb.timestamp),

    %% Simulate the Console setting `rx_delay` to non-default value
    %% during same session / without device joining again:

    ExpectedRxDelay = 9,
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {rx_delay, ExpectedRxDelay}),

    %% Must wait for device to Send again, but device won't know about new rx_delay
    %% until response/downlink.

    Send(1, []),
    {ok, Packet1} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(1000000, Packet1#packet_pb.timestamp),

    %% Get API's `rx_delay` into Metadata:
    router_device_worker:device_update(WorkerPid),
    %% Wait for async/cast to complete:
    timer:sleep(1000),

    {ok, Device1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    Metadata1 = router_device:metadata(Device1),
    ?assertEqual(rx_delay_change, maps:get(rx_delay_state, Metadata1)),
    ?assertEqual(ExpectedRxDelay, maps:get(rx_delay, Metadata1)),
    ?assertEqual(false, maps:is_key(rx_delay_actual, Metadata1)),

    %% Device being delinquent about sending ACK.
    Send(2, []),
    {ok, Packet2} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(1000000, Packet2#packet_pb.timestamp),

    %% Confirm intermediate state:
    {ok, Device2} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    Metadata2 = router_device:metadata(Device2),
    ?assertEqual(rx_delay_requested, maps:get(rx_delay_state, Metadata2)),
    ?assertEqual(ExpectedRxDelay, maps:get(rx_delay, Metadata2)),
    ?assertEqual(false, maps:is_key(rx_delay_actual, Metadata2)),

    %% Device ACK
    Send(3, [rx_timing_setup_ans]),

    %% Handling `frame_timeout` calls adjust_rx_delay(), so state has been updated.

    %% Downlink after ACK uses requested RxDelay
    {ok, Packet3} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(ExpectedRxDelay * 1000000, Packet3#packet_pb.timestamp),

    {ok, Device3} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    Metadata3 = router_device:metadata(Device3),
    ?assertEqual(rx_delay_established, maps:get(rx_delay_state, Metadata3)),
    ?assertEqual(ExpectedRxDelay, maps:get(rx_delay_actual, Metadata3)),
    ok.

rx_delay_change_ignored_by_device_downlink_test(Config) ->
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := _HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device} = router_device:get_by_id(DB, CF, WorkerID),
    {ok, _WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),

    %% TODO uncomment if testing against other regions.
    %% Channel = router_channel:new(
    %%     <<"fake">>,
    %%     websocket,
    %%     <<"fake">>,
    %%     #{},
    %%     0,
    %%     self()
    %% ),
    %% Msg = #downlink{confirmed = false, port = 1, payload = <<"somepayload">>, channel = Channel},
    %% router_device_worker:queue_downlink(WorkerPid, Msg),

    test_utils:ignore_messages(),
    Send = fun(Fcnt, FOpts) ->
        Stream !
            {send,
                test_utils:frame_packet(
                    ?CONFIRMED_UP,
                    PubKeyBin,
                    router_device:nwk_s_key(Device),
                    router_device:app_s_key(Device),
                    Fcnt,
                    #{fopts => FOpts}
                )},
        timer:sleep(router_utils:frame_timeout())
    end,
    Send(0, []),
    timer:sleep(router_utils:frame_timeout()),

    {ok, Packet0} = test_utils:wait_state_channel_packet(1000),

    %% Check that the timestamp of the packet_pb is our default (1 second in the future)
    ?assertEqual(1000000, Packet0#packet_pb.timestamp),

    %% Simulate the Console setting `rx_delay` to non-default value
    %% during same session / without device joining again:

    ExpectedRxDelay = 9,
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {rx_delay, ExpectedRxDelay}),

    %% Must wait for device to Send again, but device won't know about new rx_delay
    %% until response/downlink
    Send(1, []),
    timer:sleep(router_utils:frame_timeout()),
    {ok, Packet1} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(1000000, Packet1#packet_pb.timestamp),

    %% Uncommenting this will cause test case to fail:
    %% %% Get API's `rx_delay` in Metadata:
    %%router_device_worker:device_update(WorkerPid),

    %% Device omits ACK of new RxDelay, thus no `rx_timing_setup_ans` in FOpts.
    Send(2, []),
    timer:sleep(router_utils:frame_timeout()),

    %% Downlink after ACK would use new RxDelay, but there was no ACK.
    {ok, Packet2} = test_utils:wait_state_channel_packet(1000),
    ?assertNotEqual(ExpectedRxDelay * 1000000, Packet2#packet_pb.timestamp),
    ?assertEqual(1000000, Packet2#packet_pb.timestamp),
    ok.

rx_delay_accepted_by_device_downlink_test(Config) ->
    ExpectedRxDelay = 15,
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {rx_delay, ExpectedRxDelay}),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := _HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),

    %% TODO uncomment if testing against other regions.
    %% Channel = router_channel:new(
    %%     <<"fake">>,
    %%     websocket,
    %%     <<"fake">>,
    %%     #{},
    %%     0,
    %%     self()
    %% ),
    %% Msg = #downlink{confirmed = false, port = 1, payload = <<"somepayload">>, channel = Channel},
    %% router_device_worker:queue_downlink(WorkerPid, Msg),

    test_utils:ignore_messages(),
    Stream !
        {send,
            test_utils:frame_packet(
                ?CONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{
                    %% No rx_timing_setup_ans necessary upon Join, as join-accept flow is the ACK.
                    fopts => [
                        %% rx_timing_setup_ans
                    ]
                }
            )},
    timer:sleep(router_utils:frame_timeout()),

    {ok, Packet} = test_utils:wait_state_channel_packet(1000),

    ?assertEqual(ExpectedRxDelay * 1000000, Packet#packet_pb.timestamp),

    %% Get API's `rx_delay` into Metadata:
    router_device_worker:device_update(WorkerPid),
    timer:sleep(1000),
    {ok, Device1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    Metadata = router_device:metadata(Device1),

    ?assertEqual(ExpectedRxDelay, maps:get(rx_delay, Metadata)),
    ?assertEqual(rx_delay_established, maps:get(rx_delay_state, Metadata)),
    ok.

rx_delay_continue_session_test(Config) ->
    ExpectedRxDelay = 15,
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {rx_delay, ExpectedRxDelay}),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := _HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),
    {ok, WorkerPid0} = router_devices_sup:lookup_device_worker(WorkerID),

    %% TODO uncomment if testing against other regions.
    %% Channel = router_channel:new(
    %%     <<"fake">>,
    %%     websocket,
    %%     <<"fake">>,
    %%     #{},
    %%     0,
    %%     self()
    %% ),
    %% Msg = #downlink{confirmed = false, port = 1, payload = <<"somepayload">>, channel = Channel},
    %% router_device_worker:queue_downlink(WorkerPid0, Msg),

    test_utils:ignore_messages(),
    Send = fun(Fcnt, FOpts) ->
        Stream !
            {send,
                test_utils:frame_packet(
                    ?CONFIRMED_UP,
                    PubKeyBin,
                    router_device:nwk_s_key(Device0),
                    router_device:app_s_key(Device0),
                    Fcnt,
                    #{fopts => FOpts}
                )},
        timer:sleep(router_utils:frame_timeout())
    end,
    %% No rx_timing_setup_ans necessary upon Join, as join-accept flow is the ACK.
    Send(0, []),
    {ok, Packet0} = test_utils:wait_state_channel_packet(1000),

    ?assertEqual(ExpectedRxDelay * 1000000, Packet0#packet_pb.timestamp),

    gen_server:stop(WorkerPid0),

    Send(1, []),
    {ok, Packet1} = test_utils:wait_state_channel_packet(1000),

    {ok, WorkerPid1} = router_devices_sup:lookup_device_worker(WorkerID),

    %% We haven't ack'd channel correction

    ?assertEqual(ExpectedRxDelay * 1000000, Packet1#packet_pb.timestamp),

    Channel = router_channel:new(
        <<"fake">>,
        websocket,
        <<"fake">>,
        #{},
        0,
        self()
    ),
    Msg = #downlink{confirmed = false, port = 1, payload = <<"somepayload">>, channel = Channel},
    router_device_worker:queue_downlink(WorkerPid1, Msg),

    Send(2, []),
    {ok, Packet2} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(ExpectedRxDelay * 1000000, Packet2#packet_pb.timestamp),

    %% Re-join device, and change its RX_DELAY:
    %% 1. rejoin the device
    %% 2. send an uplink _not_ acknowledging the rx_timing_setup
    %% 3. our delay should remain 15 seconds (ExpectedRxDelay)

    #{
        pubkey_bin := _PubKeyBin1,
        stream := Stream1,
        hotspot_name := _HotspotName1
    } = test_utils:join_device(Config),

    timer:sleep(router_utils:join_timeout()),

    {ok, Device1} = router_device:get_by_id(DB, CF, WorkerID),

    Send1 = fun(Fcnt, FOpts) ->
        Stream1 !
            {send,
                test_utils:frame_packet(
                    ?CONFIRMED_UP,
                    PubKeyBin,
                    router_device:nwk_s_key(Device1),
                    router_device:app_s_key(Device1),
                    Fcnt,
                    #{fopts => FOpts}
                )},
        timer:sleep(router_utils:frame_timeout())
    end,

    test_utils:ignore_messages(),

    Send1(0, []),
    {ok, Packet3} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(ExpectedRxDelay * 1000000, Packet3#packet_pb.timestamp),
    ok.

rx_delay_change_during_session_test(Config) ->
    ExpectedRxDelay1 = 9,
    Tab = proplists:get_value(ets, Config),
    _ = ets:insert(Tab, {rx_delay, ExpectedRxDelay1}),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := _HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),

    %% TODO uncomment if testing against other regions.
    %% Channel = router_channel:new(
    %%     <<"fake">>,
    %%     websocket,
    %%     <<"fake">>,
    %%     #{},
    %%     0,
    %%     self()
    %% ),
    %% Msg = #downlink{confirmed = false, port = 1, payload = <<"somepayload">>, channel = Channel},
    %% router_device_worker:queue_downlink(WorkerPid, Msg),

    Metadata0 = router_device:metadata(Device0),
    ?assertEqual(rx_delay_established, maps:get(rx_delay_state, Metadata0)),
    ?assertEqual(ExpectedRxDelay1, maps:get(rx_delay, Metadata0)),
    ?assertEqual(ExpectedRxDelay1, maps:get(rx_delay_actual, Metadata0)),

    test_utils:ignore_messages(),
    Send = fun(Fcnt, FOpts) ->
        Stream !
            {send,
                test_utils:frame_packet(
                    ?CONFIRMED_UP,
                    PubKeyBin,
                    router_device:nwk_s_key(Device0),
                    router_device:app_s_key(Device0),
                    Fcnt,
                    #{fopts => FOpts}
                )},
        timer:sleep(router_utils:frame_timeout())
    end,

    %% No rx_timing_setup_ans necessary upon Join, as join-accept flow is the ACK.
    Send(0, []),
    {ok, Packet0} = test_utils:wait_state_channel_packet(1000),

    ?assertEqual(ExpectedRxDelay1 * 1000000, Packet0#packet_pb.timestamp),

    %% Simulate a change in `rx_delay` value from Console:
    ExpectedRxDelay2 = 5,
    _ = ets:insert(Tab, {rx_delay, ExpectedRxDelay2}),

    Send(1, []),
    {ok, Packet1} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(ExpectedRxDelay1 * 1000000, Packet1#packet_pb.timestamp),

    %% Get API's `rx_delay` into Metadata:
    router_device_worker:device_update(WorkerPid),
    %% Wait for async/cast to complete:
    timer:sleep(1000),

    {ok, Device1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    Metadata1 = router_device:metadata(Device1),
    ?assertEqual(rx_delay_change, maps:get(rx_delay_state, Metadata1)),
    ?assertEqual(ExpectedRxDelay2, maps:get(rx_delay, Metadata1)),
    ?assertEqual(ExpectedRxDelay1, maps:get(rx_delay_actual, Metadata1)),

    %% Another frame without ACK so that we can see intermediate state,
    %% because state only gets updated during `frame_timeout`:
    Send(2, []),

    {ok, Packet2} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(ExpectedRxDelay1 * 1000000, Packet2#packet_pb.timestamp),

    {ok, Device2} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    Metadata2 = router_device:metadata(Device2),
    ?assertEqual(rx_delay_requested, maps:get(rx_delay_state, Metadata2)),
    ?assertEqual(ExpectedRxDelay2, maps:get(rx_delay, Metadata2)),
    ?assertEqual(ExpectedRxDelay1, maps:get(rx_delay_actual, Metadata2)),

    %% Device ACK
    Send(3, [rx_timing_setup_ans]),

    %% Handling `frame_timeout` calls adjust_rx_delay(), so state has been updated.

    %% Downlink after ACK uses new RxDelay
    {ok, Packet3} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(ExpectedRxDelay2 * 1000000, Packet3#packet_pb.timestamp),

    {ok, Device3} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    Metadata3 = router_device:metadata(Device3),
    ?assertEqual(rx_delay_established, maps:get(rx_delay_state, Metadata3)),
    ?assertEqual(ExpectedRxDelay2, maps:get(rx_delay_actual, Metadata3)),

    %% Subsequent uplink after ACK continues using newer rx_delay.
    Send(4, []),
    {ok, Packet4} = test_utils:wait_state_channel_packet(1000),
    ?assertEqual(ExpectedRxDelay2 * 1000000, Packet4#packet_pb.timestamp),
    {ok, Device4} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    Metadata4 = router_device:metadata(Device4),
    ?assertEqual(rx_delay_established, maps:get(rx_delay_state, Metadata4)),
    ?assertEqual(ExpectedRxDelay2, maps:get(rx_delay_actual, Metadata4)),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

parse_fopts(FOpts) ->
    lists:map(
        fun(FOpt) ->
            case FOpt of
                FOpt when is_atom(FOpt) ->
                    #{<<"command">> => atom_to_binary(FOpt, utf8)};
                {link_adr_ans, PowerACK, DataRateACK, ChannelMaskACK} ->
                    #{
                        <<"command">> => <<"link_adr_ans">>,
                        <<"power_ack">> => PowerACK,
                        <<"data_rate_ack">> => DataRateACK,
                        <<"channel_mask_ack">> => ChannelMaskACK
                    };
                {rx_param_setup_ans, RX1DROffsetACK, RX2DataRateACK, ChannelACK} ->
                    #{
                        <<"command">> => <<"rx_param_setup_ans">>,
                        <<"rx1_offset_ack">> => RX1DROffsetACK,
                        <<"rx2_data_rate_ack">> => RX2DataRateACK,
                        <<"channel_ack">> => ChannelACK
                    };
                {dev_status_ans, Battery, Margin} ->
                    #{
                        <<"command">> => <<"dev_status_ans">>,
                        <<"battery">> => Battery,
                        <<"margin">> => Margin
                    };
                {new_channel_ans, DataRateRangeOK, ChannelFreqOK} ->
                    #{
                        <<"command">> => <<"new_channel_ans">>,
                        <<"data_rate_ok">> => DataRateRangeOK,
                        <<"channel_freq_ok">> => ChannelFreqOK
                    };
                {di_channel_ans, UplinkFreqExists, ChannelFreqOK} ->
                    #{
                        <<"command">> => <<"di_channel_ans">>,
                        <<"uplink_freq_exists">> => UplinkFreqExists,
                        <<"channel_freq_ok">> => ChannelFreqOK
                    };
                _FOpt ->
                    #{<<"command">> => <<"unknown">>}
            end
        end,
        FOpts
    ).
