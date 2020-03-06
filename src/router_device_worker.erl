%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_worker).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("public_key/include/public_key.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
         start_link/1,
         handle_packet/2,
         queue_message/2,
         key/1
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
                device :: router_device:device(),
                join_cache = #{},
                frame_cache = #{}
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

-spec queue_message(pid(), {boolean(), integer(), binary()}) -> ok.
queue_message(Pid, Msg) ->
    gen_server:cast(Pid, {queue_message, Msg}).

-spec key(pid()) -> any().
key(Pid) ->
    gen_server:call(Pid, key).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    DB = maps:get(db, Args),
    CF = maps:get(cf, Args),
    ID = maps:get(id, Args),
    Device = case router_device:get(DB, CF, ID) of
                 {ok, D} -> D;
                 _ -> router_device:new(ID)
             end,
    {ok, #state{db=DB, cf=CF, device=Device}}.


handle_call(key, _From, #state{db=DB, cf=CF, device=Device0}=State) ->
    case router_device:key(Device0) of
        undefined ->
            Key = libp2p_crypto:generate_keys(ecc_compact),
            Device1 = router_device:key(Key, Device0),
            {ok, _} = router_device:save(DB, CF, Device1),
            {reply, Key, State#state{device=Device0}};
        Key ->
            {reply, Key, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({queue_message, {_Type, _Port, _Payload}=Msg}, #state{db=DB, cf=CF, device=Device0}=State) ->
    Q = router_device:queue(Device0),
    Device1 = router_device:queue(lists:append(Q, [Msg]), Device0),
    {ok, _} = router_device:save(DB, CF, Device1),
    {noreply, State#state{device=Device1}};
handle_cast({join, Packet0, PubkeyBin, AppKey, Name, Pid}, #state{device=Device0, join_cache=Cache0}=State0) ->
    case handle_join(Packet0, PubkeyBin, AppKey, Name, Device0) of
        {error, _Reason} ->
            {noreply, State0};
        {ok, Packet1, Device1, JoinNonce} ->
            RSSI0 = Packet0#packet_pb.signal_strength,
            Cache1 = maps:put(JoinNonce, {RSSI0, Packet1, Device1, Pid, PubkeyBin}, Cache0),
            State = State0#state{device=Device1},
            case maps:get(JoinNonce, Cache0, undefined) of
                undefined ->
                    _ = erlang:send_after(?JOIN_DELAY, self(), {join_timeout, JoinNonce}),
                    {noreply, State#state{join_cache=Cache1}};
                {RSSI1, _, _, _, Pid2} ->
                    case RSSI0 > RSSI1 of
                        false ->
                            catch Pid ! {packet, undefined},
                            {noreply, State};
                        true ->
                            catch Pid2 ! {packet, undefined},
                            {noreply, State#state{join_cache=Cache1}}
                    end
            end
    end;
handle_cast({frame, Packet0, PubkeyBin, Pid}, #state{device=Device0, frame_cache=Cache0}=State) ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    case handle_frame_packet(Packet0, AName, Device0) of
        {error, _Reason} ->
            {noreply, State};
        {ok, Frame, Device1} ->
            ok = send_to_channel(Packet0, Device1, Frame, AName),
            FCnt = router_device:fcnt(Device1),
            RSSI0 = Packet0#packet_pb.signal_strength,
            Cache1 = maps:put(FCnt, {RSSI0, Packet0, AName, Frame, Pid}, Cache0),
            case maps:get(FCnt, Cache0, undefined) of
                undefined ->
                    _ = erlang:send_after(?REPLY_DELAY, self(), {frame_timeout, FCnt}),
                    {noreply, State#state{frame_cache=Cache1, device=Device1}};
                {RSSI1, _, _, _, Pid2} ->
                    case RSSI0 > RSSI1 of
                        false ->
                            catch Pid ! {packet, undefined},
                            {noreply, State#state{device=Device1}};
                        true ->
                            catch Pid2 ! {packet, undefined},
                            {noreply, State#state{frame_cache=Cache1, device=Device1}}
                    end
            end
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({join_timeout, JoinNonce}, #state{db=DB, cf=CF, join_cache=Cache0}=State) ->
    {_, Packet, Device0, Pid, PubkeyBin} = maps:get(JoinNonce, Cache0, undefined),
    Pid ! {packet, Packet},
    Device1 = router_device:join_nonce(JoinNonce, Device0),
    {ok, _} = router_device:save(DB, CF, Device1),
    DevEUI = router_device:dev_eui(Device0),
    AppEUI = router_device:app_eui(Device0),
    StatusMsg = <<"Join attempt from AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
                  (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    ok = report_status(success, AName, StatusMsg, activation, 0, 0),
    Cache1 = maps:remove(JoinNonce, Cache0),
    {noreply, State#state{device=Device1, join_cache=Cache1}};
handle_info({frame_timeout, FCnt}, #state{db=DB, cf=CF, device=Device, frame_cache=Cache0}=State) ->
    {_, Packet0, AName, Frame, Pid} = maps:get(FCnt, Cache0, undefined),
    Cache1 = maps:remove(FCnt, Cache0),
    case handle_frame(Packet0, AName, Device, Frame) of
        {ok, Device1} ->
            {ok, _} = router_device:save(DB, CF, Device1),
            Pid ! {packet, undefined},
            {noreply, State#state{device=Device1, frame_cache=Cache1}};
        {send, Device1, Packet1} ->
            lager:info("sending downlink ~p", [Packet1]),
            {ok, _} = router_device:save(DB, CF, Device1),
            Pid ! {packet, Packet1},
            {noreply, State#state{device=Device1, frame_cache=Cache1}};
        noop ->
            Pid ! {packet, undefined},
            {noreply, State#state{frame_cache=Cache1}}
    end;
handle_info({report_status, Status, AName, Msg, Category, FCnt, FCntDown}, #state{device=Device}=State) ->
    case router_device:app_eui(Device) of
        undefined ->
            ok;
        _ ->
            ok = router_console:report_status(router_device:id(Device), Status, AName, Msg, Category, FCnt, FCntDown)
    end,
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%%-------------------------------------------------------------------
%% @doc
%% Handle packet_pb and figures out if JOIN_REQ or frame packet
%% @end
%%%-------------------------------------------------------------------
-spec handle_packet(#packet_pb{}, string(), pid()) -> ok | {error, any()}.
handle_packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                                    DevNonce:2/binary, MIC:4/binary>> = Payload}=Packet, PubkeyBin, Pid) when MType == ?JOIN_REQ ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload)-4}),
    case router_console:get_app_key_by_eui(DevEUI, AppEUI, Msg, MIC) of
        {Key, DeviceId, Name} ->
            case maybe_start_worker(DeviceId) of
                {error, _Reason}=Error ->
                    Error;
                {ok, WorkerPid} ->
                    gen_server:cast(WorkerPid, {join, Packet, PubkeyBin, Key, Name, Pid})
            end;
        false ->
            lager:debug("no key for ~p ~p received by ~s", [lorawan_utils:binary_to_hex(DevEUI),
                                                            lorawan_utils:binary_to_hex(AppEUI),
                                                            AName]),
            StatusMsg = <<"No device for AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary,
                          " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
            ok = report_status(failure, AName, StatusMsg, error, 0, 0),
            {error, undefined_app_key};
        undefined ->
            case throttle:check(join_dedup, {AppEUI, DevEUI, DevNonce}) of
                {ok, _, _} ->
                    lager:debug("Device ~s with AppEUI ~s tried to join through ~s but had a bad Message Intregity Code~n",
                                [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
                    ok;
                _ ->
                    ok
            end,
            {error, bad_mic}
    end;

handle_packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, DevAddr0:4/binary, _ADR:1, _ADRACKReq:1,
                                    _ACK:1, _RFU:1, FOptsLen:4, FCnt:16/little-unsigned-integer,
                                    _FOpts:FOptsLen/binary, PayloadAndMIC/binary>> =Payload}=Packet, PubkeyBin, Pid) ->
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) -4}),
    MIC = binary:part(PayloadAndMIC, {erlang:byte_size(PayloadAndMIC), -4}),
    DevAddr = lorawan_utils:reverse(DevAddr0),
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    {ok, DB, [_DefaultCF, CF]} = router_db:get(),
    case get_device_by_mic(router_device:get(DB, CF),
                           <<(b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Msg)))/binary, Msg/binary>>, MIC)  of
        undefined ->
            lager:debug("packet from unknown device ~s received by ~s", [lorawan_utils:binary_to_hex(DevAddr), AName]),
            {error, {unknown_device, lorawan_utils:binary_to_hex(DevAddr)}};
        Device ->
            DeviceId = router_device:id(Device),
            case maybe_start_worker(DeviceId) of
                {error, _Reason}=Error ->
                    Error;
                {ok, WorkerPid} ->
                    gen_server:cast(WorkerPid, {frame, Packet, PubkeyBin, Pid})
            end
    end;
handle_packet(#packet_pb{payload=Payload}, AName, _Pid) ->
    {error, {bad_packet, lorawan_utils:binary_to_hex(Payload), AName}}.

%%%-------------------------------------------------------------------
%% @doc
%% Maybe start a router device worker
%% @end
%%%-------------------------------------------------------------------
-spec maybe_start_worker(binary()) -> {ok, pid()} | {error, any()}.
maybe_start_worker(DeviceId) ->
    WorkerID = router_devices_sup:id(DeviceId),
    router_devices_sup:maybe_start_worker(WorkerID, #{}).

%%%-------------------------------------------------------------------
%% @doc
%% Handle join request, dedup multiple if needed, report statsus
%% to console and sends back join resp
%% @end
%%%-------------------------------------------------------------------
-spec handle_join(#packet_pb{}, libp2p_crypto:pubkey_to_bin(), binary(), binary(), router_device:device()) ->
          {ok, #packet_pb{}, router_device:device(), binary()} | {error, any()}.
handle_join(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, _AppEUI0:8/binary,
                                  _DevEUI0:8/binary, _Nonce:2/binary, _MIC:4/binary>>}=Packet,
            PubkeyBin, AppKey, Name, Device) when MType == ?JOIN_REQ ->
    handle_join(Packet, PubkeyBin, AppKey, Name, Device, router_device:join_nonce(Device));
handle_join(_Packet, _PubkeyBin, _AppKey, _Name, _Device) ->
    {error, not_join_req}.

-spec handle_join(#packet_pb{}, libp2p_crypto:pubkey_to_bin(), binary(), binary(), router_device:device(), non_neg_integer()) ->
          {ok, #packet_pb{}, router_device:device(), binary()} | {error, any()}.
handle_join(#packet_pb{payload= <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary,
                                  DevEUI0:8/binary, Nonce:2/binary, _MIC:4/binary>>},
            PubkeyBin, _AppKey, Name, _Device, OldNonce) when Nonce == OldNonce ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
    case throttle:check(join_dedup, {AppEUI, DevEUI, Nonce}) of
        {ok, _, _} ->
            lager:debug("Device ~s ~p ~p tried to join with stale nonce ~p via ~s", [Name, OUI, DID, Nonce, AName]),
            StatusMsg = <<"Stale join nonce ", (lorawan_utils:binary_to_hex(Nonce))/binary, " for AppEUI: ",
                          (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
            ok = report_status(failure, AName, StatusMsg, error, 0, 0);
        _ ->
            ok
    end,
    {error, bad_nonce};
handle_join(#packet_pb{oui=OUI, type=Type, timestamp=Time, frequency=Freq, datarate=DataRate,
                       payload= <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                                  DevNonce:2/binary, _MIC:4/binary>>},
            PubkeyBin, AppKey, Name, Device0, _OldNonce) ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubkeyBin)),
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    NetID = <<"He2">>,
    AppNonce = crypto:strong_rand_bytes(3),
    NwkSKey = crypto:block_encrypt(aes_ecb,
                                   AppKey,
                                   lorawan_utils:padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    AppSKey = crypto:block_encrypt(aes_ecb,
                                   AppKey,
                                   lorawan_utils:padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    DevAddr = <<OUI:32/integer-unsigned-big>>,
    RxDelay = ?RX_DELAY,
    DLSettings = 0,
    ReplyHdr = <<?JOIN_ACCEPT:3, 0:3, 0:2>>,
    ReplyPayload = <<AppNonce/binary, NetID/binary, DevAddr/binary, DLSettings:8/integer-unsigned, RxDelay:8/integer-unsigned>>,
    ReplyMIC = crypto:cmac(aes_cbc128, AppKey, <<ReplyHdr/binary, ReplyPayload/binary>>, 4),
    EncryptedReply = crypto:block_decrypt(aes_ecb, AppKey, lorawan_utils:padded(16, <<ReplyPayload/binary, ReplyMIC/binary>>)),
    Reply = <<ReplyHdr/binary, EncryptedReply/binary>>,
    #{tmst := TxTime,
      datr := TxDataRate,
      freq := TxFreq} = lorawan_mac_region_old:join1_window(<<"US902-928">>,
                                                            #{<<"tmst">> => Time,
                                                              <<"freq">> => Freq,
                                                              <<"datr">> => erlang:list_to_binary(DataRate),
                                                              <<"codr">> => <<"lol">>}),
    lager:info("Device ~s DevEUI ~s with AppEUI ~s tried to join with nonce ~p via ~s",
               [Name, lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), DevNonce, AName]),
    Packet = #packet_pb{oui=OUI, type=Type, payload=Reply, timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
    %% don't set the join nonce here yet as we have not chosen the best join request yet
    DeviceUpdates = [
                     {name, Name},
                     {dev_eui, DevEUI},
                     {app_eui, AppEUI},
                     {app_s_key, AppSKey},
                     {nwk_s_key, NwkSKey},
                     {fcntdown, 0},
                     {channel_correction, false}
                    ],
    Device1 = router_device:update(DeviceUpdates, Device0),
    {ok, Packet, Device1, DevNonce}.

%%%-------------------------------------------------------------------
%% @doc
%% Handle frame packet, figures out FPort/FOptsLen to see if
%% frame is valid and check if packet is ACKnowledging
%% previous packet sent 
%% @end
%%%-------------------------------------------------------------------
-spec handle_frame_packet(#packet_pb{}, string(), router_device:device()) -> {ok, #frame{}, router_device:device()} | {error, any()}.
handle_frame_packet(Packet, AName, Device0) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddrReversed:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
      FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Packet#packet_pb.payload,
    DevAddr = lorawan_utils:reverse(DevAddrReversed),
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    DevEUI = router_device:dev_eui(Device0),
    AppEUI = router_device:app_eui(Device0),
    case FPort of
        0 when FOptsLen == 0 ->
            NwkSKey = router_device:nwk_s_key(Device0),
            Data = lorawan_utils:reverse(lorawan_utils:cipher(FRMPayload, NwkSKey, MType band 1, DevAddr, FCnt)),
            lager:info("~s packet from ~s ~s with fopts ~p received by ~s",
                       [lorawan_utils:mtype(MType), lorawan_utils:binary_to_hex(DevEUI),
                        lorawan_utils:binary_to_hex(AppEUI), lorawan_mac_commands:parse_fopts(Data), AName]),
            {error, mac_command_not_handled};
        0 ->
            lager:debug("Bad ~s packet from ~s ~s received by ~s -- double fopts~n",
                        [lorawan_utils:mtype(MType), lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
            StatusMsg = <<"Packet with double fopts received from AppEUI: ",
                          (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
                          (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
            ok = report_status(failure, AName, StatusMsg, error, FCnt, router_device:fcntdown(Device0)),
            {error, double_fopts};
        _N ->
            AppSKey = router_device:app_s_key(Device0),
            Data = lorawan_utils:reverse(lorawan_utils:cipher(FRMPayload, AppSKey, MType band 1, DevAddr, FCnt)),
            lager:info("~s packet from ~s ~s with ACK ~p fopts ~p fcnt ~p and data ~p received by ~s",
                       [lorawan_utils:mtype(MType), lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI),
                        ACK, lorawan_mac_commands:parse_fopts(FOpts), FCnt, Data, AName]),
            %% If frame countain ACK=1 we should clear message from queue and go on next
            Device1 = case ACK of
                          0 ->
                              router_device:fcnt(FCnt, Device0);
                          1 ->
                              case router_device:queue(Device0) of
                                  %% Check if confirmed down link
                                  [{true, _, _}|T] ->
                                      DeviceUpdates = [
                                                       {fcnt, FCnt},
                                                       {queue, T},
                                                       {fcntdown, router_device:fcntdown(Device0)+1}
                                                      ],
                                      router_device:update(DeviceUpdates, Device0);
                                  _ ->
                                      lager:warning("Got ack when no confirmed downlinks in queue"),
                                      router_device:fcnt(FCnt, Device0)
                              end
                      end,
            Frame = #frame{mtype=MType, devaddr=DevAddr, adr=ADR, adrackreq=ADRACKReq, ack=ACK, rfu=RFU,
                           fcnt=FCnt, fopts=lorawan_mac_commands:parse_fopts(FOpts), fport=FPort, data=Data},
            {ok, Frame, Device1}
    end.

%%%-------------------------------------------------------------------
%% @doc
%% Check device's message queue to potentially wait or send reply
%% right away
%% @end
%%%-------------------------------------------------------------------
-spec handle_frame(#packet_pb{}, string(), router_device:device(), #frame{}) -> noop | {ok, router_device:device()} | {send,router_device:device(), #packet_pb{}}.
handle_frame(Packet, AName, Device, Frame) ->
    handle_frame(Packet, AName, Device, Frame, router_device:queue(Device)).

-spec handle_frame(#packet_pb{}, string(), router_device:device(), #frame{}, list()) -> noop | {ok, router_device:device()} | {send,router_device:device(), #packet_pb{}}.
handle_frame(Packet0, AName, Device0, Frame, []) ->
    ACK = mtype_to_ack(Frame#frame.mtype),
    WereChannelsCorrected = were_channels_corrected(Frame),
    ChannelCorrection = router_device:channel_correction(Device0),
    lager:info("downlink with no queue, ACK ~p and channels corrected ~p", [ACK, ChannelCorrection orelse WereChannelsCorrected]),
    case ACK of
        X when X == 1 orelse (ChannelCorrection == false andalso not WereChannelsCorrected) ->
            ConfirmedDown = false,
            Port = 0, %% Not sure about that?
            ok = report_frame_status(ACK, ConfirmedDown, Port, AName, Device0),
            {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(Packet0, Device0, Frame),
            case ChannelsCorrected andalso (ChannelCorrection == false) andalso (ACK == 0) of
                true ->
                    %% we corrected the channels but don't have anything else to send so just update the device
                    {ok, router_device:channel_correction(true, Device0)};
                false ->
                    FCntDown = router_device:fcntdown(Device0),
                    MType = ack_to_mtype(ConfirmedDown),
                    Reply = frame_to_packet_payload(#frame{mtype=MType, devaddr=Frame#frame.devaddr, fcnt=FCntDown, fopts=FOpts1, fport=Port, ack=ACK, data= <<>>},
                                                    Device0),
                    DataRate = Packet0#packet_pb.datarate,
                    #{tmst := TxTime, datr := TxDataRate, freq := TxFreq} =
                        lorawan_mac_region_old:rx1_window(<<"US902-928">>,
                                                          router_device:offset(Device0),
                                                          #{<<"tmst">> => Packet0#packet_pb.timestamp, <<"freq">> => Packet0#packet_pb.frequency,
                                                            <<"datr">> => erlang:list_to_binary(DataRate), <<"codr">> => <<"ignored">>}),
                    Packet1 = #packet_pb{oui=Packet0#packet_pb.oui, type=Packet0#packet_pb.type, payload=Reply,
                                         timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
                    DeviceUpdates = [
                                     {channel_correction, ChannelsCorrected},
                                     {fcntdown, (FCntDown + 1)}
                                    ],
                    Device1 = router_device:update(DeviceUpdates, Device0),
                    {send, Device1, Packet1}
            end;
        _ when ACK == 0 andalso ChannelCorrection == false andalso WereChannelsCorrected == true ->
            %% we corrected the channels but don't have anything else to send so just update the device
            {ok, router_device:channel_correction(true, Device0)};
        _ ->
            noop
    end;
handle_frame(Packet0, AName, Device0, Frame, [{ConfirmedDown, Port, ReplyPayload}|T]) ->
    ACK = mtype_to_ack(Frame#frame.mtype),
    MType = ack_to_mtype(ConfirmedDown),
    ok = report_frame_status(ACK, ConfirmedDown, Port, AName, Device0),
    WereChannelsCorrected = were_channels_corrected(Frame),
    lager:info("downlink with ~p, confirmed ~p port ~p ACK ~p and channels corrected ~p",
               [ReplyPayload, ConfirmedDown, Port, ACK, router_device:channel_correction(Device0) orelse WereChannelsCorrected]),
    {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(Packet0, Device0, Frame),
    FCntDown = router_device:fcntdown(Device0),
    FPending = case T of
                   [] ->
                       %% no more packets
                       0;
                   _ ->
                       %% more pending downlinks
                       1
               end,
    Reply = frame_to_packet_payload(#frame{mtype=MType, devaddr=Frame#frame.devaddr, fcnt=FCntDown, fopts=FOpts1, fport=Port, ack=ACK, data=ReplyPayload, fpending=FPending}, Device0),
    DataRate = Packet0#packet_pb.datarate,
    #{tmst := TxTime, datr := TxDataRate, freq := TxFreq} =
        lorawan_mac_region_old:rx1_window(<<"US902-928">>,
                                          router_device:offset(Device0),
                                          #{<<"tmst">> => Packet0#packet_pb.timestamp, <<"freq">> => Packet0#packet_pb.frequency,
                                            <<"datr">> => erlang:list_to_binary(DataRate), <<"codr">> => <<"ignored">>}),
    Packet1 = #packet_pb{oui=Packet0#packet_pb.oui, type=Packet0#packet_pb.type, payload=Reply,
                         timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
    case ConfirmedDown of
        true ->
            Device1 = router_device:channel_correction(ChannelsCorrected, Device0),
            {send, Device1, Packet1};
        false ->
            DeviceUpdates = [
                             {queue, T},
                             {channel_correction, ChannelsCorrected},
                             {fcntdown, (FCntDown + 1)}
                            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            {send, Device1, Packet1}
    end.

-spec channel_correction_and_fopts(#packet_pb{}, router_device:device(), #frame{}) -> {boolean(), list()}.
channel_correction_and_fopts(Packet, Device, Frame) ->
    ChannelsCorrected = were_channels_corrected(Frame),
    DataRate = Packet#packet_pb.datarate,
    ChannelCorrection = router_device:channel_correction(Device),
    ChannelCorrectionNeeded = ChannelCorrection == false,
    FOpts1 = case ChannelCorrectionNeeded andalso not ChannelsCorrected of
                 true -> lorawan_mac_region:set_channels(<<"US902">>, {0, erlang:list_to_binary(DataRate), [{48, 55}]}, []);
                 _ -> []
             end,
    {ChannelsCorrected orelse ChannelCorrection, FOpts1}.

were_channels_corrected(Frame) ->
    FOpts0 = Frame#frame.fopts,
    case lists:keyfind(link_adr_ans, 1, FOpts0) of
        {link_adr_ans, 1, 1, 1} ->
            true;
        {link_adr_ans, 1, 1, 0} ->
            lager:info("device rejected channel adjustment"),
            %% XXX we should get this to report_status somehow, but it's a bit tricky right now
            true;
        _ ->
            false
    end.

-spec mtype_to_ack(integer()) -> 0 | 1.
mtype_to_ack(?CONFIRMED_UP) -> 1;
mtype_to_ack(_) -> 0.

-spec ack_to_mtype(boolean()) -> integer().
ack_to_mtype(true) -> ?CONFIRMED_DOWN;
ack_to_mtype(_) -> ?UNCONFIRMED_DOWN.

-spec report_frame_status(integer(), boolean(), any(), string(), router_device:device()) -> ok.
report_frame_status(0, false, 0, AName, Device) ->
    FCnt = router_device:fcnt(Device),
    FCntDown = router_device:fcntdown(Device),
    StatusMsg = <<"Correcting channel mask in response to ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(success, AName, StatusMsg, down, FCnt, FCntDown);
report_frame_status(1, _ConfirmedDown, undefined, AName, Device) ->
    FCnt = router_device:fcnt(Device),
    FCntDown = router_device:fcntdown(Device),
    StatusMsg = <<"Sending ACK in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(success, AName, StatusMsg, ack, FCnt, FCntDown);
report_frame_status(1, true, _Port, AName, Device) ->
    FCnt = router_device:fcnt(Device),
    FCntDown = router_device:fcntdown(Device),
    StatusMsg = <<"Sending ACK and confirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(success, AName, StatusMsg, ack, FCnt, FCntDown);
report_frame_status(1, false, _Port, AName, Device) ->
    FCnt = router_device:fcnt(Device),
    FCntDown = router_device:fcntdown(Device),
    StatusMsg = <<"Sending ACK and unconfirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(success, AName, StatusMsg, ack, FCnt, FCntDown);
report_frame_status(_, true, _Port, AName, Device) ->
    FCnt = router_device:fcnt(Device),
    FCntDown = router_device:fcntdown(Device),
    StatusMsg = <<"Sending confirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(success, AName, StatusMsg, down, FCnt, FCntDown);
report_frame_status(_, false, _Port, AName, Device) ->
    FCnt = router_device:fcnt(Device),
    FCntDown = router_device:fcntdown(Device),
    StatusMsg = <<"Sending unconfirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(success, AName, StatusMsg, down, FCnt, FCntDown).

-spec report_status(atom(), string(), binary(), atom(), non_neg_integer(), non_neg_integer()) -> ok.
report_status(Type, AName, Msg, Category, FCnt, FCntDown) ->
    self() ! {report_status, Type, AName, Msg, Category, FCnt, FCntDown},
    ok.

-spec send_to_channel(#packet_pb{}, router_device:device(), #frame{}, string()) -> ok.
send_to_channel(#packet_pb{timestamp=Time, datarate=DataRate, signal_strength=RSSI, snr=SNR},
                Device,
                #frame{data=Data},
                AName) ->
    Map = #{
            miner_name => erlang:list_to_binary(AName),
            rssi => RSSI,
            snr => SNR,
            sequence => router_device:fcnt(Device),
            spreading => erlang:list_to_binary(DataRate),
            payload => Data,
            timestamp => Time,
            id => router_device:id(Device)
           },
    SendFun = router_console:send_data_fun(Device),
    _ = SendFun(Map),
    ok.

-spec frame_to_packet_payload(#frame{}, router_device:device()) -> binary().
frame_to_packet_payload(Frame, Device) ->
    FOpts = lorawan_mac_commands:encode_fopts(Frame#frame.fopts),
    FOptsLen = erlang:byte_size(FOpts),
    PktHdr = <<(Frame#frame.mtype):3, 0:3, 0:2, (lorawan_utils:reverse(Frame#frame.devaddr))/binary, (Frame#frame.adr):1, 0:1, (Frame#frame.ack):1,
               (Frame#frame.fpending):1, FOptsLen:4, (Frame#frame.fcnt):16/integer-unsigned-little, FOpts:FOptsLen/binary>>,
    NwkSKey = router_device:nwk_s_key(Device),
    PktBody = case Frame#frame.data of
                  <<>> ->
                      %% no payload
                      <<>>;
                  <<Payload/binary>> when Frame#frame.fport == 0 ->
                      lager:debug("port 0 outbound"),
                      %% port 0 payload, encrypt with network key
                      <<0:8/integer-unsigned, (lorawan_utils:reverse(lorawan_utils:cipher(Payload, NwkSKey, 1, Frame#frame.devaddr, Frame#frame.fcnt)))/binary>>;
                  <<Payload/binary>> ->
                      lager:debug("port ~p outbound", [Frame#frame.fport]),
                      AppSKey = router_device:app_s_key(Device),
                      EncPayload = lorawan_utils:reverse(lorawan_utils:cipher(Payload, AppSKey, 1, Frame#frame.devaddr, Frame#frame.fcnt)),
                      <<(Frame#frame.fport):8/integer-unsigned, EncPayload/binary>>
              end,
    lager:debug("PktBody ~p, FOpts ~p", [PktBody, Frame#frame.fopts]),
    Msg = <<PktHdr/binary, PktBody/binary>>,
    MIC = crypto:cmac(aes_cbc128, NwkSKey, <<(b0(1, Frame#frame.devaddr, Frame#frame.fcnt, byte_size(Msg)))/binary, Msg/binary>>, 4),
    <<Msg/binary, MIC/binary>>.

-spec get_device_by_mic([router_device:device()], binary(), binary()) -> router_device:device() | undefined.
get_device_by_mic([], _, _) ->
    undefined;
get_device_by_mic([Device|Tail], Bin, MIC) ->
    try
        NwkSKey = router_device:nwk_s_key(Device),
        case crypto:cmac(aes_cbc128, NwkSKey, Bin, 4) of
            MIC ->
                Device;
            _ ->
                get_device_by_mic(Tail, Bin, MIC)
        end
    catch _:_ ->
            lager:warning("skipping invalid device ~p", [Device]),
            get_device_by_mic(Tail, Bin, MIC)
    end.

-spec b0(integer(), binary(), integer(), integer()) -> binary().
b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (lorawan_utils:reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

-spec int_to_bin(integer()) -> binary().
int_to_bin(Int) ->
    erlang:list_to_binary(erlang:integer_to_list(Int)).
