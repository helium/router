%%%-------------------------------------------------------------------
%% @doc
%% == Router Handler ==
%% Routes a packet depending on Helium Console provided information.
%% @end
%%%-------------------------------------------------------------------
-module(router_handler).

-behavior(libp2p_framed_stream).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-include("device_worker.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    server/4,
    client/2,
    add_stream_handler/1,
    version/0
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3
]).

-define(VERSION, "simple_http/1.0.0").

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

-spec add_stream_handler(pid()) -> ok.
add_stream_handler(Swarm) ->
    ok = libp2p_swarm:add_stream_handler(
        Swarm,
        ?VERSION,
        {libp2p_framed_stream, server, [?MODULE, self()]}
    ).

-spec version() -> string().
version() ->
    ?VERSION.

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(server, _Conn, _Args) ->
    {ok, #state{}};
init(client, _Conn, _Args) ->
    {ok, #state{}}.

handle_data(server, Data, State) ->
    lager:debug("got data ~p", [Data]),
    case decode_data(Data) of
        {error, _Reason} ->
            lager:debug("failed to transmit data ~p", [_Reason]);
        {ok, #packet_pb{type = lorawan} = Packet0, PubKeyBin} ->
            router_device_worker:handle_packet(Packet0, PubKeyBin);
        {ok, #packet_pb{type = _Type} = _Packet, PubKeyBin} ->
            {ok, _AName} =
                erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
            lager:error(
                "unknown packet type ~p coming from ~p: ~p",
                [_Type, _AName, _Packet]
            )
    end,
    {noreply, State};
handle_data(_Type, _Bin, State) ->
    lager:warning("~p got data ~p", [_Type, _Bin]),
    {noreply, State}.

handle_info(server, {send_response, Resp}, State) ->
    Data = blockchain_state_channel_message_v1:encode(Resp),
    {noreply, State, Data};
handle_info(server, {packet, undefined}, State) ->
    {noreply, State};
handle_info(server, {packet, #packet_pb{} = Packet}, State) ->
    {noreply, State, encode_resp(Packet)};
handle_info(_Type, _Msg, State) ->
    lager:warning("~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec encode_resp(#packet_pb{}) -> binary().
encode_resp(Packet) ->
    Resp = #blockchain_state_channel_response_v1_pb{accepted = true, downlink = Packet},
    Msg = #blockchain_state_channel_message_v1_pb{msg = {response, Resp}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

-spec decode_data(binary()) ->
    {ok, #packet_pb{}, libp2p_crypto:pubkey_bin()} | {error, any()}.
decode_data(Data) ->
    try
        blockchain_state_channel_v1_pb:decode_msg(
            Data,
            blockchain_state_channel_message_v1_pb
        )
    of
        #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}} ->
            #blockchain_state_channel_packet_v1_pb{
                packet = HeliumPacket,
                hotspot = PubKeyBin
            } = Packet,
            {ok, HeliumPacket, PubKeyBin};
        _ ->
            {error, unhandled_message}
    catch
        _E:_R ->
            {error, {decode_failed, _E, _R}}
    end.
