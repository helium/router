-module(router_test_gateway).

-behaviour(gen_server).

-include("../src/grpc/autogen/packet_router_pb.hrl").
-include_lib("helium_proto/include/packet_pb.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/1,
    pubkey_bin/1,
    send_packet/2,
    receive_send_packet/1,
    receive_env_down/1,
    packet_up_from_sc_packet/1,
    sc_packet_from_env_down/1,
    packet_from_env_down/1,
    payload_from_packet_down/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(SEND_PACKET, send).

-record(state, {
    forward :: pid(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: libp2p_crypto:sig_fun(),
    stream :: grpcbox_client:stream()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%%% API Function Definitions
%% ------------------------------------------------------------------

-spec start(Args :: map()) -> any().
start(Args) ->
    gen_server:start(?SERVER, Args, []).

-spec pubkey_bin(Pid :: pid()) -> libp2p_crypto:pubkey_bin().
pubkey_bin(Pid) ->
    gen_server:call(Pid, pubkey_bin).

-spec send_packet(Pid :: pid(), Args :: map()) -> ok.
send_packet(Pid, Args) ->
    gen_server:cast(Pid, {?SEND_PACKET, Args}).

-spec receive_send_packet(GatewayPid :: pid()) ->
    {ok, EnvDown :: hpr_envelope_up:envelope()} | {error, timeout}.
receive_send_packet(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, {?SEND_PACKET, EnvUp}} ->
            {ok, EnvUp}
    after timer:seconds(2) ->
        {error, timeout}
    end.

-spec receive_env_down(GatewayPid :: pid()) ->
    {ok, EnvDown :: hpr_envelope_down:envelope()} | {error, timeout}.
receive_env_down(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, {data, EnvDown}} ->
            {ok, EnvDown}
    after timer:seconds(2) ->
        {error, timeout}
    end.

%% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(map()) -> {ok, state()}.
init(#{forward := Pid} = Args) ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ed25519),
    lager:info(maps:to_list(Args), "started"),

    {ok, Stream} = helium_packet_router_packet_client:route(),
    {ok, #state{
        forward = Pid,
        pubkey_bin = libp2p_crypto:pubkey_to_bin(PubKey),
        sig_fun = libp2p_crypto:mk_sig_fun(PrivKey),
        stream = Stream
    }}.

handle_call(pubkey_bin, _From, #state{pubkey_bin = PubKeyBin} = State) ->
    {reply, PubKeyBin, State};
handle_call(_Msg, _From, State) ->
    lager:debug("unknown call ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(
    {?SEND_PACKET, SCPacket0},
    #state{
        forward = Pid,
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        stream = Stream
    } = State
) ->
    PacketUp = packet_up_from_sc_packet(SCPacket0),
    Signed = PacketUp#packet_router_packet_up_v1_pb{
        signature = SigFun(packet_router_pb:encode_msg(PacketUp))
    },
    EnvUp = #envelope_up_v1_pb{data = {packet, Signed}},
    ok = grpcbox_client:send(Stream, EnvUp),
    Pid ! {?MODULE, PubKeyBin, {?SEND_PACKET, EnvUp}},
    lager:debug("send_packet ~p", [EnvUp]),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:debug("unknown cast ~p", [_Msg]),
    {noreply, State}.

%% GRPC stream callbacks
handle_info({send, SCPacket}, #state{} = State) ->
    ct:print("test gateway sending packet: ~p", [SCPacket]),
    ok = ?MODULE:send_packet(self(), SCPacket),
    {noreply, State};
handle_info({data, _StreamID, Data}, #state{forward = Pid, pubkey_bin = PubKeyBin} = State) ->
    Pid ! {?MODULE, PubKeyBin, {data, Data}},
    {noreply, State};
handle_info(
    {'DOWN', Ref, process, Pid, _Reason},
    #state{stream = #{stream_pid := Pid, monitor_ref := Ref}} = State
) ->
    lager:debug("test gateway stream went down"),
    {noreply, State#state{stream = undefined}};
handle_info({headers, _StreamID, _Headers}, State) ->
    {noreply, State};
handle_info({trailers, _StreamID, _Trailers}, State) ->
    {noreply, State};
handle_info(_Msg, State) ->
    lager:debug("unknown info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, #state{forward = Pid, stream = Stream}) ->
    ok = grpcbox_client:close_send(Stream),
    Pid ! {?MODULE, self(), {terminate, Stream}},
    lager:debug("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%%% Internal Function Definitions
%% ------------------------------------------------------------------

packet_up_from_sc_packet(SCPacketBin) when erlang:is_binary(SCPacketBin) ->
    %% Decode if necessary
    {packet, SCPacket} = blockchain_state_channel_message_v1:decode(SCPacketBin),
    packet_up_from_sc_packet(SCPacket);
packet_up_from_sc_packet(SCPacket) ->
    #blockchain_state_channel_packet_v1_pb{
        packet = InPacket,
        hotspot = Gateway,
        region = Region,
        hold_time = HoldTime
    } = SCPacket,
    #packet_pb{
        type = lorawan,
        payload = Payload,
        timestamp = Timestamp,
        signal_strength = SignalStrength,
        frequency = Frequency,
        datarate = DataRate,
        snr = SNR
        %% , routing = ?MODULE:make_routing_info(RoutingInfo)
    } = InPacket,

    % signature = Signature
    Packet = #packet_router_packet_up_v1_pb{
        payload = Payload,
        timestamp = Timestamp,
        rssi = erlang:round(SignalStrength),
        %% MHz to Hz
        frequency = erlang:round(Frequency * 1_000_000),
        datarate = erlang:list_to_atom(DataRate),
        snr = SNR,
        region = Region,
        hold_time = HoldTime,
        gateway = Gateway
    },
    Packet.

sc_packet_from_env_down(#envelope_down_v1_pb{data = {packet, PacketDown}}) ->

    #packet_router_packet_down_v1_pb{
        payload = Payload,
        rx1 = #window_v1_pb{timestamp = Timestamp, datarate = DataRate, frequency = FrequencyHz}
    } = PacketDown,

    #packet_pb{
        type = lorawan,
        payload = Payload,
        timestamp = Timestamp,
        %% signal_strength = SignalStrength,
        frequency = FrequencyHz / 1000000,
        datarate = DataRate
        %% , snr = SNR
        %% , routing = ?MODULE:make_routing_info(RoutingInfo)
    }.

-spec packet_from_env_down(#envelope_down_v1_pb{}) -> #packet_router_packet_down_v1_pb{}.
packet_from_env_down(#envelope_down_v1_pb{data = {packet, PacketDown}}) ->
    PacketDown.

-spec payload_from_packet_down(#packet_router_packet_down_v1_pb{}) -> binary().
payload_from_packet_down(#packet_router_packet_down_v1_pb{payload = Payload}) ->
    Payload.
