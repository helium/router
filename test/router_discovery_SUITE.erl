-module(router_discovery_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([disovery_test/1, fail_to_connect_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("helium_proto/include/discovery_pb.hrl").
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
    [disovery_test, fail_to_connect_test].

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

disovery_test(Config) ->
    DiscoFrameTimeout = timer:seconds(3),
    application:set_env(router, disco_frame_timeout, DiscoFrameTimeout),

    %% Setup stream stuff
    HotspotSwarm = proplists:get_value(swarm, Config),
    libp2p_swarm:add_stream_handler(
        HotspotSwarm,
        router_discovery_handler:version(),
        {router_discovery_handler_test, server, [self()]}
    ),
    [HotspotListenAddress | _] = libp2p_swarm:listen_addrs(HotspotSwarm),
    {ok, _} = libp2p_swarm:connect(blockchain_swarm:swarm(), HotspotListenAddress),
    test_utils:wait_until(fun() ->
        case
            libp2p_swarm:connect(blockchain_swarm:swarm(), libp2p_swarm:p2p_address(HotspotSwarm))
        of
            {ok, _} -> true;
            _ -> false
        end
    end),

    #{secret := HotspotPrivKey, public := HotspotPubKey} = proplists:get_value(keys, Config),
    SigFun = libp2p_crypto:mk_sig_fun(HotspotPrivKey),
    HotspotPubKeyBin = libp2p_crypto:pubkey_to_bin(HotspotPubKey),
    HotspotB58Bin = erlang:list_to_binary(libp2p_crypto:bin_to_b58(HotspotPubKeyBin)),
    TxnID1 = 1,
    Sig = SigFun(HotspotB58Bin),
    EncodedSig = base64:encode(Sig),
    Map1 = #{
        <<"hotspot">> => HotspotB58Bin,
        <<"transaction_id">> => TxnID1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"signature">> => EncodedSig
    },

    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,

    %% Start discovery process
    WSPid ! {discovery, Map1},

    %% Make sure that data is deliverd to hotspot
    DiscoveryData1 =
        receive
            {router_discovery_handler_test, Bin1} ->
                #discovery_start_pb{
                    hotspot = HotspotPubKeyBin,
                    signature = EncodedSig
                } = discovery_pb:decode_msg(Bin1, discovery_start_pb)
        after 5000 -> ct:fail(router_discovery_handler_test_timeout)
        end,

    %% Setup to send rcved packet
    RouterSwarm = blockchain_swarm:swarm(),
    [RouterAddress | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        HotspotSwarm,
        RouterAddress,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),

    ?assertEqual(10, erlang:length(DiscoveryData1#discovery_start_pb.packets)),
    [Payload1 | _] = DiscoveryData1#discovery_start_pb.packets,

    HeliumPacket1 = #packet_pb{
        type = lorawan,
        payload = Payload1,
        frequency = 923.3,
        datarate = <<"SF8BW125">>,
        signal_strength = 0.0,
        snr = 0.0,
        routing = undefined
    },
    Packet1 = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket1,
        hotspot = HotspotPubKeyBin,
        region = 'US915'
    },
    SCMsg1 = #blockchain_state_channel_message_v1_pb{msg = {packet, Packet1}},
    blockchain_state_channel_v1_pb:encode_msg(SCMsg1),
    Stream ! {send, blockchain_state_channel_v1_pb:encode_msg(SCMsg1)},

    timer:sleep(DiscoFrameTimeout),

    %% Make sure that we got our txn id in the payload
    Body1 = jsx:encode(#{txn_id => TxnID1, error => 0}),
    test_utils:wait_channel_data(#{
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => true
        },
        <<"fcnt">> => 1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => base64:encode(Body1),
        <<"payload_size">> => erlang:byte_size(Body1),
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(HotspotPubKeyBin)),
                <<"name">> => erlang:list_to_binary(
                    blockchain_utils:addr2name(HotspotPubKeyBin)
                ),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => 100,
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

    [_, Payload2 | _] = DiscoveryData1#discovery_start_pb.packets,

    HeliumPacket2 = #packet_pb{
        type = lorawan,
        payload = Payload2,
        frequency = 923.3,
        datarate = <<"SF8BW125">>,
        signal_strength = 0.0,
        snr = 0.0,
        routing = undefined
    },
    Packet2 = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket2,
        hotspot = HotspotPubKeyBin,
        region = 'US915'
    },
    SCMsg2 = #blockchain_state_channel_message_v1_pb{msg = {packet, Packet2}},
    blockchain_state_channel_v1_pb:encode_msg(SCMsg2),
    Stream ! {send, blockchain_state_channel_v1_pb:encode_msg(SCMsg2)},

    timer:sleep(DiscoFrameTimeout),

    %% Make sure that we got our txn id in the payload
    test_utils:wait_channel_data(#{
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => true
        },
        <<"fcnt">> => 2,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => base64:encode(Body1),
        <<"payload_size">> => erlang:byte_size(Body1),
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(HotspotPubKeyBin)),
                <<"name">> => erlang:list_to_binary(
                    blockchain_utils:addr2name(HotspotPubKeyBin)
                ),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => 100,
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

    %% Restart process one more to make sure device worker behaves correctly
    TxnID3 = 3,
    Map3 = #{
        <<"hotspot">> => HotspotB58Bin,
        <<"transaction_id">> => TxnID3,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"signature">> => EncodedSig
    },

    WSPid ! {discovery, Map3},

    DiscoveryData3 =
        receive
            {router_discovery_handler_test, Bin3} ->
                #discovery_start_pb{
                    hotspot = HotspotPubKeyBin,
                    signature = EncodedSig
                } = discovery_pb:decode_msg(Bin3, discovery_start_pb)
        after 5000 -> ct:fail(router_discovery_handler_test_timeout)
        end,

    [Payload3 | _] = DiscoveryData3#discovery_start_pb.packets,
    HeliumPacket3 = #packet_pb{
        type = lorawan,
        payload = Payload3,
        frequency = 923.3,
        datarate = <<"SF8BW125">>,
        signal_strength = 0.0,
        snr = 0.0,
        routing = undefined
    },
    Packet3 = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket3,
        hotspot = HotspotPubKeyBin,
        region = 'US915'
    },
    SCMsg3 = #blockchain_state_channel_message_v1_pb{msg = {packet, Packet3}},
    blockchain_state_channel_v1_pb:encode_msg(SCMsg3),
    Stream ! {send, blockchain_state_channel_v1_pb:encode_msg(SCMsg3)},

    timer:sleep(DiscoFrameTimeout),

    Body3 = jsx:encode(#{txn_id => TxnID3, error => 0}),
    test_utils:wait_channel_data(#{
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => true
        },
        <<"fcnt">> => 1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => base64:encode(Body3),
        <<"payload_size">> => erlang:byte_size(Body3),
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(HotspotPubKeyBin)),
                <<"name">> => erlang:list_to_binary(blockchain_utils:addr2name(HotspotPubKeyBin)),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => 100,
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

    ok.

fail_to_connect_test(Config) ->
    application:set_env(router, disco_frame_timeout, 400),

    HotspotSwarm = proplists:get_value(swarm, Config),
    libp2p_swarm:add_stream_handler(
        HotspotSwarm,
        router_discovery_handler:version(),
        {router_discovery_handler_test, server, [self()]}
    ),

    #{secret := HotspotPrivKey, public := HotspotPubKey} = proplists:get_value(keys, Config),
    SigFun = libp2p_crypto:mk_sig_fun(HotspotPrivKey),
    HotspotPubKeyBin = libp2p_crypto:pubkey_to_bin(HotspotPubKey),
    HotspotB58Bin = erlang:list_to_binary(libp2p_crypto:bin_to_b58(HotspotPubKeyBin)),
    TxnID1 = 1,
    Sig = SigFun(HotspotB58Bin),
    EncodedSig = base64:encode(Sig),
    Map1 = #{
        <<"hotspot">> => HotspotB58Bin,
        <<"transaction_id">> => TxnID1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"signature">> => EncodedSig
    },

    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,

    %% Start discovery process
    WSPid ! {discovery, Map1},

    %% This can take time as we will retry 10 times
    timer:sleep(12000),

    Body1 = jsx:encode(#{txn_id => TxnID1, error => 1}),
    test_utils:wait_channel_data(#{
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
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => true
        },
        <<"fcnt">> => 1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => base64:encode(Body1),
        <<"payload_size">> => erlang:byte_size(Body1),
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(HotspotPubKeyBin)),
                <<"name">> => erlang:list_to_binary(
                    blockchain_utils:addr2name(HotspotPubKeyBin)
                ),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => 1,
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

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
