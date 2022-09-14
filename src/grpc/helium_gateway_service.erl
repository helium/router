-module(helium_gateway_service).

-behavior(helium_packet_router_gateway_bhvr).

-include("../grpc/autogen/server/packet_router_pb.hrl").
-include_lib("helium_proto/include/packet_pb.hrl").

-define(JOIN_REQUEST, 2#000).

-export([
    init/2,
    send_packet/2,
    handle_info/2
]).

-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(Rpc, Stream) ->
    Stream.

-spec send_packet(packet_router_pb:packet_router_packet_up_v1_pb(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
send_packet(PacketUp, StreamState) ->
    case verify(PacketUp) of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(2), <<"bad signature">>}};
        true ->
            SCPacket = to_sc_packet(PacketUp),
            {Time, _} = timer:tc(router_device_routing, handle_free_packet, [
                SCPacket, erlang:system_time(millisecond), self()
            ]),
            router_metrics:function_observe('router_device_routing:handle_free_packet', Time),
            {ok, StreamState}
    end.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({send_response, Reply}, StreamState) ->
    grpcbox_stream:send(false, from_sc_packet(Reply), StreamState);
handle_info(_Msg, StreamState) ->
    case application:get_env(router, packet_router_grpc_forward_unhandled_messages, undefined) of
        {Pid, Atom} when erlang:is_pid(Pid) andalso erlang:is_atom(Atom) -> Pid ! {Atom, _Msg};
        _ -> ok
    end,
    lager:info("~p got an unhandled message ~p", [self(), _Msg]),
    StreamState.

%% ------------------------------------------------------------------
%% Helper Functions
%% ------------------------------------------------------------------
-spec verify(Packet :: packet_router_pb:packet_router_packet_up_v1_pb()) -> boolean().
verify(Packet) ->
    try
        BasePacket = Packet#packet_router_packet_up_v1_pb{signature = <<>>},
        EncodedPacket = packet_router_pb:encode_msg(BasePacket),
        #packet_router_packet_up_v1_pb{
            signature = Signature,
            gateway = PubKeyBin
        } = Packet,
        PubKey = libp2p_crypto:bin_to_pubkey(PubKeyBin),
        libp2p_crypto:verify(EncodedPacket, Signature, PubKey)
    of
        Bool -> Bool
    catch
        _E:_R ->
            false
    end.

%% ===================================================================

-spec to_sc_packet(packet_router_pb:packet_router_packet_up_v1_pb()) ->
    router_pb:blockchain_state_channel_packet_v1_pb().
to_sc_packet(HprPacketUp) ->
    % Decompose uplink message
    #packet_router_packet_up_v1_pb{
        % signature = Signature
        payload = Payload,
        timestamp = Timestamp,
        rssi = SignalStrength,
        frequency_mhz = Frequency,
        datarate = DataRate,
        snr = SNR,
        region = Region,
        hold_time = HoldTime,
        gateway = Gateway
    } = HprPacketUp,

    Packet = blockchain_helium_packet_v1:new(
        lorawan,
        Payload,
        Timestamp,
        erlang:float(SignalStrength),
        Frequency,
        erlang:atom_to_list(DataRate),
        SNR,
        routing_information(Payload)
    ),
    blockchain_state_channel_packet_v1:new(Packet, Gateway, Region, HoldTime).

-spec routing_information(binary()) ->
    {devaddr, DevAddr :: non_neg_integer()}
    | {eui, DevEUI :: non_neg_integer(), AppEUI :: non_neg_integer()}.
routing_information(
    <<?JOIN_REQUEST:3, _:5, AppEUI:64/integer-unsigned-little, DevEUI:64/integer-unsigned-little,
        _/binary>>
) ->
    {eui, DevEUI, AppEUI};
routing_information(<<_FType:3, _:5, DevAddr:32/integer-unsigned-little, _/binary>>) ->
    % routing_information_pb{data = {devaddr, DevAddr}}.
    {devaddr, DevAddr}.

%% ===================================================================

-spec from_sc_packet(router_pb:blockchain_state_channel_response_v1_pb()) ->
    packet_router_db:packet_router_packet_down_v1_pb().
from_sc_packet(StateChannelResponse) ->
    Downlink = blockchain_state_channel_response_v1:downlink(StateChannelResponse),

    #packet_router_packet_down_v1_pb{
        payload = blockchain_helium_packet_v1:payload(Downlink),
        rx1 = #window_v1_pb{
            timestamp = blockchain_helium_packet_v1:timestamp(Downlink),
            frequency = blockchain_helium_packet_v1:frequency(Downlink),
            datarate = hpr_datarate(blockchain_helium_packet_v1:datarate(Downlink))
        },
        rx2 = rx2_window(blockchain_helium_packet_v1:rx2_window(Downlink))
    }.

-spec hpr_datarate(unicode:chardata()) ->
    packet_router_pb:'helium.data_rate'().
hpr_datarate(DataRateString) ->
    erlang:binary_to_existing_atom(unicode:characters_to_binary(DataRateString)).

-spec rx2_window(blockchain_helium_packet_v1:window()) ->
    undefined | packet_router_pb:window_v1_pb().
rx2_window(#window_pb{timestamp = RX2Timestamp, frequency = RX2Frequency, datarate = RX2Datarate}) ->
    #window_v1_pb{
        timestamp = RX2Timestamp,
        frequency = RX2Frequency,
        datarate = hpr_datarate(RX2Datarate)
    };
rx2_window(undefined) ->
    undefined.
