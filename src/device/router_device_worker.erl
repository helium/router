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
-include("lorawan_db.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         handle_join/8,
         handle_frame/6,
         queue_message/2,
         device_update/1,
         is_active/1, is_active/2]).

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
-define(BITS_23, 8388607). %% biggest unsigned number in 23 bits
-define(MAX_DOWNLINK_SIZE, 242).
-define(NET_ID, <<"He2">>).

-record(join_cache, {rssi :: float(),
                     reply :: binary(),
                     packet_selected :: {blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom()},
                     packets = [] :: [{blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom()}],
                     device :: router_device:device(),
                     pid :: pid()}).

-record(frame_cache, {rssi :: float(),
                      count = 1 :: pos_integer(),
                      packet :: blockchain_helium_packet_v1:packet(),
                      pubkey_bin :: libp2p_crypto:pubkey_bin(),
                      frame :: #frame{},
                      pid :: pid(),
                      region :: atom()}).

-record(state, {chain :: blockchain:blockchain(),
                db :: rocksdb:db_handle(),
                cf :: rocksdb:cf_handle(),
                device :: router_device:device(),
                downlink_handled_at = -1 :: integer(),
                join_nonce_handled_at = <<>> :: binary(),
                oui :: undefined | non_neg_integer(),
                channels_worker :: pid(),
                join_cache = #{} :: #{integer() => #join_cache{}},
                frame_cache = #{} :: #{integer() => #frame_cache{}},
                is_active = true ::boolean()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_join(pid(), blockchain_helium_packet_v1:packet(), pos_integer(), libp2p_crypto:pubkey_bin(), atom(),
                  router_device:device(), binary(), pid()) -> ok.
handle_join(WorkerPid, Packet, PacketTime, PubKeyBin, Region, APIDevice, AppKey, Pid) ->
    gen_server:cast(WorkerPid, {join, Packet, PacketTime, PubKeyBin, Region, APIDevice, AppKey, Pid}).

-spec handle_frame(pid(), blockchain_helium_packet_v1:packet(), pos_integer(), libp2p_crypto:pubkey_bin(), atom(), pid()) -> ok.
handle_frame(WorkerPid, Packet, PacketTime, PubKeyBin, Region, Pid) ->
    gen_server:cast(WorkerPid, {frame, Packet, PacketTime, PubKeyBin, Region, Pid}).

-spec queue_message(pid(), {boolean(), integer(), binary()}) -> ok.
queue_message(Pid, Msg) ->
    gen_server:cast(Pid, {queue_message, Msg}).

-spec device_update(Pid :: pid()) -> ok.
device_update(Pid) ->
    gen_server:cast(Pid, device_update).

-spec is_active(Pid :: pid()) -> boolean().
is_active(Pid) ->
    gen_server:call(Pid, is_active).

-spec is_active(Pid :: pid(), boolean()) -> ok.
is_active(Pid, IsActive) ->
    gen_server:cast(Pid, {is_active, IsActive}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{db := DB, cf := CF, id := ID}=Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Blockchain = blockchain_worker:blockchain(),
    OUI = router_device_utils:get_router_oui(),
    Device = get_device(DB, CF, ID),
    {ok, Pid} =
        router_device_channels_worker:start_link(#{blockchain => Blockchain,
                                                   device_worker => self(),
                                                   device => Device}),
    IsActive = router_device:is_active(Device),
    lager:md([{device_id, router_device:id(Device)}]),
    {ok, #state{chain=Blockchain, db=DB, cf=CF, device=Device,
                oui=OUI, channels_worker=Pid, is_active=IsActive}}.

handle_call(is_active, _From, #state{is_active=IsActive}=State) ->
    {reply, IsActive, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(device_update, #state{db=DB, cf=CF, device=Device0, channels_worker=ChannelsWorker}=State) ->
    DeviceID = router_device:id(Device0),
    case router_device_api:get_device(DeviceID) of
        {error, not_found} ->
            ok = router_device:delete(DB, CF, DeviceID),
            lager:info("device was removed, removing from DB and shutting down"),
            {stop, normal, State};
        {error, _Reason} ->
            lager:error("failed to update device ~p", [_Reason]),
            {noreply, State};
        {ok, APIDevice} ->
            lager:info("device updated: ~p", [APIDevice]),
            ChannelsWorker ! refresh_channels,
            IsActive = router_device:is_active(APIDevice),
            DeviceUpdates = [{name, router_device:name(APIDevice)},
                             {dev_eui, router_device:dev_eui(APIDevice)},
                             {app_eui, router_device:app_eui(APIDevice)},
                             {metadata, router_device:metadata(APIDevice)},
                             {is_active, IsActive}],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            {noreply, State#state{device=Device1, is_active=IsActive}}
    end;
handle_cast({queue_message, {_Type, Port, Payload}=Msg}, #state{db=DB, cf=CF, device=Device0,
                                                                channels_worker=ChannelsWorker}=State) ->
    case erlang:byte_size(Payload) of
        Size when Size > ?MAX_DOWNLINK_SIZE ->
            ok = router_device_utils:report_status_max_size(Device0, Payload, Port),
            lager:debug("failed to queue downlink message, too big (~p)", [Size]),
            {noreply, State};
        _ ->
            Q = router_device:queue(Device0),
            Device1 = router_device:queue(lists:append(Q, [Msg]), Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            lager:debug("queued downlink message"),
            {noreply, State#state{device=Device1}}
    end;
handle_cast({join, _Packet0, _PubKeyBin, _APIDevice, _AppKey, _Pid}, #state{oui=undefined}=State0) ->
    lager:warning("got join packet when oui=undefined"),
    {noreply, State0};
handle_cast({join, Packet0, PacketTime, PubKeyBin, Region, APIDevice, AppKey, Pid}, #state{chain=Chain, db=DB, cf=CF, device=Device0, join_cache=Cache0,
                                                                                           join_nonce_handled_at=JoinNonceHandledAt, oui=OUI,
                                                                                           channels_worker=ChannelsWorker}=State0) ->
    %% TODO we should really just call this once per join nonce
    %% and have a seperate function for getting the join nonce so we can check
    %% the cache
    case validate_join(Packet0, PubKeyBin, Region, OUI, APIDevice, AppKey, Device0, Chain) of
        {error, _Reason} ->
            lager:debug("failed to validate join ~p", [_Reason]),
            {noreply, State0};
        {ok, Device1, JoinNonce, Reply} ->
            NewRSSI = blockchain_helium_packet_v1:signal_strength(Packet0),
            case maps:get(JoinNonce, Cache0, undefined) of
                undefined when JoinNonceHandledAt == JoinNonce ->
                    lager:debug("got a late join: ~p (old: ~p)", [JoinNonce, JoinNonceHandledAt]),
                    {noreply, State0};
                undefined ->
                    lager:debug("got a first join: ~p", [JoinNonce]),
                    JoinCache = #join_cache{rssi=NewRSSI,
                                            reply=Reply,
                                            packet_selected={Packet0, PubKeyBin, Region},
                                            device=Device1,
                                            pid=Pid},
                    Cache1 = maps:put(JoinNonce, JoinCache, Cache0),
                    State1 = State0#state{device=Device1},
                    ok = save_and_update(DB, CF, ChannelsWorker, Device1),
                    _ = erlang:send_after(max(0, ?JOIN_DELAY - (erlang:system_time(millisecond) - PacketTime)), self(), {join_timeout, JoinNonce}),
                    {noreply, State1#state{join_cache=Cache1, join_nonce_handled_at=JoinNonce, downlink_handled_at= -1}};
                #join_cache{rssi=OldRSSI, packet_selected={OldPacket, _, _}=OldSelected, packets=OldPackets, pid=OldPid}=JoinCache1 ->
                    case NewRSSI > OldRSSI of
                        false ->
                            lager:debug("got another join for ~p with worst RSSI ~p", [JoinNonce, {NewRSSI, OldRSSI}]),
                            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true)),
                            Cache1 = maps:put(JoinNonce, JoinCache1#join_cache{packets=[{Packet0, PubKeyBin, Region}|OldPackets]}, Cache0),
                            {noreply, State0#state{join_cache=Cache1}};
                        true ->
                            lager:debug("got a another join for ~p with better RSSI ~p", [JoinNonce, {NewRSSI, OldRSSI}]),
                            catch blockchain_state_channel_handler:send_response(OldPid, blockchain_state_channel_response_v1:new(true)),
                            NewPackets = [OldSelected|lists:keydelete(OldPacket, 1, OldPackets)],
                            Cache1 = maps:put(JoinNonce, JoinCache1#join_cache{rssi=NewRSSI, packet_selected={Packet0, PubKeyBin, Region},
                                                                               packets=NewPackets, pid=Pid}, Cache0),
                            {noreply, State0#state{join_cache=Cache1}}
                    end
            end
    end;
handle_cast({frame, Packet, _PacketTime, _PubKeyBin, _Region, _Pid}, #state{device=Device,
                                                                            is_active=false}=State) ->
    _ = router_device_routing:deny_more(Packet),
    ok = router_device_utils:report_status_inactive(Device),
    {noreply, State};
handle_cast({frame, Packet0, PacketTime, PubKeyBin, Region, Pid}, #state{chain=Blockchain,
                                                                         device=Device0,
                                                                         frame_cache=Cache0,
                                                                         downlink_handled_at=DownlinkHandledAt,
                                                                         channels_worker=ChannelsWorker}=State) ->
    case validate_frame(Packet0, PubKeyBin, Region, Device0, Blockchain) of
        {error, {not_enough_dc, _Reason, Device1}} ->
            ok = router_device_utils:report_status_no_dc(Device0),
            lager:debug("did not have enough dc (~p) to send data", [_Reason]),
            _ = router_device_routing:deny_more(Packet0),
            {noreply, State#state{device=Device1}};
        {error, _Reason} ->
            _ = router_device_routing:deny_more(Packet0),
            {noreply, State};
        {ok, Frame, Device1, SendToChannels, {Balance, Nonce}} ->
            FrameAck = Frame#frame.ack,
            case router_device:queue(Device1) == [] orelse FrameAck == 1 of
                false -> router_device_routing:deny_more(Packet0);
                true -> router_device_routing:accept_more(Packet0)
            end,
            Data = {PubKeyBin, Packet0, Frame, Region, erlang:system_time(second)},
            case SendToChannels of
                true ->
                    ok = router_device_channels_worker:handle_data(ChannelsWorker, Device1, Data, {Balance, Nonce});
                false ->
                    ok
            end,
            RSSI0 = blockchain_helium_packet_v1:signal_strength(Packet0),
            FCnt = router_device:fcnt(Device1),
            FrameCache = #frame_cache{rssi=RSSI0,
                                      packet=Packet0,
                                      pubkey_bin=PubKeyBin,
                                      frame=Frame,
                                      pid=Pid,
                                      region=Region  },
            case maps:get(FCnt, Cache0, undefined) of
                undefined when FCnt =< DownlinkHandledAt andalso
                               %% devices will retransmit with an old fcnt if they're looking for an ack
                               %% so check that is not the case here
                               FrameAck == 0 ->
                    %% late packet
                    {noreply, State};
                undefined ->
                    _ = erlang:send_after(max(0, ?REPLY_DELAY - (erlang:system_time(millisecond) - PacketTime)), self(), {frame_timeout, FCnt}),
                    Cache1 = maps:put(FCnt, FrameCache, Cache0),
                    {noreply, State#state{device=Device1, frame_cache=Cache1, downlink_handled_at=FCnt}};
                #frame_cache{rssi=RSSI1, pid=Pid2, count=Count}=FrameCache0 ->
                    case RSSI0 > RSSI1 of
                        false ->
                            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true)),
                            Cache1 = maps:put(FCnt, FrameCache0#frame_cache{count=Count+1}, Cache0),
                            {noreply, State#state{device=Device1, frame_cache=Cache1}};
                        true ->
                            catch blockchain_state_channel_handler:send_response(Pid2, blockchain_state_channel_response_v1:new(true)),
                            Cache1 = maps:put(FCnt, FrameCache#frame_cache{count=Count+1}, Cache0),
                            {noreply, State#state{device=Device1, frame_cache=Cache1}}
                    end
            end
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({join_timeout, JoinNonce}, #state{chain=Blockchain, db=DB, cf=CF,
                                              channels_worker=ChannelsWorker, join_cache=JoinCache}=State) ->
    #join_cache{reply=Reply,
                packet_selected=PacketSelected,
                packets=Packets,
                device=Device0,
                pid=Pid} = maps:get(JoinNonce, JoinCache),
    {Packet, _, Region} = PacketSelected,
    lager:debug("join timeout for ~p / selected ~p out of ~p", [JoinNonce,
                                                                lager:pr(Packet, blockchain_helium_packet_v1),
                                                                erlang:length(Packets) + 1]),
    #txq{time = TxTime,
         datr = TxDataRate,
         freq = TxFreq} = lorawan_mac_region:join1_window(Region, 0,
                                                          packet_to_rxq(Packet)),
    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(Reply, TxTime, 27, TxFreq, binary_to_list(TxDataRate)),
    catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true, DownlinkPacket)),
    Device1 = router_device:join_nonce(JoinNonce, Device0),
    ok = router_device_channels_worker:handle_join(ChannelsWorker),
    ok = save_and_update(DB, CF, ChannelsWorker, Device1),
    ok = router_device_utils:report_join_status(Device1, PacketSelected, Packets, Blockchain),
    {noreply, State#state{device=Device1, join_cache= maps:remove(JoinNonce, JoinCache)}};
handle_info({frame_timeout, FCnt}, #state{chain=Blockchain, db=DB, cf=CF, device=Device,
                                          channels_worker=ChannelsWorker, frame_cache=Cache0}=State) ->
    #frame_cache{packet=Packet,
                 pubkey_bin=PubKeyBin,
                 frame=Frame,
                 count=Count,
                 pid=Pid,
                 region=Region} = maps:get(FCnt, Cache0),
    Cache1 = maps:remove(FCnt, Cache0),
    ok = router_device_routing:clear_multy_buy(Packet),
    lager:debug("frame timeout for ~p / device ~p", [FCnt, lager:pr(Device, router_device)]),
    DeviceID = router_device:id(Device),
    case handle_frame_timeout(Packet, PubKeyBin, Region, Device, Frame, Count, Blockchain) of
        {ok, Device1} ->
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true)),
            router_device_routing:clear_replay(DeviceID),
            {noreply, State#state{device=Device1, frame_cache=Cache1}};
        {send, Device1, DownlinkPacket} ->
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            lager:info("sending downlink for fcnt: ~p", [FCnt]),
            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true, DownlinkPacket)),
            case mtype_to_ack(Frame#frame.mtype) of
                1 -> router_device_routing:allow_replay(Packet, DeviceID);
                _ -> router_device_routing:clear_replay(DeviceID)
            end,
            {noreply, State#state{device=Device1, frame_cache=Cache1}};
        noop ->
            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true)),
            router_device_routing:clear_replay(DeviceID),
            {noreply, State#state{frame_cache=Cache1}}
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

-spec validate_join(blockchain_helium_packet_v1:packet(),
                    libp2p_crypto:pubkey_to_bin(),
                    atom(),
                    non_neg_integer(),
                    router_device:device(),
                    binary(),
                    router_device:device(),
                    blockchain:blockchain()) -> {ok, router_device:device(), binary(), binary()} | {error, any()}.
validate_join(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, _AppEUI0:8/binary,
                                    _DevEUI0:8/binary, Nonce:2/binary, _MIC:4/binary>>=Payload}=Packet,
              PubKeyBin, Region, OUI, APIDevice, AppKey, Device, Blockchain) when MType == ?JOIN_REQ ->
    PayloadSize = erlang:byte_size(Payload),
    case router_console_dc_tracker:charge(Device, PayloadSize, Blockchain) of
        {error, _}=Error ->
            Error;
        {ok, _, _} ->
            case Nonce == router_device:join_nonce(Device) of
                true ->
                    {error, bad_nonce};
                false ->
                    handle_join(Packet, PubKeyBin, Region, OUI, APIDevice, AppKey, Device)
            end
    end;
validate_join(_Packet, _PubKeyBin, _Region, _OUI, _APIDevice, _AppKey, _Device, _Blockchain) ->
    {error, not_join_req}.

%%%-------------------------------------------------------------------
%% @doc
%% Handle join request, dedup multiple if needed, report statsus
%% to console and sends back join resp
%% @end
%%%-------------------------------------------------------------------
-spec handle_join(blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_to_bin(), atom(),
                  non_neg_integer(), router_device:device(), binary(), router_device:device()) -> {ok, router_device:device(), binary(), binary()}.
handle_join(#packet_pb{payload= <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, JoinNonce:2/binary, _MIC:4/binary>>},
            PubKeyBin, Region, _OUI, APIDevice, AppKey, Device0) ->
    AppNonce = crypto:strong_rand_bytes(3),
    NwkSKey = crypto:block_encrypt(aes_ecb,
                                   AppKey,
                                   lorawan_utils:padded(16, <<16#01, AppNonce/binary, ?NET_ID/binary, JoinNonce/binary>>)),
    AppSKey = crypto:block_encrypt(aes_ecb,
                                   AppKey,
                                   lorawan_utils:padded(16, <<16#02, AppNonce/binary, ?NET_ID/binary, JoinNonce/binary>>)),
    DevAddr = case router_device_devaddr:allocate(Device0, PubKeyBin) of
                  {ok, D} ->
                      D;
                  {error, _Reason} ->
                      lager:warning("failed to allocate devaddr for ~p: ~p", [router_device:id(Device0), _Reason]),
                      router_device_devaddr:default_devaddr()
              end,
    DeviceName = router_device:name(APIDevice),
    %% don't set the join nonce here yet as we have not chosen the best join request yet
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    DeviceUpdates = [{name, DeviceName},
                     {dev_eui, DevEUI},
                     {app_eui, AppEUI},
                     {app_s_key, AppSKey},
                     {nwk_s_key, NwkSKey},
                     {devaddr, DevAddr},
                     {fcntdown, 0},
                     {channel_correction, Region /= 'US915'}, %% only do channel correction for 915 right now
                     {location, PubKeyBin},
                     {metadata, router_device:metadata(APIDevice)}],
    Device1 = router_device:update(DeviceUpdates, Device0),
    Reply = craft_join_reply(Region, AppNonce, DevAddr, AppKey),
    lager:debug("DevEUI ~s with AppEUI ~s tried to join with nonce ~p via ~s",
                [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI),
                 JoinNonce, blockchain_utils:addr2name(PubKeyBin)]),
    {ok, Device1, JoinNonce, Reply}.

-spec craft_join_reply(atom(), binary(), binary(), binary()) -> binary().
craft_join_reply(Region, AppNonce, DevAddr, AppKey) ->
    DLSettings = 0,
    ReplyHdr = <<?JOIN_ACCEPT:3, 0:3, 0:2>>,
    CFList = case Region of
                 'EU868' ->
                     %% In this case the CFList is a list of five channel frequencies for the channels three to seven
                     %% whereby each frequency is encoded as a 24 bits unsigned integer (three octets). All these
                     %% channels are usable for DR0 to DR5 125kHz LoRa modulation. The list of frequencies is
                     %% followed by a single CFListType octet for a total of 16 octets. The CFListType SHALL be equal
                     %% to zero (0) to indicate that the CFList contains a list of frequencies.
                     %%
                     %% The actual channel frequency in Hz is 100 x frequency whereby values representing
                     %% frequencies below 100 MHz are reserved for future use.
                     Channels = << <<X:24/integer-unsigned-little >> || X <- [8671000, 8673000, 8675000, 8677000, 8679000] >>,
                     <<Channels/binary, 0:8/integer>>;
                 _ ->
                     %% Not yet implemented for other regions
                     <<>>
             end,
    ReplyPayload = <<AppNonce/binary, ?NET_ID/binary, DevAddr/binary, DLSettings:8/integer-unsigned, ?RX_DELAY:8/integer-unsigned, CFList/binary>>,
    ReplyMIC = crypto:cmac(aes_cbc128, AppKey, <<ReplyHdr/binary, ReplyPayload/binary>>, 4),
    EncryptedReply = crypto:block_decrypt(aes_ecb, AppKey, lorawan_utils:padded(16, <<ReplyPayload/binary, ReplyMIC/binary>>)),
    <<ReplyHdr/binary, EncryptedReply/binary>>.

%%%-------------------------------------------------------------------
%% @doc
%% Validate frame packet, figures out FPort/FOptsLen to see if
%% frame is valid and check if packet is ACKnowledging
%% previous packet sent
%% @end
%%%-------------------------------------------------------------------
-spec validate_frame(blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom(),
                     router_device:device(), blockchain:blockchain()) ->
          {ok, #frame{}, router_device:device(), boolean(), {non_neg_integer(), non_neg_integer()}} | {error, any()}.
validate_frame(Packet, PubKeyBin, Region, Device0, Blockchain) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
      FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    DevEUI = router_device:dev_eui(Device0),
    AppEUI = router_device:app_eui(Device0),
    AName = blockchain_utils:addr2name(PubKeyBin),
    TS = blockchain_helium_packet_v1:timestamp(Packet),
    lager:debug("validating frame ~p @ ~p (devaddr: ~p) from ~p", [FCnt, TS, DevAddr, AName]),
    PayloadSize = erlang:byte_size(FRMPayload),
    case router_console_dc_tracker:charge(Device0, PayloadSize, Blockchain) of
        {error, Reason} ->
            DeviceUpdates = [{fcnt, FCnt}, {location, PubKeyBin}],
            Device1 = router_device:update(DeviceUpdates, Device0),
            case FPort of
                0 when FOptsLen == 0 ->
                    {error, {not_enough_dc, Reason, Device1}};
                0 when FOptsLen /= 0 ->
                    {error, {not_enough_dc, Reason, Device0}};
                _N ->
                    {error, {not_enough_dc, Reason, Device1}}
            end;
        {ok, Balance, Nonce} ->
            case FPort of
                0 when FOptsLen == 0 ->
                    NwkSKey = router_device:nwk_s_key(Device0),
                    Data = lorawan_utils:reverse(lorawan_utils:cipher(FRMPayload, NwkSKey, MType band 1, DevAddr, FCnt)),
                    lager:info("~s packet from ~s ~s with fopts ~p received by ~s",
                               [lorawan_utils:mtype(MType), lorawan_utils:binary_to_hex(DevEUI),
                                lorawan_utils:binary_to_hex(AppEUI), lorawan_mac_commands:parse_fopts(Data), AName]),
                    %% If frame countain ACK=1 we should clear message from queue and go on next
                    Device1 = case ACK of
                                  0 ->
                                      DeviceUpdates = [{fcnt, FCnt},
                                                       {location, PubKeyBin}],
                                      router_device:update(DeviceUpdates, Device0);
                                  1 ->
                                      case router_device:queue(Device0) of
                                          %% Check if confirmed down link
                                          [{true, _, _}|T] ->
                                              DeviceUpdates = [{fcnt, FCnt},
                                                               {queue, T},
                                                               {location, PubKeyBin},
                                                               {fcntdown, router_device:fcntdown(Device0)+1}],
                                              router_device:update(DeviceUpdates, Device0);
                                          _ ->
                                              lager:warning("Got ack when no confirmed downlinks in queue"),
                                              DeviceUpdates = [{fcnt, FCnt},
                                                               {location, PubKeyBin}],
                                              router_device:update(DeviceUpdates, Device0)
                                      end
                              end,
                    Frame = #frame{mtype=MType, devaddr=DevAddr, adr=ADR, adrackreq=ADRACKReq, ack=ACK, rfu=RFU,
                                   fcnt=FCnt, fopts=lorawan_mac_commands:parse_fopts(Data), fport=FPort, data=undefined},
                    Desc = <<"Packet with empty fopts received from AppEUI: ",
                             (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
                             (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
                    ok = router_device_utils:report_status(up, Desc, Device0, success, PubKeyBin, Region, Packet, undefined, 0, DevAddr, Blockchain),
                    {ok, Frame, Device1, false, {Balance, Nonce}};
                0 when FOptsLen /= 0 ->
                    lager:debug("Bad ~s packet from ~s ~s received by ~s -- double fopts~n",
                                [lorawan_utils:mtype(MType), lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
                    Desc = <<"Packet with double fopts received from AppEUI: ",
                             (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
                             (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
                    ok = router_device_utils:report_status(up, Desc, Device0, error, PubKeyBin, Region, Packet, undefined, 0, DevAddr, Blockchain),
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
                    {ok, Frame, Device1, true, {Balance, Nonce}}
            end
    end.

%%%-------------------------------------------------------------------
%% @doc
%% Check device's message queue to potentially wait or send reply
%% right away
%% @end
%%%-------------------------------------------------------------------

-spec handle_frame_timeout(blockchain_helium_packet_v1:packet(),
                           libp2p_crypto:pubkey_bin(),
                           atom(),
                           router_device:device(),
                           #frame{},
                           pos_integer(),
                           blockchain:blockchain()) -> noop | {ok, router_device:device()} | {send, router_device:device(), blockchain_helium_packet_v1:packet()}.
handle_frame_timeout(Packet, PubKeyBin, Region, Device, Frame, Count, Blockchain) ->
    handle_frame_timeout(Packet, PubKeyBin, Region, Device, Frame, Count, Blockchain, router_device:queue(Device)).

-spec handle_frame_timeout(blockchain_helium_packet_v1:packet(),
                           libp2p_crypto:pubkey_bin(),
                           atom(),
                           router_device:device(),
                           #frame{},
                           pos_integer(),
                           blockchain:blockchain(),
                           list()) -> noop | {ok, router_device:device()} | {send,router_device:device(), blockchain_helium_packet_v1:packet()}.
handle_frame_timeout(Packet0, PubKeyBin, Region, Device0, Frame, Count, Blockchain, []) ->
    ACK = mtype_to_ack(Frame#frame.mtype),
    WereChannelsCorrected = were_channels_corrected(Frame, Region),
    ChannelCorrection = router_device:channel_correction(Device0),
    {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(Packet0, Region, Device0, Frame, Count),
    lager:info("downlink with no queue, ACK ~p, Fopts ~p and channels corrected ~p -> ~p", [ACK, FOpts1, ChannelCorrection, WereChannelsCorrected]),
    case ACK of
        _ when ACK == 1 orelse FOpts1 /= [] ->
            ConfirmedDown = false,
            Port = 0,
            FCntDown = router_device:fcntdown(Device0),
            MType = ack_to_mtype(ConfirmedDown),
            Reply = frame_to_packet_payload(#frame{mtype=MType, devaddr=Frame#frame.devaddr, fcnt=FCntDown, fopts=FOpts1, fport=Port, ack=ACK, data= <<>>},
                                            Device0),
            #txq{time = TxTime,
                 datr = TxDataRate,
                 freq = TxFreq} = lorawan_mac_region:rx1_window(Region, 0, 0,
                                                                packet_to_rxq(Packet0)),
            Packet1 = blockchain_helium_packet_v1:new_downlink(Reply, TxTime, 27, TxFreq, binary_to_list(TxDataRate)),
            DeviceUpdates = [{channel_correction, ChannelsCorrected},
                             {fcntdown, (FCntDown + 1)}],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = router_device_utils:report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Region, Device1, Packet1, undefined, Frame, Blockchain),
            case ChannelCorrection == false andalso WereChannelsCorrected == true of
                true ->
                    {send, router_device:channel_correction(true, Device1), Packet1};
                false ->
                    {send, Device1, Packet1}
            end;
        _ when ChannelCorrection == false andalso WereChannelsCorrected == true ->
            %% we corrected the channels but don't have anything else to send so just update the device
            {ok, router_device:channel_correction(true, Device0)};
        _ ->
            noop
    end;
handle_frame_timeout(Packet0, PubKeyBin, Region, Device0, Frame, Count, Blockchain, [{ConfirmedDown, Port, ReplyPayload}|T]) ->
    ACK = mtype_to_ack(Frame#frame.mtype),
    MType = ack_to_mtype(ConfirmedDown),
    WereChannelsCorrected = were_channels_corrected(Frame, Region),
    lager:info("downlink with ~p, confirmed ~p port ~p ACK ~p and channels corrected ~p",
               [ReplyPayload, ConfirmedDown, Port, ACK, router_device:channel_correction(Device0) orelse WereChannelsCorrected]),
    {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(Packet0, Region, Device0, Frame, Count),
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
    #txq{time = TxTime,
         datr = TxDataRate,
         freq = TxFreq} = lorawan_mac_region:rx1_window(Region, 0, 0,
                                                        packet_to_rxq(Packet0)),
    Packet1 = blockchain_helium_packet_v1:new_downlink(Reply, TxTime, 27, TxFreq, binary_to_list(TxDataRate)),
    case ConfirmedDown of
        true ->
            Device1 = router_device:channel_correction(ChannelsCorrected, Device0),
            ok = router_device_utils:report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Region, Device1, Packet1, ReplyPayload, Frame, Blockchain),
            {send, Device1, Packet1};
        false ->
            DeviceUpdates = [{queue, T},
                             {channel_correction, ChannelsCorrected},
                             {fcntdown, (FCntDown + 1)}],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = router_device_utils:report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Region, Device1, Packet1, ReplyPayload, Frame, Blockchain),
            {send, Device1, Packet1}
    end.

-spec channel_correction_and_fopts(blockchain_helium_packet_v1:packet(), atom(), router_device:device(), #frame{}, pos_integer()) -> {boolean(), list()}.
channel_correction_and_fopts(Packet, Region, Device, Frame, Count) ->
    ChannelsCorrected = were_channels_corrected(Frame, Region),
    DataRate = blockchain_helium_packet_v1:datarate(Packet),
    ChannelCorrection = router_device:channel_correction(Device),
    ChannelCorrectionNeeded = ChannelCorrection == false,
    FOpts1 = case ChannelCorrectionNeeded andalso not ChannelsCorrected of
                 %% TODO this is going to be different for each region, we can't simply pass the region into this function
                 %% Some regions allow the channel list to be sent in the join response as well, so we may need to do that there as well
                 true -> lorawan_mac_region:set_channels(Region, {0, erlang:list_to_binary(DataRate), [{8, 15}]}, []);
                 _ -> []
             end,
    FOpts2 = case lists:member(link_check_req, Frame#frame.fopts) of
                 true ->
                     SNR = blockchain_helium_packet_v1:snr(Packet),
                     MaxUplinkSNR = lorawan_mac_region:max_uplink_snr(list_to_binary(blockchain_helium_packet_v1:datarate(Packet))),
                     Margin = trunc(SNR - MaxUplinkSNR),
                     lager:info("respond to link_check_req with link_check_ans ~p ~p", [Margin, Count]),
                     [{link_check_ans, Margin, Count}|FOpts1];
                 false ->
                     FOpts1
             end,
    {ChannelsCorrected orelse ChannelCorrection, FOpts2}.

were_channels_corrected(Frame, 'US915') ->
    FOpts0 = Frame#frame.fopts,
    case lists:keyfind(link_adr_ans, 1, FOpts0) of
        {link_adr_ans, 1, 1, 1} ->
            true;
        {link_adr_ans, TxPowerACK, DataRateACK, ChannelMaskACK} ->
            %% consider any answer good enough, if the device wants to reject things, nothing we can so
            lager:info("device rejected ADR: TxPower: ~p DataRate: ~p, Channel Mask: ~p", [TxPowerACK == 1, DataRateACK == 1, ChannelMaskACK == 1]),
            %% XXX we should get this to report_status somehow, but it's a bit tricky right now
            true;
        _ ->
            false
    end;
were_channels_corrected(_Frame, _Region) ->
    %% we only do channel correction for 915 right now
    true.

-spec mtype_to_ack(integer()) -> 0 | 1.
mtype_to_ack(?CONFIRMED_UP) -> 1;
mtype_to_ack(_) -> 0.

-spec ack_to_mtype(boolean()) -> integer().
ack_to_mtype(true) -> ?CONFIRMED_DOWN;
ack_to_mtype(_) -> ?UNCONFIRMED_DOWN.

-spec frame_to_packet_payload(#frame{}, router_device:device()) -> binary().
frame_to_packet_payload(Frame, Device) ->
    FOpts = lorawan_mac_commands:encode_fopts(Frame#frame.fopts),
    FOptsLen = erlang:byte_size(FOpts),
    PktHdr = <<(Frame#frame.mtype):3, 0:3, 0:2, (Frame#frame.devaddr)/binary, (Frame#frame.adr):1, 0:1, (Frame#frame.ack):1,
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
    MIC = crypto:cmac(aes_cbc128, NwkSKey, <<(router_utils:b0(1, Frame#frame.devaddr, Frame#frame.fcnt, byte_size(Msg)))/binary, Msg/binary>>, 4),
    <<Msg/binary, MIC/binary>>.

-spec packet_to_rxq(blockchain_helium_packet_v1:packet()) -> #rxq{}.
packet_to_rxq(Packet) ->
    #rxq{freq = blockchain_helium_packet_v1:frequency(Packet),
         datr = list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
         codr = <<"4/5">>,
         time = calendar:now_to_datetime(os:timestamp()),
         tmms = blockchain_helium_packet_v1:timestamp(Packet),
         rssi = blockchain_helium_packet_v1:signal_strength(Packet),
         lsnr = blockchain_helium_packet_v1:snr(Packet)}.

-spec save_and_update(rocksdb:db_handle(), rocksdb:cf_handle(), pid(), router_device:device()) -> ok.
save_and_update(DB, CF, Pid, Device) ->
    {ok, _} = router_device:save(DB, CF, Device),
    ok = router_device_channels_worker:handle_device_update(Pid, Device).

-spec get_device(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> router_device:device().
get_device(DB, CF, ID) ->
    case router_device:get_by_id(DB, CF, ID) of
        {ok, D} -> D;
        _ -> router_device:new(ID)
    end.
