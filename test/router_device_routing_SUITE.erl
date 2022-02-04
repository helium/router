-module(router_device_routing_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    bad_fcnt_test/1,
    multi_buy_test/1,
    packet_hash_cache_test/1
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
        bad_fcnt_test,
        multi_buy_test,
        packet_hash_cache_test
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

packet_hash_cache_test(Config) ->
    %% -------------------------------------------------------------------
    %% Hotspots
    #{public := PubKey0} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin0 = libp2p_crypto:pubkey_to_bin(PubKey0),
    {ok, _HotspotName0} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin0)),

    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    {ok, _HotspotName1} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    %% -------------------------------------------------------------------
    %% Device
    #{} = test_utils:join_device(Config),
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Change name of devices
    Device1 = router_device:update([{name, <<"new-name-1">>}], Device0),
    Device2 = router_device:update([{name, <<"new-name-2">>}], Device1),
    {ok, _} = router_device_cache:save(Device1),
    %% NOTE: purposefully not putting device-2 in the cache
    %% {ok, Device2} = router_device_cache:save(Device2),

    ?assertEqual(
        router_device:devaddr(Device0),
        router_device:devaddr(Device1),
        "all devices have same devaddr"
    ),
    ?assertEqual(
        router_device:devaddr(Device1),
        router_device:devaddr(Device2),
        "all devices have same devaddr"
    ),

    %% -------------------------------------------------------------------
    %% "make me an offer I cannot refuse" - Sufjan Stevens (right?)
    NwkSessionKey = router_device:nwk_s_key(Device2),
    AppSessionKey = router_device:app_s_key(Device2),
    SCPacket = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin0,
        NwkSessionKey,
        AppSessionKey,
        0,
        #{dont_encode => true, routing => true}
    ),
    Offer = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket),
        blockchain_state_channel_packet_v1:hotspot(SCPacket),
        blockchain_state_channel_packet_v1:region(SCPacket)
    ),
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),

    %% -------------------------------------------------------------------
    %% Query for devices
    Chain = blockchain_worker:blockchain(),
    DevAddr = router_device:devaddr(Device1),

    %% make sure things go wrong first
    ?assertNotEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin0, Chain)
    ),
    ?assertNotEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin1, Chain)
    ),

    %% make it better
    router_device_routing:cache_device_for_hash(PHash, Device2),

    %% now we should go right
    ?assertEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin0, Chain)
    ),
    ?assertEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin1, Chain)
    ),

    %% go back to nothing
    router_device_routing:force_evict_packet_hash(PHash),

    %% back to being wrong, and it feels so right
    ?assertNotEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin0, Chain)
    ),
    ?assertNotEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin1, Chain)
    ),

    ok.

multi_buy_test(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),

    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    Keys = proplists:get_value(keys, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    ConsensusMembers = proplists:get_value(consensus_member, Config),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),
    PubKeyBin1 = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    %% Inserting OUI into chain for routing
    OUI1 = 1,
    {Filter, _} = xor16:to_bin(xor16:new([0], fun xxhash:hash64/1)),
    OUITxn = blockchain_txn_oui_v1:new(OUI1, PubKeyBin1, [PubKeyBin1], Filter, 8),
    OUITxnFee = blockchain_txn_oui_v1:calculate_fee(OUITxn, Chain),
    OUITxnStakingFee = blockchain_txn_oui_v1:calculate_staking_fee(OUITxn, Chain),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, OUITxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, OUITxnStakingFee),

    #{secret := PrivKey} = Keys,
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    SignedOUITxn = blockchain_txn_oui_v1:sign(OUITxn1, SigFun),

    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
    _ = blockchain_test_utils:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    %% device should join under OUI 1
    %% Send join packet
    DevNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin1, AppKey, DevNonce)},
    timer:sleep(router_utils:join_timeout()),

    %% Waiting for report device status on that join request
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
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
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

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Hotspot 2
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    {ok, _HotspotName2} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin2)),

    %% Hotspot 3
    #{public := PubKey3} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin3 = libp2p_crypto:pubkey_to_bin(PubKey3),
    {ok, _HotspotName3} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin3)),

    %% Hotspot 4
    #{public := PubKey4} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin4 = libp2p_crypto:pubkey_to_bin(PubKey4),
    {ok, _HotspotName4} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin4)),

    %% Hotspot 5
    #{public := PubKey5} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin5 = libp2p_crypto:pubkey_to_bin(PubKey5),
    {ok, _HotspotName5} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin5)),

    HandleOfferForHotspotFun = fun(PubKeyBin, Device, FCnt) ->
        SCPacket = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            router_device:nwk_s_key(Device),
            router_device:app_s_key(Device),
            FCnt,
            #{dont_encode => true, routing => true, devaddr => router_device:devaddr(Device)}
        ),
        Offer = blockchain_state_channel_offer_v1:from_packet(
            blockchain_state_channel_packet_v1:packet(SCPacket),
            blockchain_state_channel_packet_v1:hotspot(SCPacket),
            blockchain_state_channel_packet_v1:region(SCPacket)
        ),
        router_device_routing:handle_offer(Offer, self())
    end,

    %% Multi buy for device is set to 2
    Device1 = router_device:metadata(
        maps:merge(router_device:metadata(Device0), #{multi_buy => 2}),
        Device0
    ),
    {ok, Device2} = router_device:save(DB, CF, Device1),
    {ok, _} = router_device_cache:save(Device2),

    %% Send the same packet from all hotspots
    ok = HandleOfferForHotspotFun(PubKeyBin1, Device2, 0),
    ok = HandleOfferForHotspotFun(PubKeyBin2, Device2, 0),
    {error, multi_buy_max_packet} = HandleOfferForHotspotFun(PubKeyBin3, Device2, 0),
    {error, multi_buy_max_packet} = HandleOfferForHotspotFun(PubKeyBin4, Device2, 0),

    %% Change multi-buy to 4
    Device3 = router_device:metadata(
        maps:merge(router_device:metadata(Device0), #{multi_buy => 4}),
        Device0
    ),
    {ok, Device4} = router_device:save(DB, CF, Device3),
    {ok, _} = router_device_cache:save(Device3),

    %% Send the same packet from all hotspots
    ok = HandleOfferForHotspotFun(PubKeyBin1, Device4, 1),
    ok = HandleOfferForHotspotFun(PubKeyBin2, Device4, 1),
    ok = HandleOfferForHotspotFun(PubKeyBin3, Device4, 1),
    ok = HandleOfferForHotspotFun(PubKeyBin4, Device4, 1),
    {error, multi_buy_max_packet} = HandleOfferForHotspotFun(PubKeyBin5, Device4, 1),

    ok.

bad_fcnt_test(Config) ->
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

    FCnt = 65535 - 20,
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                FCnt,
                #{fcnt_size => 16}
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
        <<"fcnt">> => FCnt,
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

    %% Waiting for report channel status from HTTP channel
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

    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                FCnt + 100,
                #{fcnt_size => 32}
            )},

    test_utils:wait_until(fun() ->
        {error, not_found} == router_device:get_by_id(DB, CF, WorkerID) andalso
            {error, not_found} == router_device_cache:get(WorkerID)
    end),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
