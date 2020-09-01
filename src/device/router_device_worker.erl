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
         handle_join/7,
         handle_frame/5,
         queue_message/2,
         device_update/1]).

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

-record(join_cache, {rssi :: float(),
                     reply :: binary(),
                     packet_rcvd :: blockchain_helium_packet_v1:packet(),
                     device :: router_device:device(),
                     pid :: pid(),
                     pubkey_bin :: libp2p_crypto:pubkey_bin(),
                     region :: atom()}).

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
                frame_cache = #{} :: #{integer() => #frame_cache{}}}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_join(pid(), blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom(),
                  router_device:device(), binary(), pid()) -> ok.
handle_join(WorkerPid, Packet, PubKeyBin, Region, APIDevice, AppKey, Pid) ->
    gen_server:cast(WorkerPid, {join, Packet, PubKeyBin, Region, APIDevice, AppKey, Pid}).

-spec handle_frame(pid(), blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom(), pid()) -> ok.
handle_frame(WorkerPid, Packet, PubKeyBin, Region, Pid) ->
    gen_server:cast(WorkerPid, {frame, Packet, PubKeyBin, Region, Pid}).

-spec queue_message(pid(), {boolean(), integer(), binary()}) -> ok.
queue_message(Pid, Msg) ->
    gen_server:cast(Pid, {queue_message, Msg}).

-spec device_update(Pid :: pid()) -> ok.
device_update(Pid) ->
    gen_server:cast(Pid, device_update).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Blockchain = blockchain_worker:blockchain(),
    DB = maps:get(db, Args),
    CF = maps:get(cf, Args),
    ID = maps:get(id, Args),
    OUI = case application:get_env(router, oui, undefined) of
              undefined -> undefined;
              OUI0 when is_list(OUI0) ->
                  list_to_integer(OUI0);
              OUI0 ->
                  OUI0
          end,
    Device = get_device(DB, CF, ID),
    {ok, Pid} =
        router_device_channels_worker:start_link(#{blockchain => Blockchain,
                                                   device_worker => self(),
                                                   device => Device}),
    lager:md([{device_id, router_device:id(Device)}]),
    {ok, #state{chain=Blockchain, db=DB, cf=CF, device=Device, oui=OUI, channels_worker=Pid}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(device_update, #state{db=DB, cf=CF, device=Device0, channels_worker=ChannelsWorker}=State) ->
    DeviceID = router_device:id(Device0),
    case router_device_api:get_device(DeviceID) of
        {error, not_found} ->
            lager:warning("device was removed, removing from DB and shutting down"),
            ok = router_device:delete(DB, CF, DeviceID),
            {stop, normal, State};
        {error, _Reason} ->
            lager:error("failed to get device ~p ~p", [DeviceID, _Reason]),
            {noreply, State};
        {ok, APIDevice} ->
            lager:info("device updated"),
            ChannelsWorker ! refresh_channels,
            DeviceUpdates = [{name, router_device:name(APIDevice)},
                             {dev_eui, router_device:dev_eui(APIDevice)},
                             {app_eui, router_device:app_eui(APIDevice)},
                             {metadata, router_device:metadata(APIDevice)}],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            {noreply, State#state{device=Device1}}
    end;
handle_cast({queue_message, {_Type, Port, Payload}=Msg}, #state{db=DB, cf=CF, device=Device0,
                                                                channels_worker=ChannelsWorker}=State) ->
    case erlang:byte_size(Payload) of
        Size when Size > 242 ->
            lager:debug("failed to queue downlink message, too big"),
            ok = report_status_max_size(Device0, Payload, Port),
            {noreply, State};
        _ ->
            Q = router_device:queue(Device0),
            Device1 = router_device:queue(lists:append(Q, [Msg]), Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            lager:debug("queue downlink message"),
            {noreply, State#state{device=Device1}}
    end;
handle_cast({join, _Packet0, _PubKeyBin, _APIDevice, _AppKey, _Pid}, #state{oui=undefined}=State0) ->
    lager:warning("got join packet when oui=undefined, standing by..."),
    {noreply, State0};
handle_cast({join, Packet0, PubKeyBin, Region, APIDevice, AppKey, Pid}, #state{db=DB, cf=CF, device=Device0, join_cache=Cache0,
                                                                               join_nonce_handled_at=JoinNonceHandledAt, oui=OUI,
                                                                               channels_worker=ChannelsWorker}=State0) ->
    %% TODO we should really just call this once per join nonce
    %% and have a seperate function for getting the join nonce so we can check
    %% the cache
    case handle_join_(Packet0, PubKeyBin, Region, OUI, APIDevice, AppKey, Device0) of
        {error, _Reason} ->
            {noreply, State0};
        {ok, Reply, Device1, JoinNonce} ->
            RSSI0 = blockchain_helium_packet_v1:signal_strength(Packet0),
            case maps:get(JoinNonce, Cache0, undefined) of
                undefined when JoinNonceHandledAt == JoinNonce ->
                    %% late packet
                    {noreply, State0};
                undefined ->
                    JoinCache = #join_cache{rssi=RSSI0,
                                            reply=Reply,
                                            packet_rcvd=Packet0,
                                            device=Device1,
                                            pid=Pid,
                                            pubkey_bin=PubKeyBin,
                                            region=Region},
                    Cache1 = maps:put(JoinNonce, JoinCache, Cache0),
                    State1 = State0#state{device=Device1},
                    ok = save_and_update(DB, CF, ChannelsWorker, Device1),
                    _ = erlang:send_after(?JOIN_DELAY, self(), {join_timeout, JoinNonce}),
                    {noreply, State1#state{join_cache=Cache1, join_nonce_handled_at=JoinNonce, downlink_handled_at= -1}};
                #join_cache{rssi=RSSI1, pid=Pid2}=JoinCache1 ->
                    case RSSI0 > RSSI1 of
                        false ->
                            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true)),
                            {noreply, State0};
                        true ->
                            catch blockchain_state_channel_handler:send_response(Pid2, blockchain_state_channel_response_v1:new(true)),
                            Cache1 = maps:put(JoinNonce, JoinCache1#join_cache{packet_rcvd=Packet0, rssi=RSSI0, pid=Pid,
                                                                               pubkey_bin=PubKeyBin, region=Region}, Cache0),
                            {noreply, State0#state{join_cache=Cache1}}
                    end
            end
    end;
handle_cast({frame, Packet0, PubKeyBin, Region, Pid}, #state{chain=Blockchain,
                                                             device=Device0,
                                                             frame_cache=Cache0,
                                                             downlink_handled_at=DownlinkHandledAt,
                                                             channels_worker=ChannelsWorker}=State) ->
    case validate_frame(Packet0, PubKeyBin, Region, Device0, Blockchain) of
        {error, {not_enough_dc, Device1}} ->
            ok = report_status_no_dc(Device0),
            lager:debug("did not have enough dc to send data"),
            {noreply, State#state{device=Device1}};
        {error, _Reason} ->
            {noreply, State};
        {ok, Frame, Device1, SendToChannels, {Balance, Nonce}} ->
            Data = {PubKeyBin, Packet0, Frame, erlang:system_time(second)},
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
                undefined when FCnt =< DownlinkHandledAt ->
                    %% late packet
                    {noreply, State};
                undefined ->
                    _ = erlang:send_after(?REPLY_DELAY, self(), {frame_timeout, FCnt}),
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
                                              channels_worker=ChannelsWorker, join_cache=Cache0}=State) ->
    #join_cache{reply=Reply,
                packet_rcvd=PacketRcvd,
                device=Device0,
                pid=Pid,
                pubkey_bin=PubKeyBin,
                region=Region} = maps:get(JoinNonce, Cache0),

    #txq{time = TxTime,
         datr = TxDataRate,
         freq = TxFreq} = lorawan_mac_region:join1_window(Region, 0,
                                                          packet_to_rxq(PacketRcvd)),

    Packet = blockchain_helium_packet_v1:new_downlink(Reply, TxTime, 27, TxFreq, binary_to_list(TxDataRate)),
    catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true, Packet)),
    Device1 = router_device:join_nonce(JoinNonce, Device0),
    ok = router_device_channels_worker:handle_join(ChannelsWorker),
    ok = save_and_update(DB, CF, ChannelsWorker, Device1),
    DevEUI = router_device:dev_eui(Device0),
    AppEUI = router_device:app_eui(Device0),
    Desc = <<"Join attempt from AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
             (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
    ok = report_status(activation, Desc, Device1, success, PubKeyBin, Region, PacketRcvd, 0, <<>>, Blockchain),
    Cache1 = maps:remove(JoinNonce, Cache0),
    {noreply, State#state{device=Device1, join_cache=Cache1}};
handle_info({frame_timeout, FCnt}, #state{chain=Blockchain, db=DB, cf=CF, device=Device,
                                          channels_worker=ChannelsWorker, frame_cache=Cache0}=State) ->
    #frame_cache{packet=Packet,
                 pubkey_bin=PubKeyBin,
                 frame=Frame,
                 count=Count,
                 pid=Pid,
                 region=Region} = maps:get(FCnt, Cache0),
    Cache1 = maps:remove(FCnt, Cache0),
    lager:debug("frame timeout for ~p / device ~p", [FCnt, lager:pr(Device, router_device)]),
    case handle_frame(Packet, PubKeyBin, Region, Device, Frame, Count, Blockchain) of
        {ok, Device1} ->
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true)),
            {noreply, State#state{device=Device1, frame_cache=Cache1}};
        {send, Device1, DownlinkPacket} ->
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            lager:info("sending downlink for fcnt: ~p", [FCnt]),
            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true, DownlinkPacket)),
            {noreply, State#state{device=Device1, frame_cache=Cache1}};
        noop ->
            catch blockchain_state_channel_handler:send_response(Pid, blockchain_state_channel_response_v1:new(true)),
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

%%%-------------------------------------------------------------------
%% @doc
%% Handle join request, dedup multiple if needed, report statsus
%% to console and sends back join resp
%% @end
%%%-------------------------------------------------------------------
-spec handle_join_(blockchain_helium_packet_v1:packet(),
                   libp2p_crypto:pubkey_to_bin(),
                   atom(),
                   non_neg_integer(),
                   router_device:device(),
                   binary(),
                   router_device:device()) ->
          {ok, Reply::binary(), Device::router_device:device(), DevAddr::binary()} | {error, any()}.
handle_join_(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, _AppEUI0:8/binary,
                                   _DevEUI0:8/binary, _Nonce:2/binary, _MIC:4/binary>>}=Packet,
             PubKeyBin, Region, OUI, APIDevice, AppKey, Device) when MType == ?JOIN_REQ ->
    handle_join_(Packet, PubKeyBin, Region, OUI, APIDevice, AppKey, Device, router_device:join_nonce(Device));
handle_join_(_Packet, _PubKeyBin, _Region, _OUI, _APIDevice, _AppKey, _Device) ->
    {error, not_join_req}.

-spec handle_join_(blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_to_bin(), atom(), non_neg_integer(), 
                   router_device:device(), binary(), router_device:device(), non_neg_integer()) ->
          {ok, binary(), router_device:device(), binary()} | {error, any()}.
handle_join_(#packet_pb{payload= <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary,
                                   DevEUI0:8/binary, Nonce:2/binary, _MIC:4/binary>>},
             PubKeyBin, _Region, _OUI, _APIDevice, _AppKey, _Device, OldNonce) when Nonce == OldNonce ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    lager:warning("~s ~s tried to join with stale nonce ~p via ~s", [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), Nonce, AName]),
    {error, bad_nonce};
handle_join_(#packet_pb{payload= <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                                   DevNonce:2/binary, _MIC:4/binary>>},
             PubKeyBin, Region, _OUI, APIDevice, AppKey, Device0, _OldNonce) ->
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
    DevAddr = case router_device_devaddr:allocate(Device0, PubKeyBin) of
                  {ok, D} ->
                      D;
                  {error, _Reason} ->
                      lager:warning("failed to allocate devaddr for ~p: ~p", [router_device:id(Device0), _Reason]),
                      router_device_devaddr:default_devaddr()
              end,
    RxDelay = ?RX_DELAY,
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
    ReplyPayload = <<AppNonce/binary, NetID/binary, DevAddr/binary, DLSettings:8/integer-unsigned, RxDelay:8/integer-unsigned, CFList/binary>>,
    ReplyMIC = crypto:cmac(aes_cbc128, AppKey, <<ReplyHdr/binary, ReplyPayload/binary>>, 4),
    EncryptedReply = crypto:block_decrypt(aes_ecb, AppKey, lorawan_utils:padded(16, <<ReplyPayload/binary, ReplyMIC/binary>>)),
    Reply = <<ReplyHdr/binary, EncryptedReply/binary>>,
    DeviceName = router_device:name(APIDevice),
    lager:info("DevEUI ~s with AppEUI ~s tried to join with nonce ~p via ~s",
               [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), DevNonce, AName]),
    %% don't set the join nonce here yet as we have not chosen the best join request yet
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
    {ok, Reply, Device1, DevNonce}.

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
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
    TS = blockchain_helium_packet_v1:timestamp(Packet),
    lager:debug("validating frame ~p @ ~p (devaddr: ~p) from ~p", [FCnt, TS, DevAddr, AName]),
    PayloadSize = erlang:byte_size(FRMPayload),
    case router_console_dc_tracker:has_enough_dc(Device0, PayloadSize, Blockchain) of
        false ->
            DeviceUpdates = [{fcnt, FCnt}, {location, PubKeyBin}],
            Device1 = router_device:update(DeviceUpdates, Device0),
            case FPort of
                0 when FOptsLen == 0 ->
                    {error, {not_enough_dc, Device1}};
                0 when FOptsLen /= 0 ->
                    {error, {not_enough_dc, Device0}};
                _N ->
                    {error, {not_enough_dc, Device1}}
            end;
        {true, Balance, Nonce} ->
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
                    ok = report_status(up, Desc, Device0, success, PubKeyBin, Region, Packet, 0, DevAddr, Blockchain),
                    {ok, Frame, Device1, false, {Balance, Nonce}};
                0 when FOptsLen /= 0 ->
                    lager:debug("Bad ~s packet from ~s ~s received by ~s -- double fopts~n",
                                [lorawan_utils:mtype(MType), lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]),
                    Desc = <<"Packet with double fopts received from AppEUI: ",
                             (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
                             (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
                    ok = report_status(up, Desc, Device0, error, PubKeyBin, Region, Packet, 0, DevAddr, Blockchain),
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

-spec handle_frame(blockchain_helium_packet_v1:packet(),
                   libp2p_crypto:pubkey_bin(),
                   atom(),
                   router_device:device(),
                   #frame{},
                   pos_integer(),
                   blockchain:blockchain()) -> noop | {ok, router_device:device()} | {send, router_device:device(), blockchain_helium_packet_v1:packet()}.
handle_frame(Packet, PubKeyBin, Region, Device, Frame, Count, Blockchain) ->
    handle_frame(Packet, PubKeyBin, Region, Device, Frame, Count, Blockchain, router_device:queue(Device)).

-spec handle_frame(blockchain_helium_packet_v1:packet(),
                   libp2p_crypto:pubkey_bin(),
                   atom(),
                   router_device:device(),
                   #frame{},
                   pos_integer(),
                   blockchain:blockchain(),
                   list()) -> noop | {ok, router_device:device()} | {send,router_device:device(), blockchain_helium_packet_v1:packet()}.
handle_frame(Packet0, PubKeyBin, Region, Device0, Frame, Count, Blockchain, []) ->
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
            ok = report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Region, Device1, Packet1, Frame, Blockchain),
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
handle_frame(Packet0, PubKeyBin, Region, Device0, Frame, Count, Blockchain, [{ConfirmedDown, Port, ReplyPayload}|T]) ->
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
            ok = report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Region, Device1, Packet1, Frame, Blockchain),
            {send, Device1, Packet1};
        false ->
            DeviceUpdates = [{queue, T},
                             {channel_correction, ChannelsCorrected},
                             {fcntdown, (FCntDown + 1)}],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = report_frame_status(ACK, ConfirmedDown, Port, PubKeyBin, Region, Device1, Packet1, Frame, Blockchain),
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

-spec report_frame_status(integer(), boolean(), any(), libp2p_crypto:pubkey_bin(), atom(),
                          router_device:device(), blockchain_helium_packet_v1:packet(),
                          #frame{}, blockchain:blockchain()) -> ok.
report_frame_status(0, false, 0, PubKeyBin, Region, Device, Packet, #frame{devaddr=DevAddr, fport=FPort}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Correcting channel mask in response to ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(down, Desc, Device, success, PubKeyBin, Region, Packet, FPort, DevAddr, Blockchain);
report_frame_status(1, _ConfirmedDown, undefined, PubKeyBin, Region, Device, Packet, #frame{devaddr=DevAddr, fport=FPort}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(ack, Desc, Device, success, PubKeyBin, Region, Packet, FPort, DevAddr, Blockchain);
report_frame_status(1, true, Port, PubKeyBin, Region, Device, Packet, #frame{devaddr=DevAddr}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK and confirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(ack, Desc, Device, success, PubKeyBin, Region, Packet, Port, DevAddr, Blockchain);
report_frame_status(1, false, Port, PubKeyBin, Region, Device, Packet, #frame{devaddr=DevAddr}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK and unconfirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(ack, Desc, Device, success, PubKeyBin, Region, Packet, Port, DevAddr, Blockchain);
report_frame_status(_, true, Port, PubKeyBin, Region, Device, Packet, #frame{devaddr=DevAddr}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending confirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(down, Desc, Device, success, PubKeyBin, Region, Packet, Port, DevAddr, Blockchain);
report_frame_status(_, false, Port, PubKeyBin, Region, Device, Packet, #frame{devaddr=DevAddr}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending unconfirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = report_status(down, Desc, Device, success, PubKeyBin, Region, Packet, Port, DevAddr, Blockchain).

-spec report_status_max_size(router_device:device(), binary(), non_neg_integer()) -> ok.
report_status_max_size(Device, Payload, Port) ->
    Report = #{category => packet_dropped,
               description => <<"Packet request exceeds maximum 242 bytes">>,
               reported_at => erlang:system_time(seconds),
               payload => base64:encode(Payload),
               payload_size => erlang:byte_size(Payload),
               port => Port,
               devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
               hotspots => [],
               channels => []},
    ok = router_device_api:report_status(Device, Report).

-spec report_status_no_dc(router_device:device()) -> ok.
report_status_no_dc(Device) ->
    Report = #{category => packet_dropped,
               description => <<"Not enough DC">>,
               reported_at => erlang:system_time(seconds),
               payload => <<>>,
               payload_size => 0,
               port => 0,
               devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
               hotspots => [],
               channels => []},
    ok = router_device_api:report_status(Device, Report).

-spec report_status(atom(), binary(), router_device:device(), success | error,
                    libp2p_crypto:pubkey_bin(), atom(), blockchain_helium_packet_v1:packet(),
                    any(), any(), blockchain:blockchain()) -> ok.
report_status(Category, Desc, Device, Status, PubKeyBin, Region, Packet, Port, DevAddr, Blockchain) ->
    HotspotID = libp2p_crypto:bin_to_b58(PubKeyBin),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(HotspotID),
    Freq = blockchain_helium_packet_v1:frequency(Packet),
    {Lat, Long} = router_utils:get_hotspot_location(PubKeyBin, Blockchain),
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
                              rssi => blockchain_helium_packet_v1:signal_strength(Packet),
                              snr => blockchain_helium_packet_v1:snr(Packet),
                              spreading => erlang:list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
                              frequency => Freq,
                              channel => lorawan_mac_region:f2uch(Region, Freq),
                              lat => Lat,
                              long => Long}],
               channels => []},
    ok = router_device_api:report_status(Device, Report).

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

-spec int_to_bin(integer()) -> binary().
int_to_bin(Int) ->
    erlang:list_to_binary(erlang:integer_to_list(Int)).

-spec packet_to_rxq(blockchain_helium_packet_v1:packet()) -> #rxq{}.
packet_to_rxq(Packet) ->
    #rxq{freq = blockchain_helium_packet_v1:frequency(Packet),
         datr = list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
         codr = <<"4/5">>,
         time = calendar:now_to_datetime(os:timestamp()),
         tmms = blockchain_helium_packet_v1:timestamp(Packet),
         rssi = blockchain_helium_packet_v1:signal_strength(Packet),
         lsnr = blockchain_helium_packet_v1:snr(Packet)}.
