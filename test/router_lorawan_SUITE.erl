-module(router_lorawan_SUITE).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").

-export([
    groups/0,
    all/0,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([lw_join_test/1]).

-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0, 0, 0, 0, 0, 0, 0, 0>>).
-define(DEVEUI, <<16#EF, 16#BE, 16#AD, 16#DE, 16#EF, 16#BE, 16#AD, 16#DE>>).
-define(ETS, suite_config).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

groups() ->
    [
        {'US915', [], [lw_join_test]},
        {'EU868', [], [lw_join_test]},
        {'CN470', [], [lw_join_test]},
        {'AS923_1', [], [lw_join_test]},
        {'AS923_2', [], [lw_join_test]},
        {'AS923_3', [], [lw_join_test]},
        {'AS923_4', [], [lw_join_test]}
    ].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        {group, 'US915'},
        {group, 'EU868'},
        {group, 'CN470'},
        {group, 'AS923_1'},
        {group, 'AS923_2'},
        {group, 'AS923_3'},
        {group, 'AS923_4'}
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_group(RegionGroup, Config) ->
    [{region, RegionGroup} | Config].

end_per_group(_, _) ->
    ok.

init_per_testcase(TestCase, Config) ->
    meck:new(router_device_devaddr, [passthrough]),
    meck:expect(router_device_devaddr, allocate, fun(_, _) ->
        DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
        {ok, <<33554431:25/integer-unsigned-little, DevAddrPrefix:7/integer>>}
    end),
    BaseDir =
        erlang:atom_to_list(TestCase) ++
            "-" ++ erlang:atom_to_list(proplists:get_value(region, Config)),
    ok = application:set_env(blockchain, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, router_console_api, [
        {endpoint, ?CONSOLE_URL},
        {downlink_endpoint, ?CONSOLE_URL},
        {ws_endpoint, ?CONSOLE_WS_URL},
        {secret, <<>>}
    ]),
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    Tab = ets:new(?ETS, [public, set]),
    AppKey =
        <<16#2B, 16#7E, 16#15, 16#16, 16#28, 16#AE, 16#D2, 16#A6, 16#AB, 16#F7, 16#15, 16#88, 16#09,
            16#CF, 16#4F, 16#3C>>,
    ElliOpts = [
        {callback, console_callback},
        {callback_args, #{
            forward => self(),
            ets => Tab,
            app_key => AppKey,
            app_eui => ?APPEUI,
            dev_eui => ?DEVEUI
        }},
        {port, 3000}
    ],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),

    {Swarm, Keys} = test_utils:start_swarm(BaseDir, TestCase, 0),
    #{public := PubKey, secret := PrivKey} = Keys,
    {ok, _GenesisMembers, _ConsensusMembers, _Keys} = blockchain_test_utils:init_chain(
        5000,
        [{PrivKey, PubKey}]
    ),

    ok = router_console_dc_tracker:refill(?CONSOLE_ORG_ID, 1, 100),

    [{app_key, AppKey}, {ets, Tab}, {elli, Pid}, {base_dir, BaseDir}, {swarm, Swarm} | Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    libp2p_swarm:stop(proplists:get_value(swarm, Config)),
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(500),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    catch exit(whereis(libp2p_swarm_sup_join_test_swarm_0), kill),
    meck:unload(router_device_devaddr),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

lw_join_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm0, _} = test_utils:start_swarm(BaseDir, join_test_swarm_0, 3620),
    ct:pal("registered ~p", [registered()]),
    Swarm0 = whereis(libp2p_swarm_sup_join_test_swarm_0),
    Region = proplists:get_value(region, Config),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),
    {ok, Stream0} = libp2p_swarm:dial_framed_stream(
        Swarm0,
        Address,
        router_lorawan_handler_test:version(),
        router_lorawan_handler_test,
        [self(), PubKeyBin0, Region]
    ),
    receive
        {client_data, _, _Data3} ->
            ct:fail("join didn't fail")
    after 0 -> ok
    end,

    %% Send join packet
    DevNonce = <<5, 0>>,
    receive
        joining -> ok
    after 5000 -> ct:fail("Joining failed")
    end,
    receive
        joined -> ok
    after 5000 -> ct:fail("Joined failed")
    end,

    {ok, HotspotName0} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin0)),
    test_utils:wait_for_console_event(<<"join_request">>, #{
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
                <<"rssi">> => -35.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF7BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => '_',
                <<"long">> => '_'
            }
        }
    }),

    %% Waiting for reply resp form router
    {_NetID, _DevAddr, _DLSettings, _RxDelay, NwkSKey, AppSKey, CFList} = test_utils:wait_for_join_resp(
        PubKeyBin0,
        AppKey,
        DevNonce
    ),
    case Region of
        'US915' ->
            %% US915 defaults cflist on joins to off
            ?assertEqual(CFList, <<>>);
        _ ->
            ?assertEqual(CFList, lorawan_mac_region:mk_join_accept_cf_list(Region, 0))
    end,

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    NwkSKey = router_device:nwk_s_key(Device0),
    AppSKey = router_device:app_s_key(Device0),

    Channel = router_channel:new(
        <<"fake_lorawan_channel">>,
        fake_lorawan,
        <<"fake_lorawan_channel">>,
        #{},
        0,
        self()
    ),
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Msg1 = #downlink{
        confirmed = true,
        port = 2,
        payload = <<"some">>,
        channel = Channel
    },
    router_device_worker:queue_message(WorkerPid, Msg1),
    Msg2 = #downlink{confirmed = false, port = 55, payload = <<"data">>, channel = Channel},
    router_device_worker:queue_message(WorkerPid, Msg2),

    receive
        rx -> ok
    after 1000 -> ct:fail("nothing received from device")
    end,

    %% Waiting for data from HTTP channel
    {ok, #{<<"hotspots">> := [#{<<"frequency">> := Frequency}]}} = test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => fun erlang:is_map/1,
        <<"fcnt">> => 1,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => base64:encode(<<0>>),
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"port">> => 2,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                <<"name">> => erlang:list_to_binary(HotspotName0),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => -35.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF7BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => '_',
                <<"long">> => '_'
            }
        ]
    }),

    %% Waiting for report channel status from console downlink
    test_utils:wait_for_console_event_sub(<<"downlink_confirmed">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_confirmed">>,
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
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                <<"name">> => erlang:list_to_binary(HotspotName0),
                <<"rssi">> => lorawan_mac_region:downlink_signal_strength(Region, Frequency),
                <<"snr">> => 0.0,
                <<"spreading">> => fun erlang:is_binary/1,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => '_',
                <<"long">> => '_'
            },
            <<"integration">> => #{
                <<"id">> => <<"fake_lorawan_channel">>,
                <<"name">> => <<"fake_lorawan_channel">>,
                <<"status">> => <<"success">>
            },
            <<"mac">> => fun erlang:is_list/1
        }
    }),

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
                <<"dc">> => #{<<"balance">> => 98, <<"nonce">> => 1, <<"used">> => 1},
                <<"fcnt">> => fun erlang:is_integer/1,
                <<"payload_size">> => fun erlang:is_integer/1,
                <<"payload">> => fun erlang:is_binary/1,
                <<"raw_packet">> => fun erlang:is_binary/1,
                <<"port">> => fun erlang:is_integer/1,
                <<"devaddr">> => fun erlang:is_binary/1,
                <<"hotspot">> => #{
                    <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                    <<"name">> => erlang:list_to_binary(HotspotName0),
                    <<"rssi">> => -35.0,
                    <<"snr">> => 0.0,
                    <<"spreading">> => <<"SF7BW125">>,
                    <<"frequency">> => fun erlang:is_float/1,
                    <<"channel">> => fun erlang:is_number/1,
                    <<"lat">> => '_',
                    <<"long">> => '_'
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

    test_utils:wait_state_channel_message(router_utils:frame_timeout() + 250, PubKeyBin0),

    receive
        rx -> ok
    after 1000 -> ct:fail("nothing received from device")
    end,
    timer:sleep(2000),

    %% Waiting for data from HTTP channel
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
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 2,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => base64:encode(<<0>>),
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"port">> => 2,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                <<"name">> => erlang:list_to_binary(HotspotName0),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => -35.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF7BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => '_',
                <<"long">> => '_'
            }
        ]
    }),

    %% Waiting for report channel status from HTTP channel
    {ok, #{<<"id">> := UplinkUUID2}} = test_utils:wait_for_console_event_sub(
        <<"uplink_confirmed">>,
        #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"uplink">>,
            <<"sub_category">> => <<"uplink_confirmed">>,
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
                    <<"rssi">> => -35.0,
                    <<"snr">> => 0.0,
                    <<"spreading">> => <<"SF7BW125">>,
                    <<"frequency">> => fun erlang:is_float/1,
                    <<"channel">> => fun erlang:is_number/1,
                    <<"lat">> => '_',
                    <<"long">> => '_'
                },
                <<"mac">> => fun erlang:is_list/1,
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
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                <<"name">> => erlang:list_to_binary(HotspotName0),
                <<"rssi">> => lorawan_mac_region:downlink_signal_strength(Region, Frequency),
                <<"snr">> => '_',
                <<"spreading">> => fun erlang:is_binary/1,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => '_',
                <<"long">> => '_'
            }
        }
    }),

    test_utils:wait_state_channel_message(router_utils:frame_timeout() + 250, PubKeyBin0),

    Stream0 ! get_channel_mask,
    receive
        {channel_mask, Mask} ->
            case Region of
                'US915' ->
                    ExpectedMask = lists:seq(8, 15),
                    Mask = ExpectedMask;
                _ ->
                    ct:pal("Mask is ~p", [Mask]),
                    ok
            end
    after 100 -> ct:fail("channel mask not corrected")
    end,

    %% check the device got our downlink
    receive
        {tx, 2, true, <<"some">>} -> ok
    after 5000 ->
        Buf =
            receive
                {tx, _, _, _} = Any -> Any
            after 0 -> nothing
            end,
        ct:fail("device did not see downlink 1 ~p ", [Buf])
    end,
    receive
        {tx, 55, false, <<"data">>} -> ok
    after 5000 -> ct:fail("device did not see downlink 2")
    end,

    libp2p_swarm:stop(Swarm0),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
