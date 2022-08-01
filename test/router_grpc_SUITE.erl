-module(router_grpc_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    join_grpc_test/1,
    join_from_unknown_device_grpc_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

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
        join_from_unknown_device_grpc_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    %% setup test dirs
    Config0 = test_utils:init_per_testcase(TestCase, Config),
    Config0.

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
    {ok, PubKey, SigFun, _} = blockchain_swarm:keys(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),

    {ok, #{msg := {response, ResponseMsg}} = Result, #{headers := Headers, trailers := _Trailers}} = helium_router_client:route(
        join_packet_map(PubKeyBin, SigFun, AppKey, JoinNonce, -40)
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg, ResponseMsg#{accepted := true}),

    ok.

%% send a packet from an unknown device
%% we will fail to get a response
join_from_unknown_device_grpc_test(_Config) ->
    {ok, PubKey, SigFun, _} = blockchain_swarm:keys(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    BadAppKey = crypto:strong_rand_bytes(16),

    {error, {_ErrorCode, ResponseMsg}, #{headers := Headers, trailers := _Trailers}} = helium_router_client:route(
        join_packet_map(PubKeyBin, SigFun, BadAppKey, JoinNonce, -40)
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [ResponseMsg]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg, <<"no response">>),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

join_packet_map(PubKeyBin, SigFun, AppKey, DevNonce, RSSI) ->
    RoutingInfo = {devaddr, 1},
    PacketMap = #{
        oui => 0,
        type => lorawan,
        payload => test_utils:join_payload(AppKey, DevNonce),
        timestamp => 1000,
        signal_strength => RSSI,
        frequency => 923.3,
        datarate => <<"SF8BW125">>,
        snr => 0.0,
        routing => #{data => RoutingInfo},
        rx2_window => undefined
    },
    SCPacketMap0 = #{
        packet => PacketMap,
        hotspot => PubKeyBin,
        region => 'US915',
        hold_time => 100
    },
    Signature = signature(SCPacketMap0, SigFun),
    PacketMap1 = maps:put(signature, Signature, SCPacketMap0),
    #{msg => {packet, PacketMap1}}.

signature(SCPacketMap, SigFun) ->
    #{
        packet := #{
            type := Type,
            payload := Payload,
            timestamp := Timestamp,
            signal_strength := RSSI,
            frequency := Frequency,
            datarate := DataRate,
            snr := SNR,
            routing := #{data := RoutingInfo}
        },
        hotspot := Hotspot,
        region := Region,
        hold_time := HoldTime
    } = SCPacketMap,
    Packet = blockchain_helium_packet_v1:new(
        Type, Payload, Timestamp, RSSI, Frequency, DataRate, SNR, RoutingInfo
    ),
    SCPacket = blockchain_state_channel_packet_v1:new(Packet, Hotspot, Region, HoldTime),
    SignedSCPacket = blockchain_state_channel_packet_v1:sign(SCPacket, SigFun),
    blockchain_state_channel_packet_v1:signature(SignedSCPacket).
