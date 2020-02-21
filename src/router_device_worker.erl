%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_worker).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
         start_link/1,
         handle_packet/2,
         queue_message/2
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).


-define(SERVER, ?MODULE).
-record(state, {
                db :: rocksdb:db_handle(),
                cf :: rocksdb:cf_handle(),
                device :: #device{}
               }).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).


-spec handle_packet(#packet_pb{}, libp2p_crypto:pubkey_bin()) -> ok.
handle_packet(Packet, PubkeyBin) ->
    case handle_packet(Packet, PubkeyBin, self()) of
        {error, _Reason} ->
            lager:warning("failed to handle packet ~p : ~p", [Packet, _Reason]);
        ok ->
            ok
    end.

-spec queue_message(pid(), {{boolean(), integer(), binary()}}) -> ok.
queue_message(Pid, Msg) ->
    gen_server:cast(Pid, {queue_message, Msg}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    DB = maps:get(db, Args),
    CF = maps:get(cf, Args),
    ID = maps:get(id, Args),
    Device = case get_device(DB, CF, ID) of
                 {ok, D} -> D;
                 _ -> #device{}
             end,
    {ok, #state{db=DB, cf=CF, device=Device}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({queue_message, {_Type, _Port, _Payload}=Msg}, #state{db=DB, cf=CF, device=Device0}=State) ->
    Device1 = Device0#device{queue=lists:append(Device0#device.queue, [Msg])},
    {ok, _} = save_device(DB, CF, Device1),
    {noreply, State#state{device=Device1}};
handle_cast({join, Packet0, PubkeyBin, Pid}, #state{db=DB, cf=CF, device=Device0}=State) ->
    case handle_join(Packet0, PubkeyBin, Device0) of
        {error, _Reason} ->
            {noreply, State};
        {ok, Packet1, Device1} ->
            {ok, _} = save_device(DB, CF, Device1),
            Pid ! {packet, Packet1},
            {noreply, State#state{device=Device1}}
    end;
handle_cast({frame, Packet, PubkeyBin, Pid}, #state{db=DB, cf=CF, device=Device0}=State) ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    case handle_frame_packet(Packet, AName, Device0) of
        {error, _Reason} ->
            {noreply, State};
        {ok, Frame, Device1} ->
            ok = send_to_channel(Packet, Device1, Frame, AName),
            case handle_frame(Packet, AName, Device1, Frame, true) of
                {send, Device2, Packet1} ->
                    {ok, _} = save_device(DB, CF, Device2),
                    Pid ! {packet, Packet1},
                    {noreply, State#state{device=Device2}};
                {delay, Time} ->
                    {ok, _} = save_device(DB, CF, Device1),
                    erlang:send_after(Time, self(), {delay_timeout, Packet, AName, Frame, Pid}),
                    {noreply, State#state{device=Device1}}
            end
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({delay_timeout, Packet, AName, Frame, Pid}, #state{db=DB, cf=CF, device=Device0}=State) ->
    case handle_frame(Packet, AName, Device0, Frame, false) of
        {send, Device1, Packet1} ->
            {ok, _} = save_device(DB, CF, Device1),
            Pid ! {packet, Packet1},
            {noreply, State#state{device=Device1}};
        noop ->
            {noreply, State}
    end;
handle_info({report_status, Status, AName, Msg}, #state{device=Device}=State) ->
    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = Device#device.app_eui,
    ok = router_console:report_status(OUI, DID, Status, AName, Msg),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{db=DB}) ->
    catch rocksdb:close(DB),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec handle_packet(#packet_pb{}, string(), pid()) -> ok | {error, any()}.
handle_packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                                    _DevNonce:2/binary, _MIC:4/binary>>}=Packet, PubkeyBin, Pid) when MType == ?JOIN_REQ ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    case maybe_start_worker(AppEUI, DevEUI) of
        {error, _Reason}=Error ->
            Error;
        {ok, WorkerPid} ->
            gen_server:cast(WorkerPid, {join, Packet, PubkeyBin, Pid})
    end;
handle_packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, DevAddr0:4/binary, _ADR:1, _ADRACKReq:1,
                                    _ACK:1, _RFU:1, FOptsLen:4, FCnt:16/little-unsigned-integer,
                                    _FOpts:FOptsLen/binary, PayloadAndMIC/binary>> =Payload}=Packet, PubkeyBin, Pid) ->
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) -4}),
    MIC = binary:part(PayloadAndMIC, {erlang:byte_size(PayloadAndMIC), -4}),
    DevAddr = lorawan_utils:reverse(DevAddr0),
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    {ok, DB, [_DefaultCF, CF]} = router_db:get(),
    case get_device_by_mic(get_devices(DB, CF),
                           <<(b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Msg)))/binary, Msg/binary>>, MIC)  of
        undefined ->
            lager:debug("packet from unknown device ~s received by ~s", [lorawan_utils:binary_to_hex(DevAddr), AName]),
            {error, unknown_device};
        #device{fcnt=FCnt, app_eui=AppEUI} ->
            lager:debug("discarding duplicate packet ~b from ~p received by ~s", [FCnt, lorawan_utils:binary_to_hex(AppEUI), AName]),
            {error, duplicate_packet};
        #device{app_eui=AppEUI, mac=MAC} ->
            case maybe_start_worker(AppEUI, MAC) of
                {error, _Reason}=Error ->
                    Error;
                {ok, WorkerPid} ->
                    gen_server:cast(WorkerPid, {frame, Packet, PubkeyBin, Pid})
            end
    end;
handle_packet(#packet_pb{payload=Payload}, AName, _Pid) ->
    {error, {bad_packet, lorawan_utils:binary_to_hex(Payload), AName}}.

-spec maybe_start_worker(binary(), binary()) -> {ok, pid()} | {error, any()}.
maybe_start_worker(AppEUI, MAC) ->
    WorkerID = router_devices_sup:id(AppEUI, MAC),
    router_devices_sup:maybe_start_worker(WorkerID, #{}).

-spec handle_join(#packet_pb{}, libp2p_crypto:pubkey_to_bin(), #device{}) -> {ok, #packet_pb{}, #device{}} | {error, any()}.
handle_join(#packet_pb{oui=OUI, payload= <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary,
                                           DevEUI0:8/binary, OldNonce:2/binary, _MIC:4/binary>>},
            PubkeyBin,
            #device{join_nonce=OldNonce}) when MType == ?JOIN_REQ ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
    case throttle:check(join_dedup, {AppEUI, DevEUI, OldNonce}) of
        {ok, _, _} ->
            lager:debug("Device ~p ~p tried to join with stale nonce ~p via ~s", [OUI, DID, OldNonce, AName]),
            StatusMsg = <<"Stale join nonce ", (lorawan_utils:binary_to_hex(OldNonce))/binary, " for AppEUI: ",
                          (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
            ok = report_status(failure, AName, StatusMsg);
        _ ->
            ok
    end,
    {error, bad_nonce};
handle_join(#packet_pb{oui=OUI, type=Type, timestamp=Time, frequency=Freq, datarate=DataRate,
                       payload= <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                                  DevNonce:2/binary, MIC:4/binary>> =Payload},
            PubkeyBin,
            _Device) when MType == 0 ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
    case router_console:get_app_key(DID, OUI) of
        undefined ->
            lager:debug("no key for ~p ~p received by ~s", [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
            StatusMsg = <<"No device for AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
            ok = report_status(failure, AName, StatusMsg),
            {error, undefined_app_key};
        AppKey ->
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
                    RxDelay = ?RX_DELAY,
                    DLSettings = 0,
                    ReplyHdr = <<2#001:3, 0:3, 0:2>>,
                    ReplyPayload = <<AppNonce/binary, NetID/binary, DevAddr/binary, DLSettings:8/integer-unsigned, RxDelay:8/integer-unsigned>>,
                    ReplyMIC = crypto:cmac(aes_cbc128, AppKey, <<ReplyHdr/binary, ReplyPayload/binary>>, 4),
                    EncryptedReply = crypto:block_decrypt(aes_ecb, AppKey, padded(16, <<ReplyPayload/binary, ReplyMIC/binary>>)),
                    Reply = <<ReplyHdr/binary, EncryptedReply/binary>>,
                    #{tmst := TxTime,
                      datr := TxDataRate,
                      freq := TxFreq} = lorawan_mac_region_old:join1_window(<<"US902-928">>,
                                                                            #{<<"tmst">> => Time,
                                                                              <<"freq">> => Freq,
                                                                              <<"datr">> => erlang:list_to_binary(DataRate),
                                                                              <<"codr">> => <<"lol">>}),
                    lager:info("Device ~s with AppEUI ~s tried to join with nonce ~p via ~s",
                               [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), DevNonce, AName]),
                    case throttle:check(join_dedup, {AppEUI, DevEUI, DevNonce}) of
                        {ok, _, _} ->
                            StatusMsg = <<"Join attempt from AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
                                          (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
                            ok = report_status(success, AName, StatusMsg);
                        _ ->
                            ok
                    end,
                    Packet = #packet_pb{oui=OUI, type=Type, payload=Reply, timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
                    Device = #device{mac=DevEUI, app_eui=AppEUI, app_s_key=AppSKey, nwk_s_key=NwkSKey, join_nonce=DevNonce, fcntdown=0, queue=[]},
                    {ok, Packet, Device};
                _ ->
                    case throttle:check(join_dedup, {AppEUI, DevEUI, DevNonce}) of
                        {ok, _, _} ->
                            lager:debug("Device ~s with AppEUI ~s tried to join through ~s but had a bad Message Intregity Code~n",
                                        [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
                            StatusMsg = <<"Bad Message Integrity Code on join for AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary,
                                          " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary, ", check AppKey">>,
                            ok = report_status(failure, AName, StatusMsg);
                        _ ->
                            ok
                    end,
                    {error, bad_mic}
            end
    end.

-spec handle_frame_packet(#packet_pb{}, string(), #device{}) -> {ok, #frame{}, #device{}} | {error, any()}.
handle_frame_packet(Packet, AName, Device0) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddrReversed:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
      FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Packet#packet_pb.payload,
    DevAddr = lorawan_utils:reverse(DevAddrReversed),
    AppEUI = Device0#device.app_eui,
    MAC = Device0#device.mac,
    case throttle:check(packet_dedup, {AppEUI, MAC, FCnt}) of
        {ok, _, _} ->
            {FPort, FRMPayload} = extract_frame_port_payload(PayloadAndMIC),
            case FPort of
                0 when FOptsLen == 0 ->
                    NwkSKey = Device0#device.nwk_s_key,
                    Data = lorawan_utils:reverse(cipher(FRMPayload, NwkSKey, MType band 1, DevAddr, FCnt)),
                    lager:info("~s packet from ~s with fopts ~p received by ~s",
                               [mtype(MType), lorawan_utils:binary_to_hex(Device0#device.app_eui), lorawan_mac_commands:parse_fopts(Data), AName]),
                    {error, mac_command_not_handled};
                0 ->
                    lager:debug("Bad ~s packet from ~s received by ~s -- double fopts~n",
                                [mtype(MType), lorawan_utils:binary_to_hex(Device0#device.app_eui), AName]),
                    StatusMsg = <<"Packet with double fopts received from AppEUI: ",
                                  (lorawan_utils:binary_to_hex(Device0#device.app_eui))/binary, " DevEUI: ",
                                  (lorawan_utils:binary_to_hex(Device0#device.mac))/binary>>,
                    ok = report_status(failure, AName, StatusMsg),
                    {error, double_fopts};
                _N ->
                    AppSKey = Device0#device.app_s_key,
                    Data = lorawan_utils:reverse(cipher(FRMPayload, AppSKey, MType band 1, DevAddr, FCnt)),
                    lager:info("~s packet from ~s with ACK ~p fopts ~p and data ~p received by ~s",
                               [mtype(MType), lorawan_utils:binary_to_hex(Device0#device.app_eui), ACK, lorawan_mac_commands:parse_fopts(FOpts), Data, AName]),
                    %% If frame countain ACK=1 we should clear message from queue and go on next
                    Queue = case ACK of
                                0 ->
                                    Device0#device.queue;
                                1 ->
                                    case Device0#device.queue of
                                        [] -> [];
                                        %% TODO: Check if confirmed down link
                                        [_Acked|T] -> T
                                    end
                            end,
                    Device1 = Device0#device{fcnt=FCnt, queue=Queue},
                    Frame = #frame{mtype=MType, devaddr=DevAddr, adr=ADR, adrackreq=ADRACKReq, ack=ACK, rfu=RFU,
                                   fcnt=FCnt, fopts=lorawan_mac_commands:parse_fopts(FOpts), fport=FPort, data=Data},
                    {ok, Frame, Device1}
            end;
        _ ->
            {error, throttle_duplicate_packet}
    end.

-spec handle_frame(#packet_pb{}, string(), #device{}, #frame{}, boolean()) -> noop | {delay, integer()} | {send,#device{}, #packet_pb{}}.
handle_frame(_Packet, _AName, #device{queue=[]}, _Frame, true) ->
    {delay, ?REPLY_DELAY};
handle_frame(Packet0, AName, #device{queue=[]}=Device0, Frame, false) ->
    ACK = mtype_to_ack(Frame#frame.mtype),
    case ACK of
        0 ->
            noop;
        1 ->
            ConfirmedDown = false,
            Port = 0, %% Not sure about that?
            ok = report_frame_status(ACK, ConfirmedDown, Port, AName, Device0#device.fcnt),
            {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(Packet0, Device0, Frame),
            FCNTDown = Device0#device.fcntdown,
            MType = ack_to_mtype(ConfirmedDown),
            Reply = frame_to_packet_payload(#frame{mtype=MType, devaddr=Frame#frame.devaddr, fcnt=FCNTDown, fopts=FOpts1, fport=Port, ack=ACK, data= <<>>},
                                            Device0),
            DataRate = Packet0#packet_pb.datarate,
            #{tmst := TxTime, datr := TxDataRate, freq := TxFreq} =
                lorawan_mac_region_old:rx1_window(<<"US902-928">>,
                                                  Device0#device.offset,
                                                  #{<<"tmst">> => Packet0#packet_pb.timestamp, <<"freq">> => Packet0#packet_pb.frequency,
                                                    <<"datr">> => erlang:list_to_binary(DataRate), <<"codr">> => <<"ignored">>}),
            Packet1 = #packet_pb{oui=Packet0#packet_pb.oui, type=Packet0#packet_pb.type, payload=Reply,
                                 timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
            Device1 = Device0#device{channel_correction=ChannelsCorrected, fcntdown=(FCNTDown + 1)},
            {send, Device1, Packet1}
    end;
handle_frame(Packet0, AName, #device{queue=[{ConfirmedDown, Port, ReplyPayload}|T]}=Device0, Frame, _AllowDelay) ->
    ACK = mtype_to_ack(Frame#frame.mtype),
    MType = ack_to_mtype(ConfirmedDown),
    ok = report_frame_status(ACK, ConfirmedDown, Port, AName, Device0#device.fcnt),
    {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(Packet0, Device0, Frame),
    FCNTDown = Device0#device.fcntdown,
    Reply = frame_to_packet_payload(#frame{mtype=MType, devaddr=Frame#frame.devaddr, fcnt=FCNTDown, fopts=FOpts1, fport=Port, ack=ACK, data=ReplyPayload}, Device0),
    DataRate = Packet0#packet_pb.datarate,
    #{tmst := TxTime, datr := TxDataRate, freq := TxFreq} =
        lorawan_mac_region_old:rx1_window(<<"US902-928">>,
                                          Device0#device.offset,
                                          #{<<"tmst">> => Packet0#packet_pb.timestamp, <<"freq">> => Packet0#packet_pb.frequency,
                                            <<"datr">> => erlang:list_to_binary(DataRate), <<"codr">> => <<"ignored">>}),
    Packet1 = #packet_pb{oui=Packet0#packet_pb.oui, type=Packet0#packet_pb.type, payload=Reply,
                         timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
    case ConfirmedDown of
        true ->
            Device1 = Device0#device{channel_correction=ChannelsCorrected},
            {send, Device1, Packet1};
        false ->
            Device1 = Device0#device{queue=T, channel_correction=ChannelsCorrected, fcntdown=(FCNTDown + 1)},
            {send, Device1, Packet1}
    end.

-spec channel_correction_and_fopts(#packet_pb{}, #device{}, #frame{}) -> {boolean(), list()}.
channel_correction_and_fopts(Packet, Device, Frame) ->
    ChannelCorrection = Device#device.channel_correction,
    FOpts0 = Frame#frame.fopts,
    ChannelsCorrected = case lists:keyfind(link_adr_ans, 1, FOpts0) of
                            {link_adr_ans, 1, 1, 1} when ChannelCorrection == false ->
                                true;
                            _ ->
                                ChannelCorrection
                        end,
    DataRate = Packet#packet_pb.datarate,
    FOpts1 = case ChannelsCorrected of
                 false -> lorawan_mac_region:set_channels(<<"US902-28">>, {0, erlang:list_to_binary(DataRate), [{48, 55}]}, []);
                 true -> []
             end,
    {ChannelsCorrected, FOpts1}.

-spec extract_frame_port_payload(binary()) -> {undefined | integer(), binary()}.
extract_frame_port_payload(PayloadAndMIC) ->
    case binary:part(PayloadAndMIC, {0, erlang:byte_size(PayloadAndMIC) -4}) of
        <<>> -> {undefined, <<>>};
        <<Port:8, Payload/binary>> -> {Port, Payload}
    end.

-spec mtype_to_ack(integer()) -> 0 | 1.
mtype_to_ack(?CONFIRMED_UP) -> 1;
mtype_to_ack(_) -> 0.

-spec ack_to_mtype(boolean()) -> integer().
ack_to_mtype(true) -> ?CONFIRMED_DOWN;
ack_to_mtype(_) -> ?UNCONFIRMED_DOWN.

-spec report_frame_status(integer(), boolean(), any(), string(), integer()) -> ok.
report_frame_status(1, _ConfirmedDown, undefined, AName, FCNT) ->
    StatusMsg = <<"Sending ACK in response to fcnt ", (int_to_bin(FCNT))/binary>>,
    ok = report_status(success, AName, StatusMsg);
report_frame_status(1, true, _Port, AName, FCNT) ->
    StatusMsg = <<"Sending ACK and confirmed data in response to fcnt ", (int_to_bin(FCNT))/binary>>,
    ok = report_status(success, AName, StatusMsg);
report_frame_status(1, false, _Port, AName, FCNT) ->
    StatusMsg = <<"Sending ACK and unconfirmed data in response to fcnt ", (int_to_bin(FCNT))/binary>>,
    ok = report_status(success, AName, StatusMsg);
report_frame_status(_, true, _Port, AName, FCNT) ->
    StatusMsg = <<"Sending confirmed data in response to fcnt ", (int_to_bin(FCNT))/binary>>,
    ok = report_status(success, AName, StatusMsg);
report_frame_status(_, false, _Port, AName, FCNT) ->
    StatusMsg = <<"Sending unconfirmed data in response to fcnt ", (int_to_bin(FCNT))/binary>>,
    ok = report_status(success, AName, StatusMsg).

-spec report_status(atom(), string(), binary()) -> ok.
report_status(Type, AName, Msg) ->
    self() ! {report_status, Type, AName, Msg},
    ok.

-spec send_to_channel(#packet_pb{}, #device{}, #frame{}, string()) -> ok.
send_to_channel(#packet_pb{oui=OUI, timestamp=Time, datarate=DataRate, signal_strength=RSSI, snr=SNR},
                #device{fcnt=FCNT, app_eui=AppEUI},
                #frame{data=Data},
                AName) ->
    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
    Map = #{
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
    SendFun = router_console:send_data_fun(DID, OUI),
    _ = SendFun(Map),
    ok.

-spec frame_to_packet_payload(#frame{}, #device{}) -> binary().
frame_to_packet_payload(Frame, Device) ->
    FOpts = lorawan_mac_commands:encode_fopts(Frame#frame.fopts),
    FOptsLen = erlang:byte_size(FOpts),
    PktHdr = <<(Frame#frame.mtype):3, 0:3, 0:2, (lorawan_utils:reverse(Frame#frame.devaddr))/binary, (Frame#frame.adr):1, 0:1, (Frame#frame.ack):1,
               (Frame#frame.fpending):1, FOptsLen:4, (Frame#frame.fcnt):16/integer-unsigned-little, FOpts:FOptsLen/binary>>,
    PktBody = case Frame#frame.data of
                  <<>> ->
                      %% no payload
                      <<>>;
                  <<Payload/binary>> when Frame#frame.fport == 0 ->
                      lager:debug("port 0 outbound"),
                      %% port 0 payload, encrypt with network key
                      <<0:8/integer-unsigned, (lorawan_utils:reverse(cipher(Payload, Device#device.nwk_s_key, 1, Frame#frame.devaddr, Frame#frame.fcnt)))/binary>>;
                  <<Payload/binary>> ->
                      lager:debug("port ~p outbound", [Frame#frame.fport]),
                      <<(Frame#frame.fport):8/integer-unsigned, (lorawan_utils:reverse(cipher(Payload, Device#device.app_s_key, 1, Frame#frame.devaddr, Frame#frame.fcnt)))/binary>>
              end,
    lager:debug("PktBody ~p, FOpts ~p", [PktBody, Frame#frame.fopts]),
    Msg = <<PktHdr/binary, PktBody/binary>>,
    MIC = crypto:cmac(aes_cbc128, Device#device.nwk_s_key, <<(b0(1, Frame#frame.devaddr, Frame#frame.fcnt, byte_size(Msg)))/binary, Msg/binary>>, 4),
    <<Msg/binary, MIC/binary>>.

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

-spec padded(integer(), binary()) -> binary().
padded(Bytes, Msg) ->
    case bit_size(Msg) rem (8*Bytes) of
        0 -> Msg;
        N -> <<Msg/bitstring, 0:(8*Bytes-N)>>
    end.

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

-spec mtype(integer()) -> string().
mtype(?JOIN_REQ) -> "Join request";
mtype(?JOIN_ACCEPT) -> "Join accept";
mtype(?UNCONFIRMED_UP) -> "Unconfirmed data up";
mtype(?UNCONFIRMED_DOWN) -> "Unconfirmed data down";
mtype(?CONFIRMED_UP) -> "Confirmed data up";
mtype(?CONFIRMED_DOWN) -> "Confirmed data down";
mtype(?RFU) -> "RFU";
mtype(?PRIORITY) -> "Proprietary".

-spec int_to_bin(integer()) -> binary().
int_to_bin(Int) ->
    erlang:list_to_binary(erlang:integer_to_list(Int)).


-spec get_device(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> {ok, #device{}} | {error, any()}.
get_device(DB, CF, AppEUI) ->
    case rocksdb:get(DB, CF, AppEUI, [{sync, true}]) of
        {ok, BinDevice} -> {ok, erlang:binary_to_term(BinDevice)};
        not_found -> {error, not_found};
        Error -> Error
    end.

-spec get_devices(rocksdb:db_handle(), rocksdb:cf_handle()) -> [#device{}].
get_devices(DB, CF) ->
    rocksdb:fold(
      DB,
      CF,
      fun({_Key, BinDevice}, Acc) ->
              [erlang:binary_to_term(BinDevice)|Acc]
      end,
      [],
      [{sync, true}]
     ).

-spec save_device(rocksdb:db_handle(), rocksdb:cf_handle(), #device{}) -> {ok, #device{}} | {error, any()}.
save_device(DB, CF, #device{mac=MAC, app_eui=AppEUI}=Device) ->
    case rocksdb:put(DB, CF, <<AppEUI/binary, MAC/binary>>, erlang:term_to_binary(Device), [{sync, true}]) of
        {error, _}=Error -> Error;
        ok -> {ok, Device}
    end.
