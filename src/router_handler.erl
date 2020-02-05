%%%-------------------------------------------------------------------
%% @doc
%% == Router Handler ==
%% Routes a packet depending on Helium Console provided information.
%% @end
%%%-------------------------------------------------------------------
-module(router_handler).

-behavior(libp2p_framed_stream).

-include_lib("helium_proto/src/pb/blockchain_state_channel_v1_pb.hrl").
-include("router.hrl").
-include("device.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

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
-define(UNCONFIRMED_DOWN, 2#011).
-define(CONFIRMED_UP, 2#100).
-define(CONFIRMED_DOWN, 2#101).

-record(state, {}).

-record(frame, {
                mtype,
                devaddr,
                ack = 0,
                adr = 0,
                adrackreq = 0,
                rfu = 0,
                fpending = 0,
                fcnt,
                fopts = [],
                fport,
                data,
                device
               }).

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
    lager:info("got data ~p", [Data]),
    case handle_server_data(Data) of
        ok ->
            lager:info("data sent, no reply"),
            {noreply, State};
        {ok, Packet} ->
            lager:info("data sent, reply ~p", [Packet]),
            {noreply, State, encode_resp(Packet)};
        {error, _Reason} ->
            lager:error("failed to transmit data ~p / ~p", [_Reason, Data]),
            {noreply, State}
    end;
handle_data(_Type, _Bin, State) ->
    lager:warning("~p got data ~p", [_Type, _Bin]),
    {noreply, State}.

handle_info(_Type, _Msg, State) ->
    lager:debug("~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_server_data(binary()) -> ok | {ok, #helium_packet_pb{}} | {error, any()}.
handle_server_data(Data) ->
    case decode_data(Data) of
        {error, _Reason}=Error ->
            Error;
        {ok, #helium_packet_pb{type=lorawan}=Packet0, PubkeyBin} ->
            case handle_lora_packet(Packet0, PubkeyBin) of
                {ok, Packet1, #{oui := OUI, device_id := DID}=MapData} ->
                    SendFun = e2qc:cache(console_cache, {OUI, DID}, 300, fun() -> router_console:send_data_fun(DID, OUI) end),
                    _ = SendFun(MapData),
                    case Packet1 of
                        undefined -> ok;
                        _ -> {ok, Packet1}
                    end;
                Else ->
                    Else
            end;
        {ok, #helium_packet_pb{type=Type}, _PubkeyBin} ->
            {error, {unknown_packet_type, Type}}
    end.

-spec encode_resp(#helium_packet_pb{}) -> binary().
encode_resp(Packet) ->
    Msg = #blockchain_state_channel_message_v1_pb{msg = {response, #blockchain_state_channel_response_v1_pb{accepted=true, downlink=Packet}}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

-spec decode_data(binary()) -> {ok, #helium_packet_pb{}, libp2p_crypto:pubkey_bin()} | {error, any()}.
decode_data(Data) ->
    try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
        #blockchain_state_channel_message_v1_pb{msg={packet, Packet}} ->
            #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket,
                                                   hotspot = PubkeyBin} = Packet,
            {ok, HeliumPacket, PubkeyBin};
        _ ->
            {error, unhandled_message}
    catch
        _E:_R ->
            {error, {decode_failed, _E, _R}}
    end.

-spec handle_lora_packet(#helium_packet_pb{}, libp2p_crypto:pubkey_bin()) -> {ok, #helium_packet_pb{}} | {ok, #helium_packet_pb{} | undefined, map()} | {error, any()}.
handle_lora_packet(#helium_packet_pb{oui=OUI, type=Type, timestamp=Time, frequency=Freq,
                                     datarate=DataRate, payload=Payload, signal_strength=RSSI, snr=SNR}, PubkeyBin) ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    case handle_lorawan_payload(Payload, AName) of
        {error, _Reason}=Error ->
            Error;
        {join, Reply} ->
            #{tmst := TxTime,
              datr := TxDataRate,
              freq := TxFreq} = lorawan_mac_region_old:join1_window(<<"US902-928">>,
                                                                    #{<<"tmst">> => Time,
                                                                      <<"freq">> => Freq,
                                                                      <<"datr">> => erlang:list_to_binary(DataRate),
                                                                      <<"codr">> => <<"lol">>}),
            Packet = #helium_packet_pb{oui=OUI, type=Type, payload=Reply, timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
            {ok, Packet};
        {ok, #frame{device=#device{queue=Queue0, fcnt=FCNT, app_eui=AppEUI, channel_correction=ChannelCorrection, fcntdown=FCNTDown, offset=Offset}=Device,
                    mtype=MType0, fopts=FOpts0, devaddr=DevAddr, data=Data}} ->
            <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
            MapData = #{
                        miner_name => erlang:list_to_binary(AName),
                        rssi => RSSI,
                        snr => SNR,
                        oui => OUI,
                        device_id => DID,
                        sequence => FCNT,
                        spreading => erlang:list_to_binary(DataRate),
                        payload => Data,
                        timestamp => Time
                       },
            case MType0 == ?CONFIRMED_UP orelse erlang:length(Queue0) > 0 of
                false ->
                    {ok, undefined, MapData};
                true ->
                    ACK = case MType0 == ?CONFIRMED_UP of
                              true -> 1;
                              false -> 0
                          end,
                    {{Confirmed, Port, ReplyPayload}, Queue1} =
                        case Queue0 of
                            [] -> {{undefined, undefined, <<>>}, []};
                            [H|T] -> {H, T}
                        end,
                    MType1 = case Confirmed of
                                 true ->
                                     ?CONFIRMED_DOWN;
                                 false ->
                                     ?UNCONFIRMED_DOWN;
                                 undefined ->
                                     ?UNCONFIRMED_DOWN
                             end,
                    case {ACK == 1, Port == undefined} of
                        {true, true} ->
                            case Confirmed of
                                true ->
                                    StatusMsg = <<"Sending ACK and confirmed data in response to fcnt ", (int_to_bin(FCNT))/binary>>,
                                    ok = router_console:report_status(OUI, DID, success, AName, StatusMsg);
                                false ->
                                    StatusMsg = <<"Sending ACK and unconfirmed data in response to fcnt ", (int_to_bin(FCNT))/binary>>,
                                    ok = router_console:report_status(OUI, DID, success, AName, StatusMsg)
                            end;
                        {true, false} ->
                            StatusMsg = <<"Sending ACK in response to fcnt ", (int_to_bin(FCNT))/binary>>,
                            ok = router_console:report_status(OUI, DID, success, AName, StatusMsg);
                        {false, true} ->
                            case Confirmed of
                                true ->
                                    StatusMsg = <<"Sending confirmed data in response to fcnt ", (int_to_bin(FCNT))/binary>>,
                                    ok = router_console:report_status(OUI, DID, success, AName, StatusMsg);
                                false ->
                                    StatusMsg = <<"Sending unconfirmed data in response to fcnt ", (int_to_bin(FCNT))/binary>>,
                                    ok = router_console:report_status(OUI, DID, success, AName, StatusMsg)
                            end
                    end,
                    FOpts1 = case ChannelCorrection of
                                 false -> lorawan_mac_region:set_channels(<<"US902-28">>, {0, erlang:list_to_binary(DataRate), [{48, 55}]}, []);
                                 true -> []
                             end,
                    ChannelsCorrected = case lists:keyfind(link_adr_ans, 1, FOpts0) of
                                            {link_adr_ans, 1, 1, 1} when ChannelCorrection == false ->
                                                true;
                                            _ ->
                                                ChannelCorrection
                                        end,
                    DeviceUpdates = [
                                     {queue, Queue1},
                                     {channel_correction, ChannelsCorrected},
                                     {fcntdown, (FCNTDown + 1)}
                                    ],
                    ok = router_devices_server:update(AppEUI, DeviceUpdates),
                    Reply = lorawan_reply(#frame{mtype=MType1, devaddr=DevAddr, fcnt=FCNTDown, fopts=FOpts1, fport=Port, ack=ACK, data=ReplyPayload}, Device),
                    #{tmst := TxTime, datr := TxDataRate, freq := TxFreq} = lorawan_mac_region_old:rx1_window(<<"US902-928">>,
                                                                                                              Offset,
                                                                                                              #{<<"tmst">> => Time, <<"freq">> => Freq,
                                                                                                                <<"datr">> => erlang:list_to_binary(DataRate), <<"codr">> => <<"lol">>}),
                    Packet = #helium_packet_pb{oui=OUI, type=Type, payload=Reply, timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
                    {ok, Packet, MapData}
            end
    end.

-spec handle_lorawan_payload(binary(), string()) -> {ok, #frame{}} | {join, binary()} | {error, any()}.
handle_lorawan_payload(<<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, DevNonce:2/binary, MIC:4/binary>> =Payload, AName) when MType == 0 ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
    case router_console:get_app_key(DID, OUI) of
        undefined ->
            lager:info("no key for ~p ~p received by ~s", [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
            StatusMsg = <<"No device for AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
            ok = router_console:report_status(OUI, DID, failure, AName, StatusMsg),
            {error, undefined_app_key};
        AppKey ->
            case router_devices_server:get(AppEUI) of
                {ok, #device{join_nonce=OldNonce}} when DevNonce == OldNonce ->
                    lager:info("Device ~p ~p tried to join with stale nonce ~p via ~s", [OUI, DID, DevNonce, AName]),
                    StatusMsg = <<"Stale join nonce ", (lorawan_utils:binary_to_hex(OldNonce))/binary, " for AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
                    ok = router_console:report_status(OUI, DID, failure, AName, StatusMsg),
                    {error, bad_nonce};
                _ ->
                    Msg = binary:part(Payload, {0, erlang:byte_size(Payload)-4}),
                    case crypto:cmac(aes_cbc128, AppKey, Msg, 4) of
                        MIC ->
                            NetID = <<"He2">>,
                            AppNonce = crypto:strong_rand_bytes(3),
                            NwkSKey = crypto:block_encrypt(aes_ecb,
                                                           AppKey,
                                                           padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
                            AppSKey = crypto:block_encrypt(aes_ecb,
                                                           AppKey,
                                                           padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
                            DevAddr = <<OUI:32/integer-unsigned-big>>,
                            Device = #device{mac=DevEUI, app_eui=AppEUI, app_s_key=AppSKey, nwk_s_key=NwkSKey, join_nonce=DevNonce, fcntdown=0, queue=[]},
                            ok = router_devices_server:insert(Device),
                            RxDelay = 0,
                            DLSettings = 0,
                            _CFList = <<0:16/integer-unsigned-little, 0:16/integer-unsigned-little, 0:16/integer-unsigned-little, 16#00ff:16/integer-unsigned-little,
                                        0:16/integer-unsigned-little, 0:16/integer-unsigned-little, 0:16/integer-unsigned-little, 1:8/integer-unsigned-little>>,
                            lager:info("~p ~p ~p ~p ~p", [AppNonce, NetID, DevAddr, DLSettings, RxDelay]),
                            ReplyHdr = <<2#001:3, 0:3, 0:2>>,
                            ReplyPayload = <<AppNonce/binary, NetID/binary, DevAddr/binary, DLSettings:8/integer-unsigned, RxDelay:8/integer-unsigned>>, %, CFList/binary>>,
                            ReplyMIC = crypto:cmac(aes_cbc128, AppKey, <<ReplyHdr/binary, ReplyPayload/binary>>, 4),
                            EncryptedReply = crypto:block_decrypt(aes_ecb, AppKey, padded(16, <<ReplyPayload/binary, ReplyMIC/binary>>)),
                            lager:info("Device ~s with AppEUI ~s tried to join with nonce ~p via ~s", [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), DevNonce, AName]),
                            StatusMsg = <<"Join attempt from AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
                            ok = router_console:report_status(OUI, DID, success, AName, StatusMsg),
                            {join, <<ReplyHdr/binary, EncryptedReply/binary>>};
                        _ ->
                            lager:info("Device ~s with AppEUI ~s tried to join through ~s but had a bad Message Intregity Code~n", [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
                            StatusMsg = <<"Bad Message Integrity Code on join for AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary, ", check AppKey">>,
                            ok = router_console:report_status(OUI, DID, failure, AName, StatusMsg),
                            {error, bad_mic}
                    end
            end
    end;
handle_lorawan_payload(<<MType:3, _MHDRRFU:3, _Major:2, DevAddr0:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1, FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Pkt, AName) ->
    Msg = binary:part(Pkt, {0, erlang:byte_size(Pkt) -4}),
    Body = binary:part(PayloadAndMIC, {0, erlang:byte_size(PayloadAndMIC) -4}),
    MIC = binary:part(PayloadAndMIC, {erlang:byte_size(PayloadAndMIC), -4}),
    {FPort, FRMPayload} =
        case Body of
            <<>> -> {undefined, <<>>};
            <<Port:8, Payload/binary>> -> {Port, Payload}
        end,
    DevAddr = lorawan_utils:reverse(DevAddr0),
    case get_device_by_mic(router_devices_server:get_all(), <<(b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Msg)))/binary, Msg/binary>>, MIC)  of
        undefined ->
            lager:info("packet from unknown device ~s received by ~s", [lorawan_utils:binary_to_hex(DevAddr), AName]),
            {error, unknown_device};
        #device{fcnt=FCnt, app_eui=AppEUI} ->
            lager:info("discarding duplicate packet ~b from ~p received by ~s", [FCnt, lorawan_utils:binary_to_hex(AppEUI), AName]),
            {error, duplicate_packet};
        Device0 ->
            NwkSKey = Device0#device.nwk_s_key,
            DeviceUpdates = [{fcnt, FCnt}],
            ok = router_devices_server:update(Device0#device.app_eui, DeviceUpdates),
            Device = Device0#device{fcnt=FCnt},
            case FPort of
                0 when FOptsLen == 0 ->
                    Data = lorawan_utils:reverse(cipher(FRMPayload, NwkSKey, MType band 1, DevAddr, FCnt)),
                    lager:info("~s packet from ~s with fopts ~p received by ~s", [mtype(MType), lorawan_utils:binary_to_hex(Device#device.app_eui), lorawan_mac_commands:parse_fopts(Data), AName]),
                    {ok, #frame{mtype=MType, devaddr=DevAddr, adr=ADR, adrackreq=ADRACKReq, ack=ACK, rfu=RFU, fcnt=FCnt, fopts=lorawan_mac_commands:parse_fopts(Data), fport=0, data = <<>>, device=Device}};
                0 ->
                    lager:info("Bad ~s packet from ~s received by ~s -- double fopts~n", [mtype(MType), lorawan_utils:binary_to_hex(Device#device.app_eui), AName]),
                    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = Device#device.app_eui,
                    StatusMsg = <<"Packet with double fopts received from AppEUI: ", (lorawan_utils:binary_to_hex(Device#device.app_eui))/binary, " DevEUI: ", (lorawan_utils:binary_to_hex(Device#device.mac))/binary>>,
                    ok = router_console:report_status(OUI, DID, failure, AName, StatusMsg),
                    {error, double_fopts};
                _N ->
                    AppSKey = Device#device.app_s_key,
                    Data = lorawan_utils:reverse(cipher(FRMPayload, AppSKey, MType band 1, DevAddr, FCnt)),
                    lager:info("~s packet from ~s with ACK ~p fopts ~p and data ~p received by ~s", [mtype(MType), lorawan_utils:binary_to_hex(Device#device.app_eui), ACK, lorawan_mac_commands:parse_fopts(FOpts), Data, AName]),
                    {ok, #frame{mtype=MType, devaddr=DevAddr, adr=ADR, adrackreq=ADRACKReq, ack=ACK, rfu=RFU, fcnt=FCnt, fopts=lorawan_mac_commands:parse_fopts(FOpts), fport=FPort, data=Data, device=Device}}
            end
    end;
handle_lorawan_payload(Payload, AName) ->
    {error, {bad_packet, lorawan_utils:binary_to_hex(Payload), AName}}.

-spec lorawan_reply(#frame{}, #device{}) -> binary().
lorawan_reply(Frame, Device) ->
    FOpts = lorawan_mac_commands:encode_fopts(Frame#frame.fopts),
    FOptsLen = erlang:byte_size(FOpts),
    PktHdr = <<(Frame#frame.mtype):3, 0:3, 0:2, (lorawan_utils:reverse(Frame#frame.devaddr))/binary, (Frame#frame.adr):1, 0:1, (Frame#frame.ack):1, (Frame#frame.fpending):1, FOptsLen:4, (Frame#frame.fcnt):16/integer-unsigned-little, FOpts:FOptsLen/binary>>,
    PktBody = case Frame#frame.data of
                  <<>> ->
                      %% no payload
                      <<>>;
                  <<Payload/binary>> when Frame#frame.fport == 0 ->
                      lager:info("port 0 outbound"),
                      %% port 0 payload, encrypt with network key
                      <<0:8/integer-unsigned, (lorawan_utils:reverse(cipher(Payload, Device#device.nwk_s_key, 1, Frame#frame.devaddr, Frame#frame.fcnt)))/binary>>;
                  <<Payload/binary>> ->
                      lager:info("port ~p outbound", [Frame#frame.fport]),
                      <<(Frame#frame.fport):8/integer-unsigned, (lorawan_utils:reverse(cipher(Payload, Device#device.app_s_key, 1, Frame#frame.devaddr, Frame#frame.fcnt)))/binary>>
              end,
    lager:info("PktBody ~p, FOpts ~p", [PktBody, Frame#frame.fopts]),
    Msg = <<PktHdr/binary, PktBody/binary>>,
    MIC = crypto:cmac(aes_cbc128, Device#device.nwk_s_key, <<(b0(1, Frame#frame.devaddr, Frame#frame.fcnt, byte_size(Msg)))/binary, Msg/binary>>, 4),
    <<Msg/binary, MIC/binary>>.
-spec padded(integer(), binary()) -> binary().
padded(Bytes, Msg) ->
    case bit_size(Msg) rem (8*Bytes) of
        0 -> Msg;
        N -> <<Msg/bitstring, 0:(8*Bytes-N)>>
    end.

-spec get_device_by_mic([#device{}], binary(), binary()) -> #device{} | undefined.
get_device_by_mic([], _, _) ->
    undefined;
get_device_by_mic([Device|Tail], Bin, MIC) ->
    NwkSKey = Device#device.nwk_s_key,
    case crypto:cmac(aes_cbc128, NwkSKey, Bin, 4) of
        MIC ->
            Device;
        _ ->
            get_device_by_mic(Tail, Bin, MIC)
    end.

-spec mtype(integer()) -> string().
mtype(2#000) -> "Join request";
mtype(2#001) -> "Join accept";
mtype(2#010) -> "Unconfirmed data up";
mtype(2#011) -> "Unconfirmed data down";
mtype(2#100) -> "Confirmed data up";
mtype(2#101) -> "Confirmed data down";
mtype(2#110) -> "RFU";
mtype(2#111) -> "Proprietary".

cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I+1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) -> Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

-spec ai(integer(), binary(), integer(), integer()) -> binary().
ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0,0,0,0, Dir, (lorawan_utils:reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

-spec b0(integer(), binary(), integer(), integer()) -> binary().
b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (lorawan_utils:reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

-spec binxor(binary(), binary(), binary()) -> binary().
binxor(<<>>, <<>>, Acc) -> Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).

-spec int_to_bin(integer()) -> binary().
int_to_bin(Int) ->
    erlang:list_to_binary(erlang:integer_to_list(Int)).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
