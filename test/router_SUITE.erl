-module(router_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    mac_commands_test/1,
    dupes_test/1,
    dupes2_test/1,
    join_test/1,
    us915_join_enabled_cf_list_test/1,
    us915_join_disabled_cf_list_test/1,
    adr_test/1
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
        dupes_test,
        join_test,
        us915_join_enabled_cf_list_test,
        us915_join_disabled_cf_list_test,
        adr_test
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

mac_commands_test(Config) ->
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
                    <<"mac">> => ExpectedFopts
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
    {ok, DB, [_, CF]} = router_db:get(),
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
    router_device_worker:queue_message(WorkerPid, Msg0),

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
            <<"cf_list_enabled">> => false
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
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
        ]
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
                <<"mac">> => []
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
                <<"mac">> => []
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
    {ok, DB, [_, CF]} = router_db:get(),
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
            <<"cf_list_enabled">> => false
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
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
                <<"mac">> => []
            }
        }
    ),

    receive
        {console_event, <<"uplink">>, <<"uplink_unconfirmed">>, Map} ->
            ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Map]),
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
    {ok, DB, [_, CF]} = router_db:get(),
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
            <<"mac">> => []
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
    HotspotDir = proplists:get_value(base_dir, Config) ++ "/join_cf_list_test",
    filelib:ensure_dir(HotspotDir),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm, _} = test_utils:start_swarm(HotspotDir, no_this_is_patrick, 0),
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
    %% This CFList is empty. We don't know if the device is using lora version
    %% older than 1.0.3 and might be choking on the cflist, so we'll send an
    %% empty one and see if they can join with that. The device will still
    %% receive a channel mask update in the first packets downlink after join.
    ?assertEqual(<<>>, CFList2),

    %% Send one more just to make sure it wasn't a fluke
    DevNonce3 = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce3, #{rssi => -100})},
    timer:sleep(router_utils:join_timeout()),

    {_NetID3, _DevAddr3, _DLSettings3, _RxDelay3, NwkSKey3, AppSKey3, CFList3} = test_utils:wait_for_join_resp(
        PubKeyBin,
        AppKey,
        DevNonce3
    ),
    %% We alternate sending and not sending the channel mask cflist.
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

    <<CFListChannelMask:16/integer, _/binary>> = CFList3,
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

    libp2p_swarm:stop(Swarm),
    ok.

us915_join_disabled_cf_list_test(Config) ->
    %% NOTE: Disabled is default for cflist per device

    AppKey = proplists:get_value(app_key, Config),
    HotspotDir = proplists:get_value(base_dir, Config) ++ "/join_cf_list_force_empty_test",
    filelib:ensure_dir(HotspotDir),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm, _} = test_utils:start_swarm(HotspotDir, no_this_is_patrick, 0),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

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

    libp2p_swarm:stop(Swarm),

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
    {ok, DB, [_, CF]} = router_db:get(),
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
    router_device_worker:queue_message(WorkerPid, Msg0),

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
    router_device_worker:queue_message(WorkerPid, Msg1),

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
            <<"cf_list_enabled">> => false
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
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
        ]
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
            <<"mac">> => []
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
            <<"cf_list_enabled">> => false
        },
        <<"fcnt">> => 1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
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
        ]
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
            <<"fcnt">> => 0,
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
            <<"mac">> => []
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
            <<"cf_list_enabled">> => false
        },
        <<"fcnt">> => 2,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
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
        ]
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
            <<"fcnt">> => 0,
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
            ]
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
            <<"cf_list_enabled">> => false
        },
        <<"fcnt">> => 3,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
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
        ]
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
            <<"mac">> => []
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
            <<"cf_list_enabled">> => false
        },
        <<"fcnt">> => 4,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
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
        ]
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
            <<"mac">> => []
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
