-module(router_grpc_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    join_grpc_test/1,
    join_grpc_gateway_test/1,
    join_from_unknown_device_grpc_test/1,
    join_from_unknown_device_grpc_gateway_test/1,
    packet_from_known_device_no_downlink/1,
    packet_from_known_device_no_downlink_gateway_test/1
]).

-include_lib("eunit/include/eunit.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").
-include("../src/grpc/autogen/packet_router_pb.hrl").
-include("../src/grpc/autogen/router_pb.hrl").

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
        join_grpc_test,
        join_grpc_gateway_test,
        join_from_unknown_device_grpc_test,
        join_from_unknown_device_grpc_gateway_test,
        packet_from_known_device_no_downlink,
        packet_from_known_device_no_downlink_gateway_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    ok = application:set_env(router, is_chain_dead, true, [{persistent, true}]),
    test_utils:init_per_testcase(TestCase, [{is_chain_dead, true} | Config]).
%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%% send a packet from a known device
%% verify we get a response
join_grpc_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    {PubKey, SigFun, _} = router_blockchain:get_key(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),

    {ok, #blockchain_state_channel_message_v1_pb{msg = {response, ResponseMsg}} = Result, #{
        headers := Headers, trailers := _Trailers
    }} = helium_router_client:route(
        join_packet(PubKeyBin, SigFun, AppKey, JoinNonce, -40)
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg, ResponseMsg#blockchain_state_channel_response_v1_pb{accepted = true}),

    ok.

join_grpc_gateway_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    {PubKey, SigFun, _} = router_blockchain:get_key(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% create a client stream
    {ok, Stream} = helium_packet_router_packet_client:route(ctx:new()),
    ct:print("stream: ~p", [Stream]),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),

    Packet = #packet_router_packet_up_v1_pb{
        payload = test_utils:join_payload(AppKey, JoinNonce),
        timestamp = 620124,
        rssi = 112,
        frequency = 903900024,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway = PubKeyBin,
        signature = <<>>
    },
    Signed = Packet#packet_router_packet_up_v1_pb{
        signature = SigFun(packet_router_pb:encode_msg(Packet))
    },
    EnvUp = #envelope_up_v1_pb{data = {packet, Signed}},
    ok = grpcbox_client:send(Stream, EnvUp),

    timer:sleep(router_utils:join_timeout()),
    {ok, DownlinkMsg} = grpcbox_client:recv_data(Stream),
    ct:print("downlink: ~p", [DownlinkMsg]),

    ok.

%% send a packet from an unknown device
%% we will fail to get a response
join_from_unknown_device_grpc_test(_Config) ->
    {PubKey, SigFun, _} = router_blockchain:get_key(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    BadAppKey = crypto:strong_rand_bytes(16),

    {error, {_ErrorCode, ResponseMsg}, #{headers := Headers, trailers := _Trailers}} = helium_router_client:route(
        join_packet(PubKeyBin, SigFun, BadAppKey, JoinNonce, -40)
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [ResponseMsg]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg, <<"not_found">>),

    ok.

join_from_unknown_device_grpc_gateway_test(_Config) ->
    ok = application:set_env(
        router,
        packet_router_grpc_forward_unhandled_messages,
        {self(), grpc_forward}
    ),

    %% create a client stream
    {ok, Stream} = helium_packet_router_packet_client:route(ctx:new()),
    ct:print("stream: ~p", [Stream]),

    {PubKey, SigFun, _} = router_blockchain:get_key(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    BadAppKey = crypto:strong_rand_bytes(16),

    Packet = #packet_router_packet_up_v1_pb{
        payload = test_utils:join_payload(BadAppKey, JoinNonce),
        timestamp = 620124,
        rssi = 112,
        frequency = 903900024,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway = PubKeyBin,
        signature = <<>>
    },
    Signed = Packet#packet_router_packet_up_v1_pb{
        signature = SigFun(packet_router_pb:encode_msg(Packet))
    },
    EnvUp = #envelope_up_v1_pb{data = {packet, Signed}},
    ok = grpcbox_client:send(Stream, EnvUp),

    timer:sleep(router_utils:join_timeout()),
    %% no downlink should be returned
    ?assertEqual(timeout, grpcbox_client:recv_data(Stream)),

    %% we get forwarded the error for testing
    ok =
        receive
            {grpc_forward, {error, not_found}} -> ok
        after timer:seconds(2) -> ct:fail(expected_msg_timeout)
        end,

    ok.

packet_from_known_device_no_downlink(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    {PubKey, SigFun, _} = router_blockchain:get_key(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),

    {ok, #blockchain_state_channel_message_v1_pb{msg = {response, ResponseMsg}}, #{
        headers := Headers, trailers := _Trailers
    }} = helium_router_client:route(
        join_packet(PubKeyBin, SigFun, AppKey, JoinNonce, -40)
    ),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg, ResponseMsg#blockchain_state_channel_response_v1_pb{accepted = true}),

    %% We are joined
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send first packet to get CFList response
    timer:sleep(router_utils:frame_timeout()),
    {ok, #blockchain_state_channel_message_v1_pb{msg = {response, Resp0}}, #{headers := Headers1}} = helium_router_client:route(
        data_packet_map(
            ?UNCONFIRMED_UP,
            1,
            PubKeyBin,
            Device,
            SigFun,
            #{}
        )
    ),

    #{<<":status">> := HttpStatus1} = Headers1,
    ?assertEqual(HttpStatus1, <<"200">>),
    ?assertEqual(Resp0, Resp0#blockchain_state_channel_response_v1_pb{accepted = true}),

    %% Send another uplink now that we have our cflist, confirming the change, we expect no downlink
    timer:sleep(router_utils:frame_timeout()),
    {ok, #blockchain_state_channel_message_v1_pb{msg = {response, Resp1}}, #{}} = helium_router_client:route(
        data_packet_map(
            ?UNCONFIRMED_UP,
            2,
            PubKeyBin,
            Device,
            SigFun,
            #{fopts => [{link_adr_ans, 1, 1, 1}]}
        )
    ),

    ?assertEqual(
        #blockchain_state_channel_response_v1_pb{
            accepted = true, downlink = undefined
        },
        Resp1
    ),

    ok.

packet_from_known_device_no_downlink_gateway_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    {PubKey, SigFun, _} = router_blockchain:get_key(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% create client stream
    {ok, Stream} = helium_packet_router_packet_client:route(ctx:new()),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Packet = #packet_router_packet_up_v1_pb{
        payload = test_utils:join_payload(AppKey, JoinNonce),
        timestamp = 620124,
        rssi = 112,
        frequency = 903900024,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway = PubKeyBin,
        signature = <<>>
    },
    Signed = Packet#packet_router_packet_up_v1_pb{
        signature = SigFun(packet_router_pb:encode_msg(Packet))
    },
    EnvUp0 = #envelope_up_v1_pb{data = {packet, Signed}},
    ok = grpcbox_client:send(Stream, EnvUp0),

    timer:sleep(router_utils:join_timeout()),
    {ok, _JoinAcceptDownlinkMsg} = grpcbox_client:recv_data(Stream),

    %% We are joined
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device} = router_device:get_by_id(DB, CF, WorkerID),

    %% create an unconfirmed uplink
    DevAddr = <<33554431:25/integer-unsigned-little, $H:7/integer>>,
    DataPacket1 = #packet_router_packet_up_v1_pb{
        payload = test_utils:frame_payload(
            ?UNCONFIRMED_UP,
            DevAddr,
            router_device:nwk_s_key(Device),
            router_device:app_s_key(Device),
            1,
            #{}
        ),
        timestamp = 620124,
        rssi = 112,
        frequency = 903900024,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway = PubKeyBin,
        signature = <<>>
    },
    DataSigned1 = DataPacket1#packet_router_packet_up_v1_pb{
        signature = SigFun(packet_router_pb:encode_msg(DataPacket1))
    },
    %% Send first packet to get CFList response
    EnvUp1 = #envelope_up_v1_pb{data = {packet, DataSigned1}},
    ok = grpcbox_client:send(Stream, EnvUp1),

    timer:sleep(router_utils:frame_timeout()),
    {ok, Downlink1} = grpcbox_client:recv_data(Stream),
    ct:print("DataRes1 recv: ~p", [Downlink1]),

    %% Send another uplink now that we have our cflist, confirming the change, we expect no downlink
    DataPacket2 = #packet_router_packet_up_v1_pb{
        payload = test_utils:frame_payload(
            ?UNCONFIRMED_UP,
            DevAddr,
            router_device:nwk_s_key(Device),
            router_device:app_s_key(Device),
            2,
            #{fopts => [{link_adr_ans, 1, 1, 1}]}
        ),
        timestamp = 620124,
        rssi = 112,
        frequency = 903900024,
        datarate = 'SF10BW125',
        snr = 5.5,
        region = 'US915',
        hold_time = 0,
        gateway = PubKeyBin,
        signature = <<>>
    },
    DataSigned2 = DataPacket2#packet_router_packet_up_v1_pb{
        signature = SigFun(packet_router_pb:encode_msg(DataPacket2))
    },
    EnvUp3 = #envelope_up_v1_pb{data = {packet, DataSigned2}},
    ok = grpcbox_client:send(Stream, EnvUp3),

    timer:sleep(router_utils:frame_timeout()),
    %% Expect no downlink
    ?assertEqual(timeout, grpcbox_client:recv_data(Stream)),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

join_packet(PubKeyBin, SigFun, AppKey, DevNonce, RSSI) ->
    RoutingInfo = {devaddr, 1},
    Packet = #packet_pb{
        oui = 0,
        type = lorawan,
        payload = test_utils:join_payload(AppKey, DevNonce),
        timestamp = 1000,
        signal_strength = RSSI,
        frequency = 923.3,
        datarate = <<"SF8BW125">>,
        snr = 0.0,
        routing = #routing_information_pb{data = RoutingInfo},
        rx2_window = undefined
    },
    SCPacket = #blockchain_state_channel_packet_v1_pb{
        packet = Packet,
        hotspot = PubKeyBin,
        region = 'US915',
        hold_time = 100
    },
    SignedSCPacket = blockchain_state_channel_packet_v1:sign(SCPacket, SigFun),
    #blockchain_state_channel_message_v1_pb{msg = {packet, SignedSCPacket}}.

data_packet_map(MType, Fcnt, PubKeyBin, Device, SigFun, Options) ->
    DevAddr0 = <<33554431:25/integer-unsigned-little, $H:7/integer>>,
    <<DevAddr:32/integer-unsigned-little>> = DevAddr0,
    P = #packet_pb{
        oui = 0,
        type = lorawan,
        timestamp = 1000,
        signal_strength = -40,
        frequency = 923.3,
        datarate = <<"SF8BW125">>,
        snr = 0.0,
        routing = #routing_information_pb{data = {devaddr, DevAddr}},
        rx2_window = undefined,
        %%
        payload = test_utils:frame_payload(
            MType,
            DevAddr0,
            router_device:nwk_s_key(Device),
            router_device:app_s_key(Device),
            Fcnt,
            Options
        )
    },
    SCPacket = #blockchain_state_channel_packet_v1_pb{
        packet = P, hotspot = PubKeyBin, region = 'US915', hold_time = 100
    },
    SignedSCPacket = blockchain_state_channel_packet_v1:sign(SCPacket, SigFun),
    #blockchain_state_channel_message_v1_pb{msg = {packet, SignedSCPacket}}.
