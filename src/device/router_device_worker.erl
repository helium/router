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
-export([start_link/1,
         handle_packet/2,
         queue_message/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-define(SERVER, ?MODULE).
-define(BACKOFF_MAX, timer:minutes(5)).

-record(join_cache, {rssi :: float(),
                     packet :: #packet_pb{},
                     packet_rcvd :: #packet_pb{},
                     device :: router_device:device(),
                     pid :: pid(),
                     pubkey_bin :: libp2p_crypto:pubkey_bin()}).

-record(frame_cache, {rssi :: float(),
                      packet :: #packet_pb{},
                      pubkey_bin :: libp2p_crypto:pubkey_bin(),
                      frame :: #frame{},
                      pid :: pid()}).

-record(state, {db :: rocksdb:db_handle(),
                cf :: rocksdb:cf_handle(),
                device :: router_device:device(),
                channels_worker :: pid(),
                join_cache = #{} :: #{integer() => #join_cache{}},
                frame_cache = #{} :: #{integer() => #frame_cache{}}}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_packet(#packet_pb{}, libp2p_crypto:pubkey_bin()) -> ok.
handle_packet(Packet, PubKeyBin) ->
    case handle_packet(Packet, PubKeyBin, self()) of
        {error, _Reason} ->
            lager:info("failed to handle packet ~p : ~p", [Packet, _Reason]);
        ok ->
            ok
    end.

-spec queue_message(pid(), {boolean(), integer(), binary()}) -> ok.
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
    Device = get_device(DB, CF, ID),
    {ok, Pid} =
        router_device_channels_worker:start_link(#{device_worker => self(),
                                                   device => Device}),
    self() ! refresh_device_metadata,
    lager:md([{device_id, router_device:id(Device)}]),
    {ok, #state{db=DB, cf=CF, device=Device, channels_worker=Pid}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({queue_message, {_Type, _Port, _Payload}=Msg}, #state{db=DB, cf=CF, device=Device0,
                                                                  channels_worker=ChannelsWorker}=State) ->
    Q = router_device:queue(Device0),
    Device1 = router_device:queue(lists:append(Q, [Msg]), Device0),
    ok = save_and_update(DB, CF, ChannelsWorker, Device1),
    lager:debug("queue downlink message"),
    {noreply, State#state{device=Device1}};
handle_cast({join, Packet0, PubKeyBin, APIDevice, AppKey, Pid}, #state{device=Device0,
                                                                       join_cache=Cache0}=State0) ->
    case handle_join(Packet0, PubKeyBin, APIDevice, AppKey, Device0) of
        {error, _Reason} ->
            {noreply, State0};
        {ok, Packet1, Device1, JoinNonce} ->
            RSSI0 = Packet0#packet_pb.signal_strength,
            JoinCache = #join_cache{rssi=RSSI0,
                                    packet=Packet1,
                                    packet_rcvd=Packet0,
                                    device=Device1,
                                    pid=Pid,
                                    pubkey_bin=PubKeyBin},
            Cache1 = maps:put(JoinNonce, JoinCache, Cache0),
            State1 = State0#state{device=Device1},
            case maps:get(JoinNonce, Cache0, undefined) of
                undefined ->
                    _ = erlang:send_after(?JOIN_DELAY, self(), {join_timeout, JoinNonce}),
                    {noreply, State1#state{join_cache=Cache1}};
                #join_cache{rssi=RSSI1, pid=Pid2} ->
                    case RSSI0 > RSSI1 of
                        false ->
                            catch Pid ! {packet, undefined},
                            {noreply, State1};
                        true ->
                            catch Pid2 ! {packet, undefined},
                            {noreply, State1#state{join_cache=Cache1}}
                    end
            end
    end;
handle_cast({frame, Packet0, PubKeyBin, Pid}, #state{device=Device0,
                                                     frame_cache=Cache0,
                                                     channels_worker=ChannelsWorker}=State) ->
    case handle_frame_packet(Packet0, PubKeyBin, Device0) of
        {error, _Reason} ->
            {noreply, State};
        {ok, Frame, Device1} ->
            Data = {PubKeyBin, Packet0, Frame, erlang:system_time(second)},
            ok = router_device_channels_worker:handle_data(ChannelsWorker, Device1, Data),
            RSSI0 = Packet0#packet_pb.signal_strength,
            FCnt = router_device:fcnt(Device1),
            FrameCache = #frame_cache{rssi=RSSI0,
                                      packet=Packet0,
                                      pubkey_bin=PubKeyBin,
                                      frame=Frame,
                                      pid=Pid},
            Cache1 = maps:put(FCnt, FrameCache, Cache0),
            case maps:get(FCnt, Cache0, undefined) of
                undefined ->
                    _ = erlang:send_after(?REPLY_DELAY, self(), {frame_timeout, FCnt}),
                    {noreply, State#state{device=Device1, frame_cache=Cache1}};
                #frame_cache{rssi=RSSI1, pid=Pid2} ->
                    case RSSI0 > RSSI1 of
                        false ->
                            catch Pid ! {packet, undefined},
                            {noreply, State#state{device=Device1}};
                        true ->
                            catch Pid2 ! {packet, undefined},
                            {noreply, State#state{device=Device1, frame_cache=Cache1}}
                    end
            end
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({join_timeout, JoinNonce}, #state{db=DB, cf=CF, channels_worker=ChannelsWorker, join_cache=Cache0}=State) ->
    #join_cache{packet=Packet,
                packet_rcvd=PacketRcvd,
                device=Device0,
                pid=Pid,
                pubkey_bin=PubKeyBin} = maps:get(JoinNonce, Cache0),
    Pid ! {packet, Packet},
    Device1 = router_device:join_nonce(JoinNonce, Device0),
    ok = router_device_channels_worker:handle_join(ChannelsWorker),
    ok = save_and_update(DB, CF, ChannelsWorker, Device1),
    DevEUI = router_device:dev_eui(Device0),
    AppEUI = router_device:app_eui(Device0),
    Desc = <<"Join attempt from AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
             (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
    ok = report_status(activation, Desc, Device1, success, PubKeyBin, PacketRcvd, 0, <<>>),
    Cache1 = maps:remove(JoinNonce, Cache0),
    {noreply, State#state{device=Device1, join_cache=Cache1}};
handle_info({frame_timeout, FCnt}, #state{db=DB, cf=CF, device=Device,
                                          channels_worker=ChannelsWorker, frame_cache=Cache0}=State) ->
    #frame_cache{packet=Packet0,
                 pubkey_bin=PubKeyBin,
                 frame=Frame,
                 pid=Pid} = maps:get(FCnt, Cache0),
    Cache1 = maps:remove(FCnt, Cache0),
    case handle_frame(Packet0, PubKeyBin, Device, Frame) of
        {ok, Device1} ->
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            Pid ! {packet, undefined},
            {noreply, State#state{device=Device1, frame_cache=Cache1}};
        {send, Device1, Packet1} ->
            lager:info("sending downlink"),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            Pid ! {packet, Packet1},
            {noreply, State#state{device=Device1, frame_cache=Cache1}};
        noop ->
            Pid ! {packet, undefined},
            {noreply, State#state{frame_cache=Cache1}}
    end;
handle_info(refresh_device_metadata, #state{db=DB, cf=CF, device=Device0, channels_worker=ChannelsWorker}=State) ->
    _ = erlang:send_after(?BACKOFF_MAX, self(), refresh_device_metadata),
    DeviceID = router_device:id(Device0),
    case router_device_api:get_device(DeviceID) of
        {error, _Reason} ->
            lager:error("failed to get device ~p ~p", [DeviceID, _Reason]),
            {noreply, State};
        {ok, APIDevice} ->
            Device1 = router_device:metadata(router_device:metadata(APIDevice), Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            {noreply, State#state{device=Device1}}
    end;
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

-spec save_and_update(rocksdb:db_handle(), rocksdb:cf_handle(), pid(), router_device:device()) -> ok.
save_and_update(DB, CF, Pid, Device) ->
    {ok, _} = router_device:save(DB, CF, Device),
    ok = router_device_channels_worker:handle_device_update(Pid, Device).

-spec get_device(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> router_device:device().
get_device(DB, CF, ID) ->
    case router_device:get(DB, CF, ID) of
        {ok, D} -> D;
        _ -> router_device:new(ID)
    end.

%%%-------------------------------------------------------------------
%% @doc
%% Handle packet_pb and figures out if JOIN_REQ or frame packet
%% @end
%%%-------------------------------------------------------------------
-spec handle_packet(#packet_pb{}, string(), pid()) -> ok | {error, any()}.
handle_packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                                    _DevNonce:2/binary, MIC:4/binary>> = Payload}=Packet, PubKeyBin, Pid) when MType == ?JOIN_REQ ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload)-4}),
    case router_device_api:get_device(DevEUI, AppEUI, Msg, MIC) of
        {ok, APIDevice, AppKey} ->
            DeviceID = router_device:id(APIDevice),
            case maybe_start_worker(DeviceID) of
                {error, _Reason}=Error ->
                    Error;
                {ok, WorkerPid} ->
                    gen_server:cast(WorkerPid, {join, Packet, PubKeyBin, APIDevice, AppKey, Pid})
            end;
        {error, api_not_found} ->
            lager:debug("no key for ~p ~p received by ~s", [lorawan_utils:binary_to_hex(DevEUI),
                                                            lorawan_utils:binary_to_hex(AppEUI),
                                                            AName]),
            {error, undefined_app_key};
        {error, _Reason} ->
            lager:debug("Device ~s with AppEUI ~s tried to join through ~s but had a bad Message Intregity Code~n",
                        [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
            {error, bad_mic}
    end;

handle_packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, DevAddr0:4/binary, _ADR:1, _ADRACKReq:1,
                                    _ACK:1, _RFU:1, FOptsLen:4, FCnt:16/little-unsigned-integer,
                                    _FOpts:FOptsLen/binary, PayloadAndMIC/binary>> =Payload}=Packet, PubKeyBin, Pid) ->
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) -4}),
    MIC = binary:part(PayloadAndMIC, {erlang:byte_size(PayloadAndMIC), -4}),
    DevAddr = lorawan_utils:reverse(DevAddr0),
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
    {ok, DB, [_DefaultCF, CF]} = router_db:get(),
    case get_device_by_mic(router_device:get(DB, CF),
                           <<(b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Msg)))/binary, Msg/binary>>, MIC)  of
        undefined ->
            lager:debug("packet from unknown device ~s received by ~s", [lorawan_utils:binary_to_hex(DevAddr), AName]),
            {error, {unknown_device, lorawan_utils:binary_to_hex(DevAddr)}};
        Device ->
            DeviceID = router_device:id(Device),
            case maybe_start_worker(DeviceID) of
                {error, _Reason}=Error ->
                    Error;
                {ok, WorkerPid} ->
                    gen_server:cast(WorkerPid, {frame, Packet, PubKeyBin, Pid})
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
maybe_start_worker(DeviceID) ->
    WorkerID = router_devices_sup:id(DeviceID),
    router_devices_sup:maybe_start_worker(WorkerID, #{}).

%%%-------------------------------------------------------------------
%% @doc
%% Handle join request, dedup multiple if needed, report statsus
%% to console and sends back join resp
%% @end
%%%-------------------------------------------------------------------
-spec handle_join(#packet_pb{}, libp2p_crypto:pubkey_to_bin(), router_device:device(), binary(), router_device:device()) ->
          {ok, #packet_pb{}, router_device:device(), binary()} | {error, any()}.
handle_join(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, _AppEUI0:8/binary,
                                  _DevEUI0:8/binary, _Nonce:2/binary, _MIC:4/binary>>}=Packet,
            PubKeyBin, APIDevice, AppKey, Device) when MType == ?JOIN_REQ ->
    handle_join(Packet, PubKeyBin, APIDevice, AppKey, Device, router_device:join_nonce(Device));
handle_join(_Packet, _PubKeyBin, _APIDevice, _AppKey, _Device) ->
    {error, not_join_req}.

-spec handle_join(#packet_pb{}, libp2p_crypto:pubkey_to_bin(), router_device:device(), binary(), router_device:device(), non_neg_integer()) ->
          {ok, #packet_pb{}, router_device:device(), binary()} | {error, any()}.
handle_join(#packet_pb{payload= <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary,
                                  DevEUI0:8/binary, Nonce:2/binary, _MIC:4/binary>>},
            PubKeyBin, _APIDevice, _AppKey, _Device, OldNonce) when Nonce == OldNonce ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
    {AppEUI, _DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
    lager:warning("~p ~p tried to join with stale nonce ~p via ~s", [OUI, DID, Nonce, AName]),
    {error, bad_nonce};
handle_join(#packet_pb{oui=OUI, type=Type, timestamp=Time, frequency=Freq, datarate=DataRate,
                       payload= <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                                  DevNonce:2/binary, _MIC:4/binary>>},
            PubKeyBin, APIDevice, AppKey, Device0, _OldNonce) ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
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
    DeviceName = router_device:name(APIDevice),
    lager:info("DevEUI ~s with AppEUI ~s tried to join with nonce ~p via ~s",
               [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), DevNonce, AName]),
    Packet = #packet_pb{oui=OUI, type=Type, payload=Reply, timestamp=TxTime, datarate=TxDataRate, signal_strength=27, frequency=TxFreq},
    %% don't set the join nonce here yet as we have not chosen the best join request yet
    DeviceUpdates = [{name, DeviceName},
                     {dev_eui, DevEUI},
                     {app_eui, AppEUI},
                     {app_s_key, AppSKey},
                     {nwk_s_key, NwkSKey},
                     {fcntdown, 0},
                     {channel_correction, false},
                     {metadata, router_device:metadata(APIDevice)}],
    Device1 = router_device:update(DeviceUpdates, Device0),
    {ok, Packet, Device1, DevNonce}.

%%%-------------------------------------------------------------------
%% @doc
%% Handle frame packet, figures out FPort/FOptsLen to see if
%% frame is valid and check if packet is ACKnowledging
%% previous packet sent 
%% @end
%%%-------------------------------------------------------------------
-spec handle_frame_packet(#packet_pb{}, libp2p_crypto:pubkey_bin(), router_device:device()) -> {ok, #frame{}, router_device:device()} | {error, any()}.
handle_frame_packet(Packet, PubKeyBin, Device0) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddrReversed:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
      FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Packet#packet_pb.payload,
    DevAddr = lorawan_utils:reverse(DevAddrReversed),
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    DevEUI = router_device:dev_eui(Device0),
    AppEUI = router_device:app_eui(Device0),
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
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
            Desc = <<"Packet with double fopts received from AppEUI: ",
                     (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
                     (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
            ok = report_status(up, Desc, Device0, error, PubKeyBin, Packet, 0, DevAddr),
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
                                      DeviceUpdates = [{fcnt, FCnt},
                                                       {queue, T},
                                                       {fcntdown, router_device:fcntdown(Device0)+1}],
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
-spec handle_frame(#packet_pb{}, libp2p_crypto:pubkey_bin(), router_device:device(), #frame{}) -> noop | {ok, router_device:device()} | {send,router_device:device(), #packet_pb{}}.
handle_frame(Packet, PubKeyBin, Device, Frame) ->
    handle_frame(Packet, PubKeyBin, Device, Frame, router_device:queue(Device)).

-spec handle_frame(#packet_pb{}, libp2p_crypto:pubkey_bin(), router_device:device(), #frame{}, list()) -> noop | {ok, router_device:device()} | {send,router_device:device(), #packet_pb{}}.
handle_frame(Packet0, PubKeyBin, Device0, Frame, []) ->
    ACK = mtype_to_ack(Frame#frame.mtype),
    WereChannelsCorrected = were_channels_corrected(Frame),
    ChannelCorrection = router_device:channel_correction(Device0),
    lager:info("downlink with no queue, ACK ~p and channels corrected ~p", [ACK, ChannelCorrection orelse WereChannelsCorrected]),
    case ACK of
        X when X == 1 orelse (ChannelCorrection == false andalso not WereChannelsCorrected) ->
            {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(Packet0, Device0, Frame),
            case ChannelsCorrected andalso (ChannelCorrection == false) andalso (ACK == 0) of
                true ->
                    %% we corrected the channels but don't have anything else to send so just update the device
                    {ok, router_device:channel_correction(true, Device0)};
                false ->
                    ConfirmedDown = false,
                    Port = 0,
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
                    DeviceUpdates = [{channel_correction, ChannelsCorrected},
                                     {fcntdown, (FCntDown + 1)}],
                    Device1 = router_device:update(DeviceUpdates, Device0),
                    ok = report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Device1, Packet0, Frame),
                    {send, Device1, Packet1}
            end;
        _ when ACK == 0 andalso ChannelCorrection == false andalso WereChannelsCorrected == true ->
            %% we corrected the channels but don't have anything else to send so just update the device
            {ok, router_device:channel_correction(true, Device0)};
        _ ->
            noop
    end;
handle_frame(Packet0, PubKeyBin, Device0, Frame, [{ConfirmedDown, Port, ReplyPayload}|T]) ->
    ACK = mtype_to_ack(Frame#frame.mtype),
    MType = ack_to_mtype(ConfirmedDown),
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
            ok = report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Device1, Packet0, Frame),
            {send, Device1, Packet1};
        false ->
            DeviceUpdates = [{queue, T},
                             {channel_correction, ChannelsCorrected},
                             {fcntdown, (FCntDown + 1)}],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Device1, Packet0, Frame),
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

-spec report_frame_status(integer(), boolean(), any(), libp2p_crypto:pubkey_bin(),
                          router_device:device(), #packet_pb{}, #frame{}) -> ok.
report_frame_status(0, false, 0, PubKeyBin, Device, Packet, #frame{devaddr=DevAddr, fport=FPort}) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Correcting channel mask in response to ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(down, Desc, Device, success, PubKeyBin, Packet, FPort, DevAddr);
report_frame_status(1, _ConfirmedDown, undefined, PubKeyBin, Device, Packet, #frame{devaddr=DevAddr, fport=FPort}) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(ack, Desc, Device, success, PubKeyBin, Packet, FPort, DevAddr);
report_frame_status(1, true, _Port, PubKeyBin, Device, Packet, #frame{devaddr=DevAddr, fport=FPort}) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK and confirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(ack, Desc, Device, success, PubKeyBin, Packet, FPort, DevAddr);
report_frame_status(1, false, _Port, PubKeyBin, Device, Packet, #frame{devaddr=DevAddr, fport=FPort}) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK and unconfirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(ack, Desc, Device, success, PubKeyBin, Packet, FPort, DevAddr);
report_frame_status(_, true, _Port, PubKeyBin, Device, Packet, #frame{devaddr=DevAddr, fport=FPort}) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending confirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(down, Desc, Device, success, PubKeyBin, Packet, FPort, DevAddr);
report_frame_status(_, false, _Port, PubKeyBin, Device, Packet, #frame{devaddr=DevAddr, fport=FPort}) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending unconfirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(down, Desc, Device, success, PubKeyBin, Packet, FPort, DevAddr).

-spec report_status(atom(), binary(), router_device:device(), success | error,
                    libp2p_crypto:pubkey_bin(), #packet_pb{}, any(), any()) -> ok.
report_status(Category, Desc, Device, Status, PubKeyBin, Packet, Port, DevAddr) ->
    HotspotID = libp2p_crypto:bin_to_b58(PubKeyBin),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(HotspotID),
    Report = #{category => Category,
               description => Desc,
               reported_at => erlang:system_time(seconds),
               payload => <<>>,
               payload_size => 0,
               port => Port,
               devaddr => lorawan_utils:binary_to_hex(DevAddr),
               hotspots => [#{id => erlang:list_to_binary(HotspotID),
                              name => erlang:list_to_binary(HotspotName),
                              reported_at => erlang:system_time(seconds),
                              status => Status,
                              rssi => Packet#packet_pb.signal_strength,
                              snr => Packet#packet_pb.snr,
                              spreading => erlang:list_to_binary(Packet#packet_pb.datarate),
                              frequency => Packet#packet_pb.frequency}],
               channels => []},
    ok = router_device_api:report_status(Device, Report).

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
