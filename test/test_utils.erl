-module(test_utils).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    start_swarm/3,
    get_device_channels_worker/1,
    get_channel_worker_event_manager/1,
    get_device_last_seen_fcnt/1,
    get_last_dev_nonce/1,
    get_device_worker_device/1,
    get_device_worker_offer_cache/1,
    get_device_queue/1,
    force_refresh_channels/1,
    ignore_messages/0,
    wait_for_console_event/2,
    wait_for_console_event_sub/2,
    wait_for_join_resp/3,
    wait_channel_data/1,
    wait_state_channel_message/1,
    wait_state_channel_message/2,
    wait_state_channel_message/3,
    wait_state_channel_message/8,
    wait_organizations_burned/1,
    wait_state_channel_packet/1,
    join_payload/2,
    join_packet/3, join_packet/4,
    join_device/1, join_device/2,
    frame_payload/6,
    frame_packet/5, frame_packet/6,
    deframe_packet/2,
    deframe_join_packet/3,
    tmp_dir/0, tmp_dir/1,
    wait_until/1, wait_until/3,
    wait_until_no_messages/1,
    is_jsx_encoded_map/1,
    ws_init/0
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").
-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

init_per_testcase(TestCase, Config) ->
    meck:new(router_device_devaddr, [passthrough]),
    meck:expect(router_device_devaddr, allocate, fun(_, _) ->
        DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
        {ok, <<33554431:25/integer-unsigned-little, DevAddrPrefix:7/integer>>}
    end),

    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(blockchain, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, testing, true),
    ok = application:set_env(router, router_console_api, [
        {endpoint, ?CONSOLE_URL},
        {downlink_endpoint, ?CONSOLE_URL},
        {ws_endpoint, ?CONSOLE_WS_URL},
        {secret, <<>>}
    ]),
    FormatStr = [
        "[",
        date,
        " ",
        time,
        "] ",
        pid,
        " [",
        severity,
        "]",
        {device_id, [" [", device_id, "]"], ""},
        " [",
        {module, ""},
        {function, [":", function], ""},
        {line, [":", line], ""},
        "] ",
        message,
        "\n"
    ],
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    ok = application:set_env(lager, crash_log, "crash.log"),
    case os:getenv("CT_LAGER", "NONE") of
        "DEBUG" ->
            ok = application:set_env(lager, handlers, [
                {lager_console_backend, [
                    {level, error},
                    {formatter_config, FormatStr}
                ]},
                {lager_file_backend, [
                    {file, "router.log"},
                    {level, error},
                    {formatter_config, FormatStr}
                ]},
                {lager_file_backend, [
                    {file, "device.log"},
                    {level, error},
                    {formatter_config, FormatStr}
                ]}
            ]),
            ok = application:set_env(lager, traces, [
                {lager_console_backend, [{application, router}], debug},
                {lager_console_backend, [{module, router_console_api}], debug},
                {lager_console_backend, [{module, router_device_routing}], debug},
                {lager_console_backend, [{module, console_callback}], debug},
                {{lager_file_backend, "router.log"}, [{application, router}], debug},
                {{lager_file_backend, "router.log"}, [{module, router_console_api}], debug},
                {{lager_file_backend, "router.log"}, [{module, router_device_routing}], debug},
                {{lager_file_backend, "device.log"}, [{device_id, <<"yolo_id">>}], debug},
                {{lager_file_backend, "router.log"}, [{module, console_callback}], debug}
            ]);
        _ ->
            ok
    end,
    Tab = ets:new(TestCase, [public, set]),
    AppKey = crypto:strong_rand_bytes(16),
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
    application:ensure_all_started(gun),

    {ok, _} = application:ensure_all_started(router),

    SwarmKey = filename:join([
        application:get_env(blockchain, base_dir, "data"),
        "blockchain",
        "swarm_key"
    ]),
    ok = filelib:ensure_dir(SwarmKey),
    {ok, RouterKeys} = libp2p_crypto:load_keys(SwarmKey),
    #{public := RouterPubKey, secret := RouterPrivKey} = RouterKeys,

    HotspotDir = BaseDir ++ "/hotspot",
    filelib:ensure_dir(HotspotDir),
    {HotspotSwarm, HotspotKeys} = ?MODULE:start_swarm(HotspotDir, TestCase, 0),
    #{public := HotspotPubKey, secret := HotspotPrivKey} = HotspotKeys,

    {ok, _GenesisMembers, ConsensusMembers, _Keys} = blockchain_test_utils:init_chain(
        5000,
        [{RouterPrivKey, RouterPubKey}, {HotspotPrivKey, HotspotPubKey}]
    ),

    ok = router_console_dc_tracker:refill(?CONSOLE_ORG_ID, 1, 100),

    [
        {app_key, AppKey},
        {ets, Tab},
        {elli, Pid},
        {base_dir, BaseDir},
        {swarm, HotspotSwarm},
        {keys, HotspotKeys},
        {consensus_member, ConsensusMembers}
        | Config
    ].

end_per_testcase(_TestCase, Config) ->
    catch libp2p_swarm:stop(proplists:get_value(swarm, Config)),
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(500),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    e2qc:teardown(router_console_api_get_devices_by_deveui_appeui),
    e2qc:teardown(router_console_api_get_org),
    application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    meck:unload(router_device_devaddr),
    ok.

start_swarm(BaseDir, Name, Port) ->
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := PrivKey, public := PubKey} = Keys,
    Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)},
    SwarmOpts = [
        {base_dir, BaseDir ++ "/" ++ erlang:atom_to_list(Name) ++ "_data"},
        {key, Key},
        {libp2p_group_gossip, [{seed_nodes, []}]},
        {libp2p_nat, [{enabled, false}]},
        {libp2p_proxy, [{limit, 1}]}
    ],
    {ok, Swarm} = libp2p_swarm:start(Name, SwarmOpts),
    libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/" ++ erlang:integer_to_list(Port)),
    ct:pal("created swarm ~p @ ~p p2p address=~p", [Name, Swarm, libp2p_swarm:p2p_address(Swarm)]),
    {Swarm, Keys}.

join_device(Config) ->
    join_device(Config, #{}).

join_device(Config, JoinOpts) ->
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
    SCPacket = ?MODULE:join_packet(
        PubKeyBin,
        AppKey,
        DevNonce,
        maps:put(dont_encode, true, JoinOpts)
    ),
    Stream !
        {send,
            blockchain_state_channel_v1_pb:encode_msg(#blockchain_state_channel_message_v1_pb{
                msg = {packet, SCPacket}
            })},

    timer:sleep(router_utils:join_timeout()),

    %% Waiting for report device status on that join request
    ?MODULE:wait_for_console_event(<<"join_request">>, #{
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
            <<"raw_packet">> => base64:encode(
                blockchain_helium_packet_v1:payload(
                    blockchain_state_channel_packet_v1:packet(SCPacket)
                )
            ),
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
            }
        }
    }),

    %% Waiting for report device status on that join request
    ?MODULE:wait_for_console_event(<<"join_accept">>, #{
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
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => fun erlang:is_integer/1,
                <<"snr">> => 0.0,
                <<"spreading">> => fun erlang:is_binary/1,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),
    #{
        app_key => AppKey,
        dev_nonce => DevNonce,
        hotspot_name => HotspotName,
        stream => Stream,
        pubkey_bin => PubKeyBin
    }.

get_device_channels_worker(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt,
        _OUI, ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADREngine,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    ChannelsWorkerPid.

get_last_dev_nonce(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt,
        _OUI, _ChannelsWorkerPid, LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    LastDevNonce.

get_channel_worker_event_manager(DeviceID) ->
    ChannelWorkerPid = get_device_channels_worker(DeviceID),
    {state, _Chain, EventManagerPid, _DeviceWorkerPid, _Device, _Channels, _ChannelsBackoffs,
        _DataCache} = sys:get_state(ChannelWorkerPid),
    EventManagerPid.

get_device_last_seen_fcnt(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, FCnt,
        _OUI, _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    FCnt.

get_device_worker_device(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt,
        _OUI, _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    Device.

get_device_worker_offer_cache(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt,
        _OUI, _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    OfferCache.

get_device_queue(DeviceID) ->
    Device = ?MODULE:get_device_worker_device(DeviceID),
    router_device:queue(Device).

force_refresh_channels(DeviceID) ->
    Pid = get_device_channels_worker(DeviceID),
    Pid ! refresh_channels,
    timer:sleep(250),
    ok.

ignore_messages() ->
    receive
        Msg ->
            ct:pal("ignored message: ~p~n", [Msg]),
            ?MODULE:ignore_messages()
    after 2000 -> ok
    end.

% "category": "uplink | downlink | misc"
wait_for_console_event(Category, #{<<"id">> := ExpectedUUID} = Expected) when
    erlang:is_binary(ExpectedUUID)
->
    try
        receive
            {console_event, Category, _, #{<<"id">> := ExpectedUUID} = Got} ->
                case match_map(Expected, Got) of
                    true ->
                        {ok, Got};
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_for_console_event (explicit id) ~p data failed ~p", [
                            Category,
                            Reason
                        ])
                end
        after 4250 -> ct:fail("wait_for_console_event (explicit id) ~p timeout", [Category])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event (explicit id) ~p stacktrace ~n~p", [
                Category,
                {_Reason, _Stacktrace}
            ]),
            ct:fail("wait_for_console_event (explicit id) ~p failed", [Category])
    end;
wait_for_console_event(Category, Expected) ->
    try
        receive
            {console_event, Category, _, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        {ok, Got};
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_for_console_event ~p data failed ~p", [Category, Reason])
                end
        after 4250 -> ct:fail("wait_for_console_event ~p timeout", [Category])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event ~p stacktrace ~n~p", [Category, {_Reason, _Stacktrace}]),
            ct:fail("wait_for_console_event ~p failed", [Category])
    end.

% "sub_category":
%   "undefined
%   | uplink_confirmed | uplink_unconfirmed | uplink_integration_req | uplink_integration_res | uplink_dropped
%   | downlink_confirmed | downlink_unconfirmed | downlink_dropped | downlink_queued | downlink_ack
%   | misc_integration_error"
wait_for_console_event_sub(SubCategory, #{<<"id">> := ExpectedUUID} = Expected) when
    erlang:is_binary(ExpectedUUID)
->
    try
        receive
            {console_event, _, SubCategory, #{<<"id">> := ExpectedUUID} = Got} ->
                case match_map(Expected, Got) of
                    true ->
                        {ok, Got};
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail(
                            "wait_for_console_event_sub (explicit id: ~p) ~p data failed ~n~p",
                            [
                                ExpectedUUID,
                                SubCategory,
                                Reason
                            ]
                        )
                end
        after 4250 ->
            ct:fail("wait_for_console_event_sub (explicit id: ~p) ~p timeout", [
                ExpectedUUID,
                SubCategory
            ])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event_sub (explicit id: ~p) ~p stacktrace ~n~p", [
                ExpectedUUID,
                SubCategory,
                {_Reason, _Stacktrace}
            ]),
            ct:fail("wait_for_console_event_sub (explicit id: ~p) ~p failed", [
                ExpectedUUID,
                SubCategory
            ])
    end;
wait_for_console_event_sub(SubCategory, Expected) ->
    try
        receive
            {console_event, _, SubCategory, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        {ok, Got};
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_for_console_event_sub ~p data failed ~p", [
                            SubCategory,
                            Reason
                        ])
                end
        after 4250 -> ct:fail("wait_for_console_event_sub ~p timeout", [SubCategory])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event_sub ~p stacktrace ~n~p", [
                SubCategory,
                {_Reason, _Stacktrace}
            ]),
            ct:fail("wait_for_console_event_sub ~p failed", [SubCategory])
    end.

wait_for_join_resp(PubKeyBin, AppKey, DevNonce) ->
    receive
        {client_data, PubKeyBin, Data} ->
            try
                blockchain_state_channel_v1_pb:decode_msg(
                    Data,
                    blockchain_state_channel_message_v1_pb
                )
            of
                #blockchain_state_channel_message_v1_pb{msg = {response, Resp}} ->
                    #blockchain_state_channel_response_v1_pb{accepted = true, downlink = Packet} =
                        Resp,
                    ct:pal("packet ~p", [Packet]),
                    Frame = deframe_join_packet(Packet, DevNonce, AppKey),
                    ct:pal("Join response ~p", [Frame]),
                    Frame
            catch
                _:_ ->
                    ct:fail("invalid join response")
            end
    after 1250 -> ct:fail("missing_join for")
    end.

wait_channel_data(Expected) ->
    try
        receive
            {channel_data, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        {ok, Got};
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_channel_data failed ~p", [Reason])
                end
        after 1250 -> ct:fail("wait_channel_data timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_channel_data stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_channel_data failed caught ~p", [_Reason])
    end.

wait_state_channel_message(Timeout) ->
    wait_state_channel_message(Timeout, undefined).

wait_state_channel_message(Timeout, PubKeyBin) ->
    try
        receive
            {client_data, PubKeyBin, Data} ->
                try
                    blockchain_state_channel_v1_pb:decode_msg(
                        Data,
                        blockchain_state_channel_message_v1_pb
                    )
                of
                    #blockchain_state_channel_message_v1_pb{msg = {response, Resp}} ->
                        #blockchain_state_channel_response_v1_pb{accepted = true} = Resp,
                        ok;
                    _Else ->
                        ct:fail("wait_state_channel_message wrong message ~p ", [_Else])
                catch
                    _E:_R ->
                        ct:fail("wait_state_channel_message failed to decode ~p ~p", [
                            Data,
                            {_E, _R}
                        ])
                end
        after Timeout -> ct:fail("wait_state_channel_message timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_state_channel_message stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_state_channel_message failed")
    end.

wait_state_channel_message(Timeout, PubKeyBin, AppSKey) ->
    try
        receive
            {client_data, PubKeyBin, Data} ->
                try
                    blockchain_state_channel_v1_pb:decode_msg(
                        Data,
                        blockchain_state_channel_message_v1_pb
                    )
                of
                    #blockchain_state_channel_message_v1_pb{msg = {response, Resp}} ->
                        case Resp of
                            #blockchain_state_channel_response_v1_pb{
                                accepted = true,
                                downlink = undefined
                            } ->
                                wait_state_channel_message(Timeout, PubKeyBin, AppSKey);
                            #blockchain_state_channel_response_v1_pb{
                                accepted = true,
                                downlink = Packet
                            } ->
                                {ok, deframe_packet(Packet, AppSKey)}
                        end;
                    _Else ->
                        ct:fail("wait_state_channel_message with frame wrong message ~p ", [_Else])
                catch
                    _E:_R ->
                        ct:fail("wait_state_channel_message with frame failed to decode ~p ~p", [
                            Data,
                            {_E, _R}
                        ])
                end
        after Timeout -> ct:fail("wait_state_channel_message with frame timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_state_channel_message with frame stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_state_channel_message with frame failed")
    end.

wait_state_channel_message(Msg, Device, FrameData, Type, FPending, Ack, Fport, FCnt) ->
    try
        receive
            {client_data, undefined, Data} ->
                try
                    blockchain_state_channel_v1_pb:decode_msg(
                        Data,
                        blockchain_state_channel_message_v1_pb
                    )
                of
                    #blockchain_state_channel_message_v1_pb{msg = {response, Resp}} ->
                        case Resp of
                            #blockchain_state_channel_response_v1_pb{
                                accepted = true,
                                downlink = undefined
                            } ->
                                wait_state_channel_message(
                                    Msg,
                                    Device,
                                    FrameData,
                                    Type,
                                    FPending,
                                    Ack,
                                    Fport,
                                    FCnt
                                );
                            #blockchain_state_channel_response_v1_pb{
                                accepted = true,
                                downlink = Packet
                            } ->
                                ct:pal("wait_state_channel_message packet ~p", [Packet]),
                                Frame = deframe_packet(Packet, router_device:app_s_key(Device)),
                                ct:pal("~p", [lager:pr(Frame, ?MODULE)]),
                                ?assertEqual(FrameData, Frame#frame.data),
                                %% we queued an unconfirmed packet
                                ?assertEqual(Type, Frame#frame.mtype),
                                ?assertEqual(FPending, Frame#frame.fpending),
                                ?assertEqual(Ack, Frame#frame.ack),
                                ?assertEqual(Fport, Frame#frame.fport),
                                ?assertEqual(FCnt, Frame#frame.fcnt),
                                {ok, Frame}
                        end;
                    _Else ->
                        ct:fail("wait_state_channel_message wrong message ~p for ~p", [_Else, Msg])
                catch
                    _E:_R ->
                        ct:fail("wait_state_channel_message failed to decode ~p ~p for ~p", [
                            Data,
                            {_E, _R},
                            Msg
                        ])
                end
        after 1250 -> ct:fail("wait_state_channel_message timeout for ~p", [Msg])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_state_channel_message stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_state_channel_message failed")
    end.

wait_state_channel_packet(Timeout) ->
    try
        receive
            {client_data, _, Data} ->
                try
                    blockchain_state_channel_v1_pb:decode_msg(
                        Data,
                        blockchain_state_channel_message_v1_pb
                    )
                of
                    #blockchain_state_channel_message_v1_pb{msg = {response, Resp}} ->
                        case Resp of
                            #blockchain_state_channel_response_v1_pb{
                                accepted = true,
                                downlink = Packet
                            } ->
                                {ok, Packet};
                            _ ->
                                {error, Resp}
                        end;
                    _Else ->
                        ct:fail("wait_state_channel_packet with frame wrong message ~p ", [_Else])
                catch
                    _E:_R ->
                        ct:fail("wait_state_channel_packet with frame failed to decode ~p ~p", [
                            Data,
                            {_E, _R}
                        ])
                end
        after Timeout -> ct:fail("wait_state_channel_packet with frame timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_state_channel_packet with frame stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_state_channel_packet with frame failed")
    end.

wait_organizations_burned(Expected) ->
    try
        receive
            {organizations_burned, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_organizations_burned failed ~p", [Reason])
                end
        after 1250 -> ct:fail("wait_organizations_burned timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_organizations_burned stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_organizations_burned failed")
    end.

join_packet(PubKeyBin, AppKey, DevNonce) ->
    join_packet(PubKeyBin, AppKey, DevNonce, #{}).

join_packet(PubKeyBin, AppKey, DevNonce, Options) ->
    %% THIS IS WRONG
    RoutingInfo = {devaddr, 1},
    RSSI = maps:get(rssi, Options, 0),
    HeliumPacket = blockchain_helium_packet_v1:new(
        lorawan,
        join_payload(AppKey, DevNonce),
        1000,
        RSSI,
        923.3,
        <<"SF8BW125">>,
        0.0,
        RoutingInfo
    ),
    Region = maps:get(region, Options, 'US915'),
    Packet = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket,
        hotspot = PubKeyBin,
        region = Region
    },
    case maps:get(dont_encode, Options, false) of
        true ->
            Packet;
        false ->
            Msg = #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}},
            blockchain_state_channel_v1_pb:encode_msg(Msg)
    end.

join_payload(AppKey, DevNonce) ->
    MType = ?JOIN_REQ,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = lorawan_utils:reverse(?APPEUI),
    DevEUI = lorawan_utils:reverse(?DEVEUI),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:macN(cmac, aes_128_cbc, AppKey, Payload0, 4),
    <<Payload0/binary, MIC:4/binary>>.

frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt) ->
    frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt, #{}).

frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt, Options) ->
    DevAddr = maps:get(devaddr, Options, <<33554431:25/integer-unsigned-little, $H:7/integer>>),
    Payload1 = frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt, Options),
    Routing =
        case maps:get(routing, Options, false) of
            true ->
                <<DevNum:32/integer-unsigned-little>> = DevAddr,
                blockchain_helium_packet_v1:make_routing_info({devaddr, DevNum});
            false ->
                undefined
        end,
    HeliumPacket = #packet_pb{
        type = lorawan,
        payload = Payload1,
        frequency = 923.3,
        datarate = maps:get(datarate, Options, <<"SF8BW125">>),
        signal_strength = maps:get(rssi, Options, 0.0),
        snr = maps:get(snr, Options, 0.0),
        routing = Routing
    },
    Packet = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket,
        hotspot = PubKeyBin,
        region = maps:get(region, Options, 'US915')
    },
    case maps:get(dont_encode, Options, false) of
        true ->
            Packet;
        false ->
            Msg = #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}},
            blockchain_state_channel_v1_pb:encode_msg(Msg)
    end.

frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt, Options) ->
    OptionsBoolToBit = fun(Key) ->
        case maps:get(Key, Options, false) of
            true -> 1;
            false -> 0
        end
    end,
    MHDRRFU = 0,
    Major = 0,
    ADR = OptionsBoolToBit(wants_adr),
    ADRACKReq = OptionsBoolToBit(wants_adr_ack),
    ACK = OptionsBoolToBit(wants_ack),
    RFU = 0,
    FOptsBin = lorawan_mac_commands:encode_fupopts(maps:get(fopts, Options, [])),
    FOptsLen = byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = maps:get(body, Options, <<1:8>>),
    Data = lorawan_utils:reverse(
        lorawan_utils:cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)
    ),
    FCntSize = maps:get(fcnt_size, Options, 16),
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
            FOptsLen:4, FCnt:FCntSize/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = router_utils:b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:macN(cmac, aes_128_cbc, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    <<Payload0/binary, MIC:4/binary>>.

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory to be used as a scratch by eunit tests
%% @end
%%-------------------------------------------------------------------
tmp_dir() ->
    os:cmd("mkdir -p " ++ ?BASE_TMP_DIR),
    create_tmp_dir(?BASE_TMP_DIR_TEMPLATE).

tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        {fail, _Reason} = Fail ->
            Fail;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

wait_until_no_messages(Pid) ->
    wait_until(fun() ->
        case erlang:process_info(Pid, message_queue_len) of
            {message_queue_len, 0} ->
                true;
            {message_queue_len, N} ->
                {messages_still_in_queue, N}
        end
    end).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec match_map(map(), any()) -> true | {false, term()}.
match_map(Expected, Got) when is_map(Got) ->
    case maps:size(Expected) == maps:size(Got) of
        false ->
            {false, {size_mismatch, maps:size(Expected), maps:size(Got)}};
        true ->
            maps:fold(
                fun
                    (_K, _V, {false, _} = Acc) ->
                        Acc;
                    (K, V, true) when is_function(V) ->
                        case V(maps:get(K, Got, undefined)) of
                            true ->
                                true;
                            false ->
                                {false, {value_predicate_failed, K, maps:get(K, Got, undefined)}}
                        end;
                    (K, '_', true) ->
                        case maps:is_key(K, Got) of
                            true -> true;
                            false -> {false, {missing_key, K}}
                        end;
                    (K, V, true) when is_map(V) ->
                        case match_map(V, maps:get(K, Got, #{})) of
                            true -> true;
                            Err -> {false, {key, K, Err}}
                        end;
                    (K, V0, true) when is_list(V0) ->
                        V1 = lists:zip(lists:seq(1, erlang:length(V0)), lists:sort(V0)),
                        G0 = maps:get(K, Got, []),
                        G1 = lists:zip(lists:seq(1, erlang:length(G0)), lists:sort(G0)),
                        case match_map(maps:from_list(V1), maps:from_list(G1)) of
                            true -> true;
                            Err -> {false, {key, K, Err}}
                        end;
                    (K, V, true) ->
                        case maps:get(K, Got, undefined) of
                            V -> true;
                            _ -> {false, {value_mismatch, K, V, maps:get(K, Got, undefined)}}
                        end
                end,
                true,
                Expected
            )
    end;
match_map(_Expected, _Got) ->
    {false, not_map}.

-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path) ->
    nonl(os:cmd("mktemp -d " ++ Path)).

nonl([$\n | T]) -> nonl(T);
nonl([H | T]) -> [H | nonl(T)];
nonl([]) -> [].

deframe_packet(Packet, SessionKey) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, ADR:1, RFU:1, ACK:1, FPending:1, FOptsLen:4,
        FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary,
        PayloadAndMIC/binary>> = Packet#packet_pb.payload,
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    Data = lorawan_utils:reverse(
        lorawan_utils:cipher(FRMPayload, SessionKey, MType band 1, DevAddr, FCnt)
    ),
    ct:pal("FOpts ~p", [FOpts]),
    #frame{
        mtype = MType,
        devaddr = DevAddr,
        adr = ADR,
        rfu = RFU,
        ack = ACK,
        fpending = FPending,
        fcnt = FCnt,
        fopts = lorawan_mac_commands:parse_fdownopts(FOpts),
        fport = FPort,
        data = Data
    }.

deframe_join_packet(
    #packet_pb{payload = <<MType:3, _MHDRRFU:3, _Major:2, EncPayload/binary>>},
    DevNonce,
    AppKey
) when MType == ?JOIN_ACCEPT ->
    ct:pal("Enc join ~w", [EncPayload]),
    Payload = crypto:crypto_one_time(aes_128_ecb, AppKey, EncPayload, true),
    {AppNonce, NetID, DevAddr, DLSettings, RxDelay, MIC, CFList} =
        case Payload of
            <<AN:3/binary, NID:3/binary, DA:4/binary, DL:8/integer-unsigned, RxD:8/integer-unsigned,
                M:4/binary>> ->
                CFL = <<>>,
                {AN, NID, DA, DL, RxD, M, CFL};
            <<AN:3/binary, NID:3/binary, DA:4/binary, DL:8/integer-unsigned, RxD:8/integer-unsigned,
                CFL:16/binary, M:4/binary>> ->
                {AN, NID, DA, DL, RxD, M, CFL}
        end,
    ct:pal("Dec join ~w", [Payload]),
    %{?APPEUI, ?DEVEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
    MIC = crypto:macN(cmac, aes_128_cbc, AppKey, <<MType:3, _MHDRRFU:3, _Major:2, Msg/binary>>, 4),
    NetID = <<"He2">>,
    NwkSKey = crypto:crypto_one_time(
        aes_128_ecb,
        AppKey,
        lorawan_utils:padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>),
        true
    ),
    AppSKey = crypto:crypto_one_time(
        aes_128_ecb,
        AppKey,
        lorawan_utils:padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>),
        true
    ),
    {NetID, DevAddr, DLSettings, RxDelay, NwkSKey, AppSKey, CFList}.

%%%-------------------------------------------------------------------
%% @doc
%%
%% `jsx:encode/1' turns proplists into maps, but empty proplists into arrays.
%% There are times empty "maps" are what we expect, but they're proplists before
%% they hit the api boundary.
%%
%% @end
%% %-------------------------------------------------------------------
-spec is_jsx_encoded_map(map() | list()) -> boolean().
is_jsx_encoded_map([]) -> true;
is_jsx_encoded_map(M) when is_map(M) -> true;
is_jsx_encoded_map(_) -> false.

-spec ws_init() -> {ok, pid()}.
ws_init() ->
    receive
        {websocket_init, Pid} ->
            {ok, Pid}
    after 2500 -> ct:fail(websocket_init_timeout)
    end.
