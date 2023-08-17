-module(test_utils).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    init_per_group/2,
    end_per_group/2,
    add_oui/1,
    start_swarm/3,
    get_device_channels_worker/1,
    get_channel_worker_event_manager/1,
    get_channel_worker_channels_map/1,
    get_channel_worker_device/1,
    get_channel_worker_backoff_map/1,
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
-include("../src/grpc/autogen/iot_config_pb.hrl").
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
    %% Clean up router_blockchain to avoid old chain from previous test
    _ = persistent_term:erase(router_blockchain),
    meck:new(router_device_devaddr, [passthrough]),
    meck:expect(router_device_devaddr, allocate, fun(_, _) ->
        DevAddrPrefix = router_utils:get_env_int(devaddr_prefix, $H),
        {ok, <<33554431:25/integer-unsigned-little, DevAddrPrefix:7/integer>>}
    end),

    BaseDir = io_lib:format("~p-~p", [TestCase, erlang:system_time(millisecond)]),
    ok = application:set_env(blockchain, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, device_rate_limit, 50),
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
                {lager_console_backend, [{module, router_test_ics_route_service}], debug},
                {lager_console_backend, [{module, router_ics_eui_worker_SUITE}], debug},
                {lager_console_backend, [{module, router_ics_route_get_euis_handler}], debug},
                {lager_console_backend, [{module, router_test_ics_skf_service}], debug},
                {lager_console_backend, [{module, router_ics_skf_worker_SUITE}], debug},
                {lager_console_backend, [{module, router_ics_skf_list_handler}], debug},
                {lager_console_backend, [{module, router_ics_gateway_location_worker_SUITE}],
                    debug},
                {lager_console_backend, [{module, router_test_ics_gateway_service}], debug},
                {{lager_file_backend, "router.log"}, [{application, router}], debug},
                {{lager_file_backend, "router.log"}, [{module, router_console_api}], debug},
                {{lager_file_backend, "router.log"}, [{module, router_device_routing}], debug},
                {{lager_file_backend, "device.log"}, [{device_id, <<"yolo_id">>}], debug},
                {{lager_file_backend, "router.log"}, [{module, console_callback}], debug},
                {
                    {lager_file_backend, "router.log"},
                    [{module, router_test_ics_route_service}],
                    debug
                },
                {
                    {lager_file_backend, "router.log"},
                    [{module, router_ics_eui_worker_SUITE}],
                    debug
                },
                {
                    {lager_file_backend, "router.log"},
                    [{module, router_ics_route_get_euis_handler}],
                    debug
                },
                {
                    {lager_file_backend, "router.log"},
                    [{module, router_test_ics_skf_service}],
                    debug
                },
                {
                    {lager_file_backend, "router.log"},
                    [{module, router_ics_skf_worker_SUITE}],
                    debug
                },
                {
                    {lager_file_backend, "router.log"},
                    [{module, router_ics_skf_list_handler}],
                    debug
                }
            ]);
        _ ->
            ok
    end,
    ok = router_test_ics_route_service:test_init(),
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

    SwarmKey = router_utils:get_swarm_key_location(),
    ok = filelib:ensure_dir(SwarmKey),
    {ok, RouterKeys} = libp2p_crypto:load_keys(SwarmKey),
    #{public := RouterPubKey, secret := RouterPrivKey} = RouterKeys,

    HotspotDir = BaseDir ++ "/hotspot",
    filelib:ensure_dir(HotspotDir),
    {HotspotSwarm, HotspotKeys} = ?MODULE:start_swarm(HotspotDir, TestCase, 0),
    #{public := HotspotPubKey, secret := HotspotPrivKey} = HotspotKeys,

    Config0 =
        case proplists:get_value(is_chain_dead, Config, false) of
            true ->
                Config;
            false ->
                {ok, _GenesisMembers, ConsensusMembers, _Keys} = blockchain_test_utils:init_chain(
                    5000,
                    [{RouterPrivKey, RouterPubKey}, {HotspotPrivKey, HotspotPubKey}]
                ),
                [{consensus_member, ConsensusMembers} | Config]
        end,

    ok = router_console_dc_tracker:refill(?CONSOLE_ORG_ID, 1, 100),

    [
        {app_key, AppKey},
        {ets, Tab},
        {elli, Pid},
        {base_dir, BaseDir},
        {swarm, HotspotSwarm},
        {keys, HotspotKeys}
        | Config0
    ].

end_per_testcase(_TestCase, Config) ->
    %% Clean up router_blockchain to avoid old chain from previous test
    _ = persistent_term:erase(router_blockchain),
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
    e2qc:teardown(devaddr_subnets_cache),
    e2qc:teardown(phash_to_device_cache),
    ok = application:stop(grpcbox),
    ok = application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    meck:unload(router_device_devaddr),
    ok.

init_per_group(chain_alive, Config) ->
    ok = application:set_env(
        router,
        is_chain_dead,
        false,
        [{persistent, true}]
    ),
    [{is_chain_dead, false} | Config];
init_per_group(chain_dead, Config) ->
    ok = application:set_env(
        router,
        is_chain_dead,
        true,
        [{persistent, true}]
    ),
    [{is_chain_dead, true} | Config];
init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, _Config) ->
    ok = application:set_env(
        router,
        is_chain_dead,
        false,
        [{persistent, true}]
    ),
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

add_oui(Config) ->
    case router_blockchain:is_chain_dead() of
        true ->
            Range1 = #iot_config_devaddr_range_v1_pb{
                route_id = "test_route_id",
                start_addr = binary:decode_unsigned(binary:decode_hex(<<"48000000">>)),
                end_addr = binary:decode_unsigned(binary:decode_hex(<<"48000007">>))
            },
            _ = erlang:spawn(router_test_ics_route_service, devaddr_ranges, [[Range1]]),
            % router_device_devaddr:set_devaddr_bases([{0, 8}]),
            [{oui, 1} | Config];
        false ->
            {ok, PubKey, SigFun, _} = blockchain_swarm:keys(),
            PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

            Chain = blockchain_worker:blockchain(),
            Ledger = blockchain:ledger(Chain),
            ConsensusMembers = proplists:get_value(consensus_member, Config),

            %% Create and submit OUI txn with an empty filter
            OUI = 1,
            {Filter, _} = xor16:to_bin(xor16:new([0], fun xxhash:hash64/1)),
            OUITxn = blockchain_txn_oui_v1:new(OUI, PubKeyBin, [PubKeyBin], Filter, 8),
            OUITxnFee = blockchain_txn_oui_v1:calculate_fee(OUITxn, Chain),
            OUITxnStakingFee = blockchain_txn_oui_v1:calculate_staking_fee(OUITxn, Chain),
            OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, OUITxnFee),
            OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, OUITxnStakingFee),

            SignedOUITxn = blockchain_txn_oui_v1:sign(OUITxn1, SigFun),

            ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI, Ledger)),

            {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
            _ = blockchain_test_utils:add_block(Block0, Chain, self(), blockchain_swarm:tid()),

            ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),
            [{oui, OUI} | Config]
    end.

join_device(Config) ->
    join_device(Config, #{}).

join_device(Config, JoinOpts) ->
    AppKey = proplists:get_value(app_key, Config),
    DevNonce = crypto:strong_rand_bytes(2),

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(
        libp2p_crypto:bin_to_b58(PubKeyBin)
    ),
    Stream =
        case router_blockchain:is_chain_dead() of
            false ->
                RouterSwarm = blockchain_swarm:swarm(),
                [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
                {ok, Stream0} = libp2p_swarm:dial_framed_stream(
                    Swarm,
                    Address,
                    router_handler_test:version(),
                    router_handler_test,
                    [self()]
                ),

                Stream0;
            true ->
                HotspotKeys = proplists:get_value(keys, Config),
                {ok, Stream0} = router_test_gateway:start(HotspotKeys#{forward => self()}),
                PubKeyBin0 = router_test_gateway:pubkey_bin(Stream0),
                ok = router_test_ics_gateway_service:register_gateway_location(
                    PubKeyBin0,
                    "8c29a962ed5b3ff"
                ),

                Stream0
        end,
    %% Send join packet
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
    {state, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt, _OUI,
        ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADREngine,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    ChannelsWorkerPid.

get_last_dev_nonce(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt, _OUI,
        _ChannelsWorkerPid, LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    LastDevNonce.

get_channel_worker_event_manager(DeviceID) ->
    ChannelWorkerPid = get_device_channels_worker(DeviceID),
    {state, EventManagerPid, _DeviceWorkerPid, _Device, _Channels, _ChannelsBackoffs, _DataCache} = sys:get_state(
        ChannelWorkerPid
    ),
    EventManagerPid.

get_channel_worker_channels_map(DeviceID) ->
    ChannelWorkerPid = get_device_channels_worker(DeviceID),
    {state, _EventManagerPid, _DeviceWorkerPid, _Device, Channels, _ChannelsBackoffs, _DataCache} = sys:get_state(
        ChannelWorkerPid
    ),
    Channels.

get_channel_worker_device(DeviceID) ->
    ChannelWorkerPid = get_device_channels_worker(DeviceID),
    {state, _EventManagerPid, _DeviceWorkerPid, Device, _Channels, _ChannelsBackoffs, _DataCache} = sys:get_state(
        ChannelWorkerPid
    ),
    Device.

get_channel_worker_backoff_map(DeviceID) ->
    ChannelWorkerPid = get_device_channels_worker(DeviceID),
    {state, _EventManagerPid, _DeviceWorkerPid, _Device, _Channels, ChannelsBackoffs, _DataCache} = sys:get_state(
        ChannelWorkerPid
    ),
    ChannelsBackoffs.

get_device_last_seen_fcnt(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, FCnt, _OUI,
        _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    FCnt.

get_device_worker_device(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _DB, _CF, _FrameTimeout, Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt, _OUI,
        _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    Device.

get_device_worker_offer_cache(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt, _OUI,
        _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, OfferCache, _ADRCache,
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
    Got =
        receive
            {console_event, Category, _, G} -> G
        after 4250 ->
            ct:fail("wait_for_console_event ~p timeout", [Category])
        end,
    try match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({wait_for_console_event, {category, Category}, Reason})
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event ~p stacktrace ~n~p", [Category, {_Reason, _Stacktrace}]),
            ct:fail({wait_for_console_event, {category, Category}, _Reason})
    end.

% "sub_category":
%   "undefined
%   | uplink_confirmed | uplink_unconfirmed | uplink_integration_req | uplink_integration_res | uplink_dropped
%   | downlink_confirmed | downlink_unconfirmed | downlink_dropped | downlink_queued | downlink_ack
%   | misc_integration_error"
wait_for_console_event_sub(SubCategory, #{<<"id">> := ExpectedUUID} = Expected) when
    erlang:is_binary(ExpectedUUID)
->
    Got =
        receive
            {console_event, _, SubCategory, #{<<"id">> := ExpectedUUID} = G} ->
                G
        after 4250 ->
            ct:fail("wait_for_console_event_sub (explicit id: ~p) ~p timeout", [
                ExpectedUUID,
                SubCategory
            ])
        end,

    try match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED: got: ~n~p~n~nexpected: ~n~p", [Got, Expected]),
            ct:fail({
                wait_for_console_event_sub,
                {sub_category, SubCategory},
                {expected_id, ExpectedUUID},
                Reason
            })
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event_sub (explicit id: ~p) ~p stacktrace ~n~p", [
                ExpectedUUID,
                SubCategory,
                {_Reason, _Stacktrace}
            ]),
            ct:fail({
                wait_for_console_event_sub,
                {sub_category, SubCategory},
                {expected_id, ExpectedUUID},
                _Reason
            })
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
            end;
        {router_test_gateway, _Pid, {data, EnvDown}} ->
            PacketDown = router_test_gateway:packet_from_env_down(EnvDown),
            Payload = router_test_gateway:payload_from_packet_down(PacketDown),
            ct:pal("packet ~p", [PacketDown]),
            Frame = deframe_join_packet(Payload, DevNonce, AppKey),
            ct:pal("Join response ~p", [Frame]),
            Frame
    after 1250 -> ct:fail("missing_join for")
    end.

wait_channel_data(Expected) ->
    Got =
        receive
            {channel_data, G} -> G
        after 1250 ->
            ct:fail("wait_channel_data timeout")
        end,
    try match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({wait_channel_data, Reason})
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_channel_data stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_channel_data failed caught ~p", [_Reason])
    end.

%% NOTE: Waiting for state channel messages is akin to waiting for downlink messages.
%% In a grpc world, there is no state channel involved. But these helpers have
%% been updated to listen for both libp2p and grpc downlink messages.
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
                end;
            {router_test_gateway, _PubKeyBin, {data, _EnvDown}} ->
                ok
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
                end;
            {router_test_gateway, PubKeyBin, {data, EnvDown}} ->
                PacketDown = router_test_gateway:packet_from_env_down(EnvDown),
                Payload = router_test_gateway:payload_from_packet_down(PacketDown),
                Frame = deframe_packet(Payload, AppSKey),
                {ok, Frame};
            {router_test_gateway, _PubKeyBin, {data, _EnvDown}} ->
                ct:print(
                    "got env_down, but with unexpected pubkey ~n"
                    "Expected: ~p~n"
                    "Got:      ~p",
                    [PubKeyBin, _PubKeyBin]
                ),
                ct:fail("unexpected env down")
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
                                assert_frame(Frame, FrameData, Type, FPending, Ack, Fport, FCnt),

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
                end;
            {router_test_gateway, _Pid, {data, EnvDown}} ->
                PacketDown = router_test_gateway:packet_from_env_down(EnvDown),
                Payload = router_test_gateway:payload_from_packet_down(PacketDown),
                Frame = deframe_packet(Payload, router_device:app_s_key(Device)),
                assert_frame(Frame, FrameData, Type, FPending, Ack, Fport, FCnt),
                {ok, Frame}
        after 1250 ->
            ct:print("wait_state_channel_message timeout for ~p", [Msg]),
            ct:fail("wait_state_channel_message timeout for ~p", [Msg])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_state_channel_message stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_state_channel_message failed")
    end.

assert_frame(Frame, FrameData, Type, FPending, Ack, Fport, FCnt) ->
    ?assertEqual(FrameData, Frame#frame.data),
    ?assertEqual(Type, Frame#frame.mtype),
    ?assertEqual(FPending, Frame#frame.fpending),
    ?assertEqual(Ack, Frame#frame.ack),
    ?assertEqual(Fport, Frame#frame.fport),
    ?assertEqual(FCnt, Frame#frame.fcnt).

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
                end;
            {router_test_gateway, _, {data, EnvDown}} ->
                Packet = router_test_gateway:sc_packet_from_env_down(EnvDown),
                {ok, Packet}
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
    RoutingInfo =
        {eui, binary:decode_unsigned(?DEVEUI), binary:decode_unsigned(?APPEUI)},
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
        region = Region,
        %% Match blockchain ct default hold_time from router_device_routing:handle_packet/4
        hold_time = 100
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
    Prefix = router_utils:get_env_int(devaddr_prefix, $H),
    DevAddr = maps:get(devaddr, Options, <<33554431:25/integer-unsigned-little, Prefix:7/integer>>),
    Payload1 = frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt, Options),
    <<DevNum:32/integer-unsigned-little>> = DevAddr,
    Routing = blockchain_helium_packet_v1:make_routing_info({devaddr, DevNum}),
    HeliumPacket = #packet_pb{
        type = lorawan,
        payload = Payload1,
        frequency = 923.3,
        datarate = maps:get(datarate, Options, "SF8BW125"),
        signal_strength = maps:get(rssi, Options, 0.0),
        snr = maps:get(snr, Options, 0.0),
        routing = Routing
    },
    Packet = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket,
        hotspot = PubKeyBin,
        region = maps:get(region, Options, 'US915'),
        %% Match blockchain ct default hold_time from router_device_routing:handle_packet/4
        hold_time = 100
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
    FOptsBin = lora_core:encode_fupopts(maps:get(fopts, Options, [])),
    FOptsLen = byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = maps:get(body, Options, <<1:8>>),
    Data = lorawan_utils:reverse(
        lorawan_utils:cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)
    ),
    <<FCntLow:16/integer-unsigned-little, _:16>> = <<FCnt:32/integer-unsigned-little>>,
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
            FOptsLen:4, FCntLow:16/little-unsigned-integer, FOptsBin:FOptsLen/binary,
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
    ESize = maps:size(Expected),
    GSize = maps:size(Got),
    case ESize == GSize of
        false ->
            Flavor =
                case ESize > GSize of
                    true -> {missing_keys, maps:keys(Expected) -- maps:keys(Got)};
                    false -> {extra_keys, maps:keys(Got) -- maps:keys(Expected)}
                end,
            {false, {size_mismatch, {expected, ESize}, {got, GSize}, Flavor}};
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
                    (K, V1, true) when is_float(V1) ->
                        case maps:get(K, Got, undefined) of
                            V2 when is_float(V2) ->
                                Diff = abs(V1 - V2) < 0.0001,
                                case Diff of
                                    true ->
                                        true;
                                    false ->
                                        {false,
                                            {float_outside_tolerance, K, {got, V2}, {expected, V1},
                                                {tolerance, 0.0001}, {difference, Diff}}}
                                end
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

-spec deframe_packet(#packet_pb{} | binary(), binary()) -> #frame{}.
deframe_packet(#packet_pb{payload = Payload}, SessionKey) ->
    deframe_packet(Payload, SessionKey);
deframe_packet(Payload, SessionKey) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, ADR:1, RFU:1, ACK:1, FPending:1, FOptsLen:4,
        FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Payload,
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

deframe_join_packet(#packet_pb{payload = Payload}, DevNonce, AppKey) ->
    deframe_join_packet(Payload, DevNonce, AppKey);
deframe_join_packet(
    <<MType:3, _MHDRRFU:3, _Major:2, EncPayload/binary>> = _Payload,
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
