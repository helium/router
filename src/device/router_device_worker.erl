%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_worker).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("public_key/include/public_key.hrl").

-include("router_device_worker.hrl").
-include("lorawan_adr.hrl").
-include("lorawan_vars.hrl").
-include("lorawan_db.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_offer/2,
    handle_join/8,
    handle_frame/7,
    queue_message/2,
    queue_message/3,
    device_update/1,
    clear_queue/1
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
-define(BACKOFF_MAX, timer:minutes(5)).
%% biggest unsigned number in 23 bits
-define(BITS_23, 8388607).

-define(NET_ID, <<"He2">>).

-define(RX_MAX_WINDOW, 2000).

-record(state, {
    chain :: blockchain:blockchain(),
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle(),
    device :: router_device:device(),
    downlink_handled_at = -1 :: integer(),
    fcnt = -1 :: integer(),
    oui :: undefined | non_neg_integer(),
    channels_worker :: pid(),
    last_dev_nonce = undefined :: binary() | undefined,
    join_cache = #{} :: #{integer() => #join_cache{}},
    frame_cache = #{} :: #{integer() => #frame_cache{}},
    adr_engine :: undefined | lorawan_adr:handle(),
    is_active = true :: boolean()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_offer(pid(), blockchain_state_channel_offer_v1:offer()) -> ok.
handle_offer(WorkerPid, Offer) ->
    gen_server:cast(WorkerPid, {handle_offer, Offer}).

-spec handle_join(
    pid(),
    blockchain_helium_packet_v1:packet(),
    pos_integer(),
    libp2p_crypto:pubkey_bin(),
    atom(),
    router_device:device(),
    binary(),
    pid()
) -> ok.
handle_join(WorkerPid, Packet, PacketTime, PubKeyBin, Region, APIDevice, AppKey, Pid) ->
    gen_server:cast(
        WorkerPid,
        {join, Packet, PacketTime, PubKeyBin, Region, APIDevice, AppKey, Pid}
    ).

-spec handle_frame(
    pid(),
    binary(),
    blockchain_helium_packet_v1:packet(),
    pos_integer(),
    libp2p_crypto:pubkey_bin(),
    atom(),
    pid()
) -> ok.
handle_frame(WorkerPid, NwkSKey, Packet, PacketTime, PubKeyBin, Region, Pid) ->
    gen_server:cast(WorkerPid, {frame, NwkSKey, Packet, PacketTime, PubKeyBin, Region, Pid}).

-spec queue_message(pid(), #downlink{}) -> ok.
queue_message(Pid, #downlink{} = Downlink) ->
    ?MODULE:queue_message(Pid, Downlink, last).

-spec queue_message(pid(), #downlink{}, first | last) -> ok.
queue_message(Pid, #downlink{} = Downlink, Position) ->
    gen_server:cast(Pid, {queue_message, Downlink, Position}).

-spec clear_queue(Pid :: pid()) -> ok.
clear_queue(Pid) ->
    gen_server:cast(Pid, clear_queue).

-spec device_update(Pid :: pid()) -> ok.
device_update(Pid) ->
    gen_server:cast(Pid, device_update).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{db := DB, cf := CF, id := ID} = Args) ->
    Blockchain = blockchain_worker:blockchain(),
    OUI = router_utils:get_oui(),
    Device = get_device(DB, CF, ID),
    {ok, Pid} =
        router_device_channels_worker:start_link(#{
            blockchain => Blockchain,
            device_worker => self(),
            device => Device
        }),
    IsActive = router_device:is_active(Device),
    ok = router_utils:lager_md(Device),
    ok = ?MODULE:device_update(self()),
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, #state{
        chain = Blockchain,
        db = DB,
        cf = CF,
        device = Device,
        oui = OUI,
        channels_worker = Pid,
        is_active = IsActive
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({handle_offer, Offer}, #state{device = Device, adr_engine = ADREngine0} = State) ->
    ADREngine1 = maybe_track_adr_offer(Device, ADREngine0, Offer),
    {noreply, State#state{adr_engine = ADREngine1}};
handle_cast(
    device_update,
    #state{db = DB, cf = CF, device = Device0, channels_worker = ChannelsWorker} = State
) ->
    DeviceID = router_device:id(Device0),
    case router_console_api:get_device(DeviceID) of
        {error, not_found} ->
            ok = router_device:delete(DB, CF, DeviceID),
            ok = router_device_cache:delete(DeviceID),
            lager:info("device was removed, removing from DB and shutting down"),
            {stop, normal, State};
        {error, _Reason} ->
            lager:error("failed to update device ~p", [_Reason]),
            {noreply, State};
        {ok, APIDevice} ->
            lager:info("device updated: ~p", [APIDevice]),
            router_device_channels_worker:refresh_channels(ChannelsWorker),
            IsActive = router_device:is_active(APIDevice),
            DeviceUpdates = [
                {name, router_device:name(APIDevice)},
                {dev_eui, router_device:dev_eui(APIDevice)},
                {app_eui, router_device:app_eui(APIDevice)},
                {metadata, router_device:metadata(APIDevice)},
                {is_active, IsActive}
            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            {noreply, State#state{device = Device1, is_active = IsActive}}
    end;
handle_cast(
    clear_queue,
    #state{
        db = DB,
        cf = CF,
        device = Device0,
        channels_worker = ChannelsWorkerPid
    } = State
) ->
    lager:debug("cleared queue"),
    Device1 = router_device:queue([], Device0),
    ok = save_and_update(DB, CF, ChannelsWorkerPid, Device1),
    {noreply, State#state{device = Device1}};
handle_cast(
    {queue_message, #downlink{port = Port, payload = Payload, channel = Channel} = Downlink,
        Position},
    #state{
        db = DB,
        cf = CF,
        device = Device0,
        channels_worker = ChannelsWorker
    } = State
) ->
    case router_device:can_queue_payload(Payload, Device0) of
        {false, Size, MaxSize, Datarate} ->
            Desc = io_lib:format(
                "Payload too big for ~p max size is ~p (payload was ~p)",
                [Datarate, MaxSize, Size]
            ),
            ok = router_utils:event_downlink_dropped(
                erlang:list_to_binary(Desc),
                Port,
                Payload,
                Device0,
                router_channel:to_map(Channel)
            ),
            lager:debug("failed to queue downlink message, too big (~p > ~p), using datarate ~p", [
                Size,
                MaxSize,
                Datarate
            ]),
            {noreply, State};
        {true, Size, MaxSize, _Datarate} ->
            OldQueue = router_device:queue(Device0),
            NewQueue =
                case Position of
                    first -> [Downlink | OldQueue];
                    last -> OldQueue ++ [Downlink]
                end,
            Device1 = router_device:queue(NewQueue, Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            Desc = io_lib:format(
                "Downlink queued in ~p place",
                [Position]
            ),
            ok = router_utils:event_downlink_queued(
                erlang:list_to_binary(Desc),
                Port,
                Payload,
                Device1,
                router_channel:to_map(Channel)
            ),

            lager:debug("queued downlink message of size ~p < ~p", [Size, MaxSize]),
            {noreply, State#state{device = Device1}};
        {error, _Reason} ->
            Desc = io_lib:format("Failed to queue downlink: ~p", [_Reason]),
            ok = router_utils:event_downlink_dropped(
                erlang:list_to_binary(Desc),
                Port,
                Payload,
                Device0,
                router_channel:to_map(Channel)
            ),
            lager:debug("failed to queue downlink message, ~p", [_Reason]),
            {noreply, State}
    end;
handle_cast(
    {join, _Packet0, _PubKeyBin, _APIDevice, _AppKey, _Pid},
    #state{oui = undefined} = State0
) ->
    lager:warning("got join packet when oui=undefined"),
    {noreply, State0};
handle_cast(
    {join, Packet0, PacketTime, PubKeyBin, Region, APIDevice, AppKey, Pid},
    #state{
        chain = Chain,
        db = DB,
        cf = CF,
        device = Device0,
        join_cache = Cache0,
        oui = OUI,
        channels_worker = ChannelsWorker
    } = State
) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet0),
    lager:debug("got join packet (~p) ~p", [PHash, lager:pr(Packet0, blockchain_helium_packet_v1)]),
    %% TODO we should really just call this once per join nonce
    %% and have a seperate function for getting the join nonce so we can check
    %% the cache
    case validate_join(Packet0, PubKeyBin, Region, OUI, APIDevice, AppKey, Device0, Chain) of
        {error, _Reason} ->
            lager:debug("failed to validate join ~p", [_Reason]),
            {noreply, State};
        {ok, Device1, DevNonce, Reply} ->
            NewRSSI = blockchain_helium_packet_v1:signal_strength(Packet0),
            LastDevNonce =
                case router_device:dev_nonces(Device0) of
                    [D | _] -> D;
                    [] -> <<>>
                end,
            case maps:get(DevNonce, Cache0, undefined) of
                undefined when LastDevNonce == DevNonce ->
                    lager:debug("got a late join: ~p", [DevNonce]),
                    {noreply, State};
                undefined ->
                    lager:debug("got a first join: ~p", [DevNonce]),
                    JoinCache = #join_cache{
                        uuid = router_utils:uuid_v4(),
                        rssi = NewRSSI,
                        reply = Reply,
                        packet_selected = {Packet0, PubKeyBin, Region, PacketTime},
                        device = Device1,
                        pid = Pid
                    },
                    Cache1 = maps:put(DevNonce, JoinCache, Cache0),
                    ok = save_and_update(DB, CF, ChannelsWorker, Device1),
                    Timeout = max(
                        0,
                        router_utils:join_timeout() -
                            (erlang:system_time(millisecond) - PacketTime)
                    ),
                    lager:debug("setting join timeout [dev_nonce: ~p] [timeout: ~p]", [
                        DevNonce,
                        Timeout
                    ]),
                    _ = erlang:send_after(Timeout, self(), {join_timeout, DevNonce}),
                    ok = router_utils:event_join_request(
                        JoinCache#join_cache.uuid,
                        PacketTime,
                        Device1,
                        Chain,
                        PubKeyBin,
                        Packet0,
                        Region
                    ),
                    {noreply, State#state{
                        device = Device1,
                        last_dev_nonce = DevNonce,
                        join_cache = Cache1,
                        adr_engine = undefined,
                        downlink_handled_at = -1,
                        fcnt = -1
                    }};
                #join_cache{
                    uuid = UUID,
                    rssi = OldRSSI,
                    packet_selected = {OldPacket, _, _, _} = OldSelected,
                    packets = OldPackets,
                    pid = OldPid
                } = JoinCache1 ->
                    ok = router_utils:event_join_request(
                        UUID,
                        PacketTime,
                        Device1,
                        Chain,
                        PubKeyBin,
                        Packet0,
                        Region
                    ),
                    case NewRSSI > OldRSSI of
                        false ->
                            lager:debug("got another join for ~p with worst RSSI ~p", [
                                DevNonce,
                                {NewRSSI, OldRSSI}
                            ]),
                            catch blockchain_state_channel_handler:send_response(
                                Pid,
                                blockchain_state_channel_response_v1:new(true)
                            ),
                            ok = router_metrics:packet_trip_observe_end(
                                blockchain_helium_packet_v1:packet_hash(Packet0),
                                PubKeyBin,
                                erlang:system_time(millisecond),
                                join,
                                false
                            ),
                            Cache1 = maps:put(
                                DevNonce,
                                JoinCache1#join_cache{
                                    packets = [
                                        {Packet0, PubKeyBin, Region, PacketTime}
                                        | OldPackets
                                    ]
                                },
                                Cache0
                            ),
                            {noreply, State#state{join_cache = Cache1}};
                        true ->
                            lager:debug("got a another join for ~p with better RSSI ~p", [
                                DevNonce,
                                {NewRSSI, OldRSSI}
                            ]),
                            catch blockchain_state_channel_handler:send_response(
                                OldPid,
                                blockchain_state_channel_response_v1:new(true)
                            ),
                            NewPackets = [OldSelected | lists:keydelete(OldPacket, 1, OldPackets)],
                            Cache1 = maps:put(
                                DevNonce,
                                JoinCache1#join_cache{
                                    rssi = NewRSSI,
                                    packet_selected = {Packet0, PubKeyBin, Region, PacketTime},
                                    packets = NewPackets,
                                    pid = Pid
                                },
                                Cache0
                            ),
                            {noreply, State#state{join_cache = Cache1}}
                    end
            end
    end;
handle_cast(
    {frame, _NwkSKey, Packet, PacketTime, PubKeyBin, _Region, _Pid},
    #state{
        chain = Blockchain,
        device = Device,
        is_active = false
    } = State
) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),

    _ = router_device_routing:deny_more(PHash),
    <<_MType:3, _MHDRRFU:3, _Major:2, _DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
        _FOptsLen:4, FCnt:16/little-unsigned-integer, _FOpts:_FOptsLen/binary,
        _PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),
    Desc = <<"Device inactive packet dropped">>,
    ok = router_utils:event_uncharged_uplink_dropped(
        Desc,
        PacketTime,
        FCnt,
        Device,
        Blockchain,
        PubKeyBin
    ),
    {noreply, State};
handle_cast(
    {frame, UsedNwkSKey, Packet0, PacketTime, PubKeyBin, Region, Pid},
    #state{
        chain = Blockchain,
        device = Device0,
        frame_cache = Cache0,
        downlink_handled_at = DownlinkHandledAt,
        fcnt = LastSeenFCnt,
        channels_worker = ChannelsWorker,
        last_dev_nonce = LastDevNonce
    } = State
) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet0),
    lager:debug("got packet (~p) ~p from ~p", [
        PHash,
        lager:pr(Packet0, blockchain_helium_packet_v1),
        blockchain_utils:addr2name(PubKeyBin)
    ]),
    Device1 =
        case LastDevNonce == undefined of
            true ->
                Device0;
            %% this is our first good uplink after join lets cleanup keys and update dev_nonces
            false ->
                %% if our keys are not matching we can assume that last dev nonce is bad
                %% and we should not save it
                DevNonces =
                    case UsedNwkSKey == router_device:nwk_s_key(Device0) of
                        false -> router_device:dev_nonces(Device0);
                        true -> [LastDevNonce | router_device:dev_nonces(Device0)]
                    end,
                DeviceUpdates = [
                    {keys,
                        lists:filter(
                            fun({NwkSKey, _}) -> NwkSKey == UsedNwkSKey end,
                            router_device:keys(Device0)
                        )},
                    {dev_nonces, DevNonces}
                ],
                lager:debug("we got our first uplink after join dev nonce=~p and key=~p", [
                    LastDevNonce,
                    UsedNwkSKey
                ]),
                router_device:update(DeviceUpdates, Device0)
        end,
    case
        validate_frame(
            Packet0,
            PacketTime,
            PubKeyBin,
            Region,
            Device1,
            Blockchain,
            {LastSeenFCnt, DownlinkHandledAt},
            Cache0
        )
    of
        {error, {not_enough_dc, _Reason, Device2}} ->
            ok = router_utils:event_uncharged_uplink_dropped(
                <<"Not enough DC">>,
                PacketTime,
                router_device:fcnt(Device2),
                Device2,
                Blockchain,
                PubKeyBin
            ),
            lager:debug("did not have enough dc (~p) to send data", [_Reason]),
            _ = router_device_routing:deny_more(PHash),
            ok = router_metrics:packet_trip_observe_end(
                PHash,
                PubKeyBin,
                erlang:system_time(millisecond),
                packet,
                false
            ),
            {noreply, State#state{device = Device2}};
        {error, Reason} ->
            lager:debug("packet not validated: ~p", [Reason]),
            case Reason of
                late_packet ->
                    ok = router_utils:event_uncharged_uplink_dropped(
                        <<"Invalid Packet: ", (erlang:atom_to_binary(Reason, utf8))/binary>>,
                        PacketTime,
                        router_device:fcnt(Device1),
                        Device1,
                        Blockchain,
                        PubKeyBin
                    );
                _ ->
                    ok = router_utils:event_charged_uplink_dropped(
                        <<"Invalid Packet: ", (erlang:atom_to_binary(Reason, utf8))/binary>>,
                        PacketTime,
                        router_device:fcnt(Device1),
                        Device1,
                        Blockchain,
                        PubKeyBin,
                        Packet0,
                        Region
                    )
            end,
            _ = router_device_routing:deny_more(PHash),
            ok = router_metrics:packet_trip_observe_end(
                PHash,
                PubKeyBin,
                erlang:system_time(millisecond),
                packet,
                false
            ),
            {noreply, State};
        {ok, Frame, Device2, SendToChannels, BalanceNonce} ->
            RSSI0 = blockchain_helium_packet_v1:signal_strength(Packet0),
            FCnt = router_device:fcnt(Device2),
            NewFrameCache = #frame_cache{
                uuid = router_utils:uuid_v4(),
                rssi = RSSI0,
                packet = Packet0,
                pubkey_bin = PubKeyBin,
                frame = Frame,
                pid = Pid,
                region = Region
            },
            {UUID, State1} =
                case maps:get(FCnt, Cache0, undefined) of
                    undefined ->
                        ok = router_utils:event_uplink(
                            NewFrameCache#frame_cache.uuid,
                            PacketTime,
                            Frame,
                            Device2,
                            Blockchain,
                            PubKeyBin,
                            Packet0,
                            Region,
                            BalanceNonce
                        ),
                        Timeout = max(
                            0,
                            router_utils:frame_timeout() -
                                (erlang:system_time(millisecond) - PacketTime)
                        ),
                        lager:debug("setting frame timeout [fcnt: ~p] [timeout: ~p]", [
                            FCnt,
                            Timeout
                        ]),
                        _ = erlang:send_after(Timeout, self(), {frame_timeout, FCnt, PacketTime}),
                        {NewFrameCache#frame_cache.uuid, State#state{
                            device = Device2,
                            frame_cache = maps:put(FCnt, NewFrameCache, Cache0)
                        }};
                    #frame_cache{rssi = OldRSSI, pid = OldPid, count = Count} = OldFrameCache ->
                        ok = router_utils:event_uplink(
                            OldFrameCache#frame_cache.uuid,
                            PacketTime,
                            Frame,
                            Device2,
                            Blockchain,
                            PubKeyBin,
                            Packet0,
                            Region,
                            BalanceNonce
                        ),
                        case RSSI0 > OldRSSI of
                            false ->
                                catch blockchain_state_channel_handler:send_response(
                                    Pid,
                                    blockchain_state_channel_response_v1:new(true)
                                ),
                                ok = router_metrics:packet_trip_observe_end(
                                    PHash,
                                    PubKeyBin,
                                    erlang:system_time(millisecond),
                                    packet,
                                    false
                                ),
                                {OldFrameCache#frame_cache.uuid, State#state{
                                    device = Device2,
                                    frame_cache = maps:put(
                                        FCnt,
                                        OldFrameCache#frame_cache{count = Count + 1},
                                        Cache0
                                    )
                                }};
                            true ->
                                catch blockchain_state_channel_handler:send_response(
                                    OldPid,
                                    blockchain_state_channel_response_v1:new(true)
                                ),
                                {OldFrameCache#frame_cache.uuid, State#state{
                                    device = Device2,
                                    frame_cache = maps:put(
                                        FCnt,
                                        NewFrameCache#frame_cache{
                                            uuid = OldFrameCache#frame_cache.uuid,
                                            count = Count + 1
                                        },
                                        Cache0
                                    )
                                }}
                        end
                end,
            case SendToChannels of
                true ->
                    Data = router_device_channels_worker:new_data_cache(
                        PubKeyBin,
                        UUID,
                        Packet0,
                        Frame,
                        Region,
                        PacketTime
                    ),
                    ok = router_device_channels_worker:handle_frame(ChannelsWorker, Data);
                false ->
                    ok
            end,
            {noreply, State1}
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {join_timeout, DevNonce},
    #state{
        chain = Blockchain,
        channels_worker = ChannelsWorker,
        join_cache = JoinCache
    } = State
) ->
    #join_cache{
        reply = Reply,
        packet_selected = PacketSelected,
        packets = Packets,
        device = Device0,
        pid = Pid
    } = maps:get(DevNonce, JoinCache),
    {Packet, PubKeyBin, Region, _PacketTime} = PacketSelected,
    lager:debug("join timeout for ~p / selected ~p out of ~p", [
        DevNonce,
        lager:pr(Packet, blockchain_helium_packet_v1),
        erlang:length(Packets) + 1
    ]),
    #txq{
        time = TxTime,
        datr = TxDataRate,
        freq = TxFreq
    } = lorawan_mac_region:join1_window(
        Region,
        0,
        packet_to_rxq(Packet)
    ),
    Rx2 = join2_from_packet(Region, Packet),
    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        Reply,
        27,
        TxTime,
        TxFreq,
        binary_to_list(TxDataRate),
        Rx2
    ),
    catch blockchain_state_channel_handler:send_response(
        Pid,
        blockchain_state_channel_response_v1:new(true, DownlinkPacket)
    ),
    ok = router_metrics:packet_trip_observe_end(
        blockchain_helium_packet_v1:packet_hash(Packet),
        PubKeyBin,
        erlang:system_time(millisecond),
        join,
        true
    ),
    ok = router_device_channels_worker:handle_join(ChannelsWorker),
    _ = erlang:spawn(router_utils, maybe_update_trace, [router_device:id(Device0)]),
    ok = router_utils:event_join_accept(Device0, Blockchain, PubKeyBin, Packet, Region),
    {noreply, State#state{join_cache = maps:remove(DevNonce, JoinCache)}};
handle_info(
    {frame_timeout, FCnt, PacketTime},
    #state{
        chain = Blockchain,
        db = DB,
        cf = CF,
        device = Device0,
        channels_worker = ChannelsWorker,
        frame_cache = Cache0,
        adr_engine = ADREngine0
    } = State
) ->
    FrameCache = maps:get(FCnt, Cache0),
    #frame_cache{
        uuid = UUID,
        packet = Packet,
        pubkey_bin = PubKeyBin,
        frame = Frame,
        count = Count,
        pid = Pid,
        region = Region
    } = FrameCache,
    Cache1 = maps:remove(FCnt, Cache0),
    ok = router_device_routing:clear_multi_buy(Packet),
    ok = router_device_channels_worker:frame_timeout(ChannelsWorker, UUID),
    lager:debug("frame timeout for ~p / device ~p", [FCnt, lager:pr(Device0, router_device)]),
    {ADREngine1, ADRAdjustment} = maybe_track_adr_packet(Device0, ADREngine0, FrameCache),
    DeviceID = router_device:id(Device0),
    case
        handle_frame_timeout(
            Packet,
            Region,
            Device0,
            Frame,
            Count,
            ADRAdjustment,
            router_device:queue(Device0)
        )
    of
        {ok, Device1} ->
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            catch blockchain_state_channel_handler:send_response(
                Pid,
                blockchain_state_channel_response_v1:new(true)
            ),
            router_device_routing:clear_replay(DeviceID),
            ok = router_metrics:packet_trip_observe_end(
                blockchain_helium_packet_v1:packet_hash(Packet),
                PubKeyBin,
                erlang:system_time(millisecond),
                packet,
                false
            ),
            {noreply, State#state{
                device = Device1,
                last_dev_nonce = undefined,
                adr_engine = ADREngine1,
                frame_cache = Cache1,
                fcnt = FCnt
            }};
        {send, Device1, DownlinkPacket, {ACK, ConfirmedDown, Port, Reply, ChannelMap}} ->
            IsDownlinkAck =
                case ACK of
                    1 -> true;
                    0 -> false
                end,
            ok = router_utils:event_downlink(
                IsDownlinkAck,
                ConfirmedDown,
                Port,
                Reply,
                Device1,
                ChannelMap,
                Blockchain,
                PubKeyBin,
                Packet,
                Region
            ),
            case router_utils:mtype_to_ack(Frame#frame.mtype) of
                1 -> router_device_routing:allow_replay(Packet, DeviceID, PacketTime);
                _ -> router_device_routing:clear_replay(DeviceID)
            end,
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            lager:debug("sending downlink for fcnt: ~p", [FCnt]),
            catch blockchain_state_channel_handler:send_response(
                Pid,
                blockchain_state_channel_response_v1:new(true, DownlinkPacket)
            ),

            ok = router_metrics:packet_trip_observe_end(
                blockchain_helium_packet_v1:packet_hash(Packet),
                PubKeyBin,
                erlang:system_time(millisecond),
                packet,
                true
            ),
            {noreply, State#state{
                device = Device1,
                last_dev_nonce = undefined,
                adr_engine = ADREngine1,
                frame_cache = Cache1,
                downlink_handled_at = FCnt,
                fcnt = FCnt
            }};
        noop ->
            catch blockchain_state_channel_handler:send_response(
                Pid,
                blockchain_state_channel_response_v1:new(true)
            ),
            router_device_routing:clear_replay(DeviceID),
            ok = router_metrics:packet_trip_observe_end(
                blockchain_helium_packet_v1:packet_hash(Packet),
                PubKeyBin,
                erlang:system_time(millisecond),
                packet,
                false
            ),
            {noreply, State#state{
                last_dev_nonce = undefined,
                frame_cache = Cache1,
                adr_engine = ADREngine1,
                fcnt = FCnt
            }}
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    lager:info("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec validate_join(
    blockchain_helium_packet_v1:packet(),
    libp2p_crypto:pubkey_to_bin(),
    atom(),
    non_neg_integer(),
    router_device:device(),
    binary(),
    router_device:device(),
    blockchain:blockchain()
) -> {ok, router_device:device(), binary(), binary()} | {error, any()}.
validate_join(
    #packet_pb{
        payload =
            <<MType:3, _MHDRRFU:3, _Major:2, _AppEUI0:8/binary, _DevEUI0:8/binary,
                DevNonce:2/binary, _MIC:4/binary>> = Payload
    } = Packet,
    PubKeyBin,
    Region,
    OUI,
    APIDevice,
    AppKey,
    Device,
    Blockchain
) when MType == ?JOIN_REQ ->
    PayloadSize = erlang:byte_size(Payload),
    case router_console_dc_tracker:charge(Device, PayloadSize, Blockchain) of
        {error, _} = Error ->
            Error;
        {ok, _, _} ->
            case lists:member(DevNonce, router_device:dev_nonces(Device)) of
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
-spec handle_join(
    blockchain_helium_packet_v1:packet(),
    libp2p_crypto:pubkey_to_bin(),
    atom(),
    non_neg_integer(),
    router_device:device(),
    binary(),
    router_device:device()
) -> {ok, router_device:device(), binary(), binary()}.
handle_join(
    #packet_pb{
        payload =
            <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, DevNonce:2/binary,
                _MIC:4/binary>>
    } = Packet,
    PubKeyBin,
    Region,
    _OUI,
    APIDevice,
    AppKey,
    Device0
) ->
    AppNonce = crypto:strong_rand_bytes(3),
    NwkSKey = crypto:block_encrypt(
        aes_ecb,
        AppKey,
        lorawan_utils:padded(16, <<16#01, AppNonce/binary, ?NET_ID/binary, DevNonce/binary>>)
    ),
    AppSKey = crypto:block_encrypt(
        aes_ecb,
        AppKey,
        lorawan_utils:padded(16, <<16#02, AppNonce/binary, ?NET_ID/binary, DevNonce/binary>>)
    ),
    DevAddr =
        case router_device_devaddr:allocate(Device0, PubKeyBin) of
            {ok, D} ->
                D;
            {error, _Reason} ->
                lager:warning("failed to allocate devaddr for ~p: ~p", [
                    router_device:id(Device0),
                    _Reason
                ]),
                router_device_devaddr:default_devaddr()
        end,
    DeviceName = router_device:name(APIDevice),
    %% don't set the join nonce here yet as we have not chosen the best join request yet
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    DeviceUpdates = [
        {name, DeviceName},
        {dev_eui, DevEUI},
        {app_eui, AppEUI},
        {keys, [{NwkSKey, AppSKey} | router_device:keys(Device0)]},
        {devaddr, DevAddr},
        {fcntdown, 0},
        %% only do channel correction for 915 right now
        {channel_correction, Region /= 'US915'},
        {location, PubKeyBin},
        {metadata, router_device:metadata(APIDevice)},
        {last_known_datarate, packet_datarate_to_dr(Packet, Region)},
        {region, Region}
    ],
    Device1 = router_device:update(DeviceUpdates, Device0),
    LoraRegion = lora_region(Region, PubKeyBin),
    Reply = craft_join_reply(LoraRegion, AppNonce, DevAddr, AppKey),
    lager:debug(
        "DevEUI ~s with AppEUI ~s tried to join with nonce ~p via ~s",
        [
            lorawan_utils:binary_to_hex(DevEUI),
            lorawan_utils:binary_to_hex(AppEUI),
            DevNonce,
            blockchain_utils:addr2name(PubKeyBin)
        ]
    ),
    {ok, Device1, DevNonce, Reply}.

-spec craft_join_reply(atom(), binary(), binary(), binary()) -> binary().
craft_join_reply(Region, AppNonce, DevAddr, AppKey) ->
    DLSettings = 0,
    ReplyHdr = <<?JOIN_ACCEPT:3, 0:3, 0:2>>,
    CFList =
        case Region of
            'EU868' ->
                %% In this case the CFList is a list of five channel frequencies for the channels
                %% three to seven whereby each frequency is encoded as a 24 bits unsigned integer
                %% (three octets). All these channels are usable for DR0 to DR5 125kHz LoRa
                %% modulation. The list of frequencies is followed by a single CFListType octet
                %% for a total of 16 octets. The CFListType SHALL be equal to zero (0) to indicate
                %% that the CFList contains a list of frequencies.
                %%
                %% The actual channel frequency in Hz is 100 x frequency whereby values representing
                %% frequencies below 100 MHz are reserved for future use.
                mk_cflist_for_freqs([8671000, 8673000, 8675000, 8677000, 8679000]);
            'AS923_AS1' ->
                mk_cflist_for_freqs([9222000, 9224000, 9226000, 9228000, 9230000]);
            'AS923_AS2' ->
                mk_cflist_for_freqs([9236000, 9238000, 9240000, 9242000, 9246000]);
            _ ->
                %% Not yet implemented for other regions
                <<>>
        end,
    ReplyPayload =
        <<AppNonce/binary, ?NET_ID/binary, DevAddr/binary, DLSettings:8/integer-unsigned,
            ?RX_DELAY:8/integer-unsigned, CFList/binary>>,
    ReplyMIC = crypto:cmac(aes_cbc128, AppKey, <<ReplyHdr/binary, ReplyPayload/binary>>, 4),
    EncryptedReply = crypto:block_decrypt(
        aes_ecb,
        AppKey,
        lorawan_utils:padded(16, <<ReplyPayload/binary, ReplyMIC/binary>>)
    ),
    <<ReplyHdr/binary, EncryptedReply/binary>>.

-spec do_multi_buy(
    Packet :: blockchain_helium_packet_v1:packet(),
    Device :: router_device:device(),
    FrameAck :: 0 | 1
) -> ok.
do_multi_buy(Packet, Device, FrameAck) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    MultiBuyValue = maps:get(multi_buy, router_device:metadata(Device), 1),
    case MultiBuyValue > 1 of
        true ->
            lager:debug("accepting more packets [multi_buy: ~p] for ~p", [MultiBuyValue, PHash]),
            router_device_routing:accept_more(PHash, MultiBuyValue);
        false ->
            case {router_device:queue(Device), FrameAck == 1} of
                {[], false} ->
                    lager:debug("denying more packets [queue_length: 0] [frame_ack: 0] for ~p", [
                        PHash
                    ]),
                    router_device_routing:deny_more(PHash);
                {_Queue, _Ack} ->
                    lager:debug(
                        "accepting more packets [queue_length: ~p] [frame_ack: ~p] for ~p",
                        [length(_Queue), _Ack, PHash]
                    ),
                    router_device_routing:accept_more(PHash)
            end
    end,
    ok.

%%%-------------------------------------------------------------------
%% @doc
%% Validate frame packet, figures out FPort/FOptsLen to see if
%% frame is valid and check if packet is ACKnowledging
%% previous packet sent
%% @end
%%%-------------------------------------------------------------------
-spec validate_frame(
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Device :: router_device:device(),
    Blockchain :: blockchain:blockchain(),
    {LastSeenFCnt :: non_neg_integer(), DownlinkHanldedAt :: integer()},
    FrameCache :: #{integer() => #frame_cache{}}
) ->
    {error, any()}
    | {ok, #frame{}, router_device:device(), SendToChannel :: boolean(),
        {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}}.
validate_frame(
    Packet,
    PacketTime,
    PubKeyBin,
    Region,
    Device0,
    Blockchain,
    {LastSeenFCnt, DownlinkHandledAt},
    FrameCache
) ->
    <<MType:3, _MHDRRFU:3, _Major:2, _DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
        _FOptsLen:4, FCnt:16/little-unsigned-integer, _FOpts:_FOptsLen/binary,
        _PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),

    FrameAck = router_utils:mtype_to_ack(MType),
    Window = erlang:system_time(millisecond) - PacketTime,
    case maps:get(FCnt, FrameCache, undefined) of
        #frame_cache{} ->
            validate_frame_(Packet, PubKeyBin, Region, Device0, Blockchain);
        undefined when FrameAck == 0 andalso FCnt =< LastSeenFCnt ->
            lager:debug("we got a late unconfirmed up packet for ~p: lastSeendFCnt: ~p", [
                FCnt,
                LastSeenFCnt
            ]),
            {error, late_packet};
        undefined when
            FrameAck == 1 andalso FCnt == DownlinkHandledAt andalso Window < ?RX_MAX_WINDOW
        ->
            lager:debug(
                "we got a late confirmed up packet for ~p: DownlinkHandledAt: ~p within window ~p",
                [FCnt, DownlinkHandledAt, Window]
            ),
            {error, late_packet};
        undefined when
            FrameAck == 1 andalso FCnt == DownlinkHandledAt andalso Window >= ?RX_MAX_WINDOW
        ->
            lager:debug(
                "we got a replay confirmed up packet for ~p: DownlinkHandledAt: ~p outside window ~p",
                [FCnt, DownlinkHandledAt, Window]
            ),
            validate_frame_(Packet, PubKeyBin, Region, Device0, Blockchain);
        undefined ->
            ok = do_multi_buy(Packet, Device0, FrameAck),
            validate_frame_(Packet, PubKeyBin, Region, Device0, Blockchain)
    end.

-spec validate_frame_(
    Packet :: blockchain_helium_packet_v1:packet(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Device :: router_device:device(),
    Blockchain :: blockchain:blockchain()
) ->
    {ok, #frame{}, router_device:device(), SendToChannel :: boolean(),
        {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}}
    | {error, any()}.
validate_frame_(Packet, PubKeyBin, Region, Device0, Blockchain) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1, FOptsLen:4,
        FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary,
        PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    DevEUI = router_device:dev_eui(Device0),
    AppEUI = router_device:app_eui(Device0),
    AName = blockchain_utils:addr2name(PubKeyBin),
    TS = blockchain_helium_packet_v1:timestamp(Packet),
    lager:debug("validating frame ~p @ ~p (devaddr: ~p) from ~p", [FCnt, TS, DevAddr, AName]),
    PayloadSize = erlang:byte_size(FRMPayload),
    case router_console_dc_tracker:charge(Device0, PayloadSize, Blockchain) of
        {error, Reason} ->
            %% REVIEW: Do we want to update region and datarate for an uncharged packet?
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
                    Data = lorawan_utils:reverse(
                        lorawan_utils:cipher(FRMPayload, NwkSKey, MType band 1, DevAddr, FCnt)
                    ),
                    lager:debug(
                        "~s packet from ~s ~s with fopts ~p received by ~s",
                        [
                            lorawan_utils:mtype(MType),
                            lorawan_utils:binary_to_hex(DevEUI),
                            lorawan_utils:binary_to_hex(AppEUI),
                            lorawan_mac_commands:parse_fopts(Data),
                            AName
                        ]
                    ),
                    BaseDeviceUpdates = [
                        {fcnt, FCnt},
                        {location, PubKeyBin},
                        {region, Region},
                        {last_known_datarate, packet_datarate_to_dr(Packet, Region)}
                    ],
                    %% If frame countain ACK=1 we should clear message from queue and go on next
                    QueueDeviceUpdates =
                        case {ACK, router_device:queue(Device0)} of
                            %% Check if acknowledging confirmed downlink
                            {1, [#downlink{confirmed = true} | T]} ->
                                [{queue, T}, {fcntdown, router_device:fcntdown(Device0) + 1}];
                            {1, _} ->
                                lager:warning("got ack when no confirmed downlinks in queue"),
                                [];
                            _ ->
                                []
                        end,
                    Device1 = router_device:update(
                        QueueDeviceUpdates ++ BaseDeviceUpdates,
                        Device0
                    ),
                    Frame = #frame{
                        mtype = MType,
                        devaddr = DevAddr,
                        adr = ADR,
                        adrackreq = ADRACKReq,
                        ack = ACK,
                        rfu = RFU,
                        fcnt = FCnt,
                        fopts = lorawan_mac_commands:parse_fopts(Data),
                        fport = FPort,
                        data = undefined
                    },
                    {ok, Frame, Device1, false, {Balance, Nonce}};
                0 when FOptsLen /= 0 ->
                    lager:debug(
                        "bad ~s packet from ~s ~s received by ~s -- double fopts~n",
                        [
                            lorawan_utils:mtype(MType),
                            lorawan_utils:binary_to_hex(DevEUI),
                            lorawan_utils:binary_to_hex(AppEUI),
                            AName
                        ]
                    ),
                    {error, double_fopts};
                _N ->
                    AppSKey = router_device:app_s_key(Device0),
                    Data = lorawan_utils:reverse(
                        lorawan_utils:cipher(FRMPayload, AppSKey, MType band 1, DevAddr, FCnt)
                    ),
                    lager:debug(
                        "~s packet from ~s ~s with ACK ~p fopts ~p " ++
                            "fcnt ~p and data ~p received by ~s",
                        [
                            lorawan_utils:mtype(MType),
                            lorawan_utils:binary_to_hex(DevEUI),
                            lorawan_utils:binary_to_hex(AppEUI),
                            ACK,
                            lorawan_mac_commands:parse_fopts(FOpts),
                            FCnt,
                            Data,
                            AName
                        ]
                    ),

                    BaseDeviceUpdates = [
                        {fcnt, FCnt},
                        {region, Region},
                        {last_known_datarate, packet_datarate_to_dr(Packet, Region)}
                    ],
                    %% If frame countain ACK=1 we should clear message from queue and go on next
                    QueueDeviceUpdates =
                        case {ACK, router_device:queue(Device0)} of
                            %% Check if acknowledging confirmed downlink
                            {1, [#downlink{confirmed = true} | T]} ->
                                [{queue, T}, {fcntdown, router_device:fcntdown(Device0) + 1}];
                            {1, _} ->
                                lager:warning("got ack when no confirmed downlinks in queue"),
                                [];
                            _ ->
                                []
                        end,
                    Device1 = router_device:update(
                        QueueDeviceUpdates ++ BaseDeviceUpdates,
                        Device0
                    ),
                    Frame = #frame{
                        mtype = MType,
                        devaddr = DevAddr,
                        adr = ADR,
                        adrackreq = ADRACKReq,
                        ack = ACK,
                        rfu = RFU,
                        fcnt = FCnt,
                        fopts = lorawan_mac_commands:parse_fopts(FOpts),
                        fport = FPort,
                        data = Data
                    },
                    {ok, Frame, Device1, true, {Balance, Nonce}}
            end
    end.

%%%-------------------------------------------------------------------
%% @doc
%% Check device's message queue to potentially wait or send reply
%% right away
%% @end
%%%-------------------------------------------------------------------
-spec handle_frame_timeout(
    Packet0 :: blockchain_helium_packet_v1:packet(),
    Region :: atom(),
    Device0 :: router_device:device(),
    Frame :: #frame{},
    Count :: pos_integer(),
    ADRAdjustment :: lorwan_adr:adjustment(),
    [#downlink{}]
) ->
    noop
    | {ok, router_device:device()}
    | {send, router_device:device(), blockchain_helium_packet_v1:packet(), tuple()}.
handle_frame_timeout(
    Packet0,
    Region,
    Device0,
    Frame,
    Count,
    ADRAdjustment,
    []
) ->
    ACK = router_utils:mtype_to_ack(Frame#frame.mtype),
    WereChannelsCorrected = were_channels_corrected(Frame, Region),
    ChannelCorrection = router_device:channel_correction(Device0),
    {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(
        Packet0,
        Region,
        Device0,
        Frame,
        Count,
        ADRAdjustment
    ),
    lager:debug(
        "downlink with no queue, ACK ~p, Fopts ~p, channels corrected ~p -> ~p, ADR adjustment ~p",
        [
            ACK,
            FOpts1,
            ChannelCorrection,
            WereChannelsCorrected,
            ADRAdjustment
        ]
    ),
    case ACK of
        _ when ACK == 1 orelse FOpts1 /= [] ->
            ConfirmedDown = false,
            Port = 0,
            FCntDown = router_device:fcntdown(Device0),
            MType = ack_to_mtype(ConfirmedDown),
            Reply = frame_to_packet_payload(
                #frame{
                    mtype = MType,
                    devaddr = Frame#frame.devaddr,
                    fcnt = FCntDown,
                    fopts = FOpts1,
                    fport = Port,
                    ack = ACK,
                    data = <<>>
                },
                Device0
            ),
            #txq{
                time = TxTime,
                datr = TxDataRate,
                freq = TxFreq
            } = lorawan_mac_region:rx1_window(
                Region,
                0,
                0,
                packet_to_rxq(Packet0)
            ),
            Rx2 = rx2_from_packet(Region, Packet0),
            Packet1 = blockchain_helium_packet_v1:new_downlink(
                Reply,
                27,
                adjust_rx_time(TxTime),
                TxFreq,
                binary_to_list(TxDataRate),
                Rx2
            ),
            DeviceUpdates = [
                {channel_correction, ChannelsCorrected},
                {fcntdown, (FCntDown + 1)}
            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            EventTuple =
                {ACK, ConfirmedDown, Port, Reply, #{id => undefined, name => <<"router">>}},
            case ChannelCorrection == false andalso WereChannelsCorrected == true of
                true ->
                    {send, router_device:channel_correction(true, Device1), Packet1, EventTuple};
                false ->
                    {send, Device1, Packet1, EventTuple}
            end;
        _ when ChannelCorrection == false andalso WereChannelsCorrected == true ->
            %% we corrected the channels but don't have anything else to send
            %% so just update the device
            {ok, router_device:channel_correction(true, Device0)};
        _ ->
            noop
    end;
handle_frame_timeout(
    Packet0,
    Region,
    Device0,
    Frame,
    Count,
    ADRAdjustment,
    [
        #downlink{confirmed = ConfirmedDown, port = Port, payload = ReplyPayload, channel = Channel}
        | T
    ]
) ->
    ACK = router_utils:mtype_to_ack(Frame#frame.mtype),
    MType = ack_to_mtype(ConfirmedDown),
    WereChannelsCorrected = were_channels_corrected(Frame, Region),
    {ChannelsCorrected, FOpts1} = channel_correction_and_fopts(
        Packet0,
        Region,
        Device0,
        Frame,
        Count,
        ADRAdjustment
    ),
    lager:debug(
        "downlink with ~p, confirmed ~p port ~p ACK ~p and" ++
            " channels corrected ~p, ADR adjustment ~p, FOpts ~p",
        [
            ReplyPayload,
            ConfirmedDown,
            Port,
            ACK,
            router_device:channel_correction(Device0) orelse WereChannelsCorrected,
            ADRAdjustment,
            FOpts1
        ]
    ),
    FCntDown = router_device:fcntdown(Device0),
    FPending =
        case T of
            [] ->
                %% no more packets
                0;
            _ ->
                %% more pending downlinks
                1
        end,
    Reply = frame_to_packet_payload(
        #frame{
            mtype = MType,
            devaddr = Frame#frame.devaddr,
            fcnt = FCntDown,
            fopts = FOpts1,
            fport = Port,
            ack = ACK,
            data = ReplyPayload,
            fpending = FPending
        },
        Device0
    ),
    #txq{
        time = TxTime,
        datr = TxDataRate,
        freq = TxFreq
    } = lorawan_mac_region:rx1_window(
        Region,
        0,
        0,
        packet_to_rxq(Packet0)
    ),
    Rx2 = rx2_from_packet(Region, Packet0),
    Packet1 = blockchain_helium_packet_v1:new_downlink(
        Reply,
        27,
        adjust_rx_time(TxTime),
        TxFreq,
        binary_to_list(TxDataRate),
        Rx2
    ),
    EventTuple = {ACK, ConfirmedDown, Port, Reply, router_channel:to_map(Channel)},
    case ConfirmedDown of
        true ->
            Device1 = router_device:channel_correction(ChannelsCorrected, Device0),
            {send, Device1, Packet1, EventTuple};
        false ->
            DeviceUpdates = [
                {queue, T},
                {channel_correction, ChannelsCorrected},
                {fcntdown, (FCntDown + 1)}
            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            {send, Device1, Packet1, EventTuple}
    end.

%% TODO: we need `link_adr_answer' for ADR. Suggest refactoring this.
-spec channel_correction_and_fopts(
    blockchain_helium_packet_v1:packet(),
    atom(),
    router_device:device(),
    #frame{},
    pos_integer(),
    lorawan_adr:adjustment()
) -> {boolean(), list()}.
channel_correction_and_fopts(Packet, Region, Device, Frame, Count, ADRAdjustment) ->
    ChannelsCorrected = were_channels_corrected(Frame, Region),
    DataRate = blockchain_helium_packet_v1:datarate(Packet),
    ChannelCorrection = router_device:channel_correction(Device),
    ChannelCorrectionNeeded = ChannelCorrection == false,
    %% begin-needs-refactor
    %%
    %% TODO: I don't know if we track these channel lists elsewhere,
    %%       but since they were already hardcoded for 'US915' below,
    %%       here's a few more.
    Channels =
        case Region of
            'US915' ->
                {8, 15};
            'AU915' ->
                {8, 15};
            _ ->
                AssumedChannels = {0, 7},
                lager:warning("confirm channel plan for region ~p, assuming ~p", [
                    Region,
                    AssumedChannels
                ]),
                AssumedChannels
        end,
    %% end-needs-refactor
    FOpts1 =
        case {ChannelCorrectionNeeded, ChannelsCorrected, ADRAdjustment} of
            %% TODO this is going to be different for each region,
            %% we can't simply pass the region into this function
            %% Some regions allow the channel list to be sent in the join response as well,
            %% so we may need to do that there as well
            {true, false, _} ->
                lorawan_mac_region:set_channels(
                    Region,
                    {0, erlang:list_to_binary(DataRate), [Channels]},
                    []
                );
            {false, _, {NewDataRateIdx, NewTxPowerIdx}} ->
                %% begin-needs-refactor
                %%
                %% This is silly because `NewDr' is converted right
                %% back to the value `NewDataRateIdx' inside
                %% `lorwan_mac_region'.  But `set_channels' wants data
                %% rate in the form of "SFdd?BWddd?" so that's what
                %% we'll give it.
                NewDr = lorawan_mac_region:dr_to_datar(Region, NewDataRateIdx),
                %% end-needs-refactor
                lorawan_mac_region:set_channels(
                    Region,
                    {NewTxPowerIdx, NewDr, [Channels]},
                    []
                );
            _ ->
                []
        end,
    FOpts2 =
        case lists:member(link_check_req, Frame#frame.fopts) of
            true ->
                SNR = blockchain_helium_packet_v1:snr(Packet),
                MaxUplinkSNR = lorawan_mac_region:max_uplink_snr(
                    list_to_binary(blockchain_helium_packet_v1:datarate(Packet))
                ),
                Margin = trunc(SNR - MaxUplinkSNR),
                lager:debug("respond to link_check_req with link_check_ans ~p ~p", [Margin, Count]),
                [{link_check_ans, Margin, Count} | FOpts1];
            false ->
                FOpts1
        end,
    {ChannelsCorrected orelse ChannelCorrection, FOpts2}.

%% TODO: with ADR implemented, this function, or at least its name,
%%       doesn't make much sense anymore; it may return true for any
%%       or all of these reasons:
%%
%%       - accepts new data rate
%%       - accepts new transmit power
%%       - accepts new channel mask
were_channels_corrected(Frame, 'US915') ->
    FOpts0 = Frame#frame.fopts,
    case lists:keyfind(link_adr_ans, 1, FOpts0) of
        {link_adr_ans, 1, 1, 1} ->
            true;
        {link_adr_ans, TxPowerACK, DataRateACK, ChannelMaskACK} ->
            %% consider any answer good enough, if the device wants to reject things,
            %% nothing we can so
            lager:debug("device rejected ADR: TxPower: ~p DataRate: ~p, Channel Mask: ~p", [
                TxPowerACK == 1,
                DataRateACK == 1,
                ChannelMaskACK == 1
            ]),
            %% XXX we should get this to report_status somehow, but it's a bit tricky right now
            true;
        _ ->
            false
    end;
were_channels_corrected(_Frame, _Region) ->
    %% we only do channel correction for 915 right now
    true.

-spec ack_to_mtype(boolean()) -> integer().
ack_to_mtype(true) -> ?CONFIRMED_DOWN;
ack_to_mtype(_) -> ?UNCONFIRMED_DOWN.

-spec frame_to_packet_payload(#frame{}, router_device:device()) -> binary().
frame_to_packet_payload(Frame, Device) ->
    FOpts = lorawan_mac_commands:encode_fopts(Frame#frame.fopts),
    FOptsLen = erlang:byte_size(FOpts),
    PktHdr =
        <<(Frame#frame.mtype):3, 0:3, 0:2, (Frame#frame.devaddr)/binary, (Frame#frame.adr):1, 0:1,
            (Frame#frame.ack):1, (Frame#frame.fpending):1, FOptsLen:4,
            (Frame#frame.fcnt):16/integer-unsigned-little, FOpts:FOptsLen/binary>>,
    NwkSKey = router_device:nwk_s_key(Device),
    PktBody =
        case Frame#frame.data of
            <<>> ->
                %% no payload
                <<>>;
            <<Payload/binary>> when Frame#frame.fport == 0 ->
                lager:debug("port 0 outbound"),
                %% port 0 payload, encrypt with network key
                <<0:8/integer-unsigned,
                    (lorawan_utils:reverse(
                        lorawan_utils:cipher(
                            Payload,
                            NwkSKey,
                            1,
                            Frame#frame.devaddr,
                            Frame#frame.fcnt
                        )
                    ))/binary>>;
            <<Payload/binary>> ->
                lager:debug("port ~p outbound", [Frame#frame.fport]),
                AppSKey = router_device:app_s_key(Device),
                EncPayload = lorawan_utils:reverse(
                    lorawan_utils:cipher(Payload, AppSKey, 1, Frame#frame.devaddr, Frame#frame.fcnt)
                ),
                <<(Frame#frame.fport):8/integer-unsigned, EncPayload/binary>>
        end,
    Msg = <<PktHdr/binary, PktBody/binary>>,
    MIC = crypto:cmac(
        aes_cbc128,
        NwkSKey,
        <<(router_utils:b0(1, Frame#frame.devaddr, Frame#frame.fcnt, byte_size(Msg)))/binary,
            Msg/binary>>,
        4
    ),
    <<Msg/binary, MIC/binary>>.

-spec join2_from_packet(atom(), blockchain_helium_packet_v1:packet()) ->
    blockchain_helium_packet_v1:window().
join2_from_packet(Region, Packet) ->
    Rxq = packet_to_rxq(Packet),
    #txq{
        time = TxTime,
        datr = TxDataRate,
        freq = TxFreq
    } = lorawan_mac_region:join2_window(Region, Rxq),
    blockchain_helium_packet_v1:window(adjust_rx_time(TxTime), TxFreq, binary_to_list(TxDataRate)).

-spec rx2_from_packet(atom(), blockchain_helium_packet_v1:packet()) ->
    blockchain_helium_packet_v1:window().
rx2_from_packet(Region, Packet) ->
    Rxq = packet_to_rxq(Packet),
    #txq{
        time = TxTime,
        datr = TxDataRate,
        freq = TxFreq
    } = lorawan_mac_region:rx2_window(Region, Rxq),
    blockchain_helium_packet_v1:window(adjust_rx_time(TxTime), TxFreq, binary_to_list(TxDataRate)).

-spec adjust_rx_time(non_neg_integer()) -> non_neg_integer().
adjust_rx_time(Time) ->
    Time band 4294967295.

-spec packet_to_rxq(blockchain_helium_packet_v1:packet()) -> #rxq{}.
packet_to_rxq(Packet) ->
    #rxq{
        freq = blockchain_helium_packet_v1:frequency(Packet),
        datr = list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
        codr = <<"4/5">>,
        time = calendar:now_to_datetime(os:timestamp()),
        tmms = blockchain_helium_packet_v1:timestamp(Packet),
        rssi = blockchain_helium_packet_v1:signal_strength(Packet),
        lsnr = blockchain_helium_packet_v1:snr(Packet)
    }.

-spec save_and_update(rocksdb:db_handle(), rocksdb:cf_handle(), pid(), router_device:device()) ->
    ok.
save_and_update(DB, CF, Pid, Device) ->
    {ok, _} = router_device_cache:save(Device),
    {ok, _} = router_device:save(DB, CF, Device),
    ok = router_device_channels_worker:handle_device_update(Pid, Device).

-spec get_device(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> router_device:device().
get_device(DB, CF, ID) ->
    case router_device:get_by_id(DB, CF, ID) of
        {ok, D} -> D;
        _ -> router_device:new(ID)
    end.

-spec maybe_construct_adr_engine(undefined | lorawan_adr:handle(), atom()) -> lorawan_adr:handle().
maybe_construct_adr_engine(Other, Region) ->
    case Other of
        undefined ->
            lorawan_adr:new(Region);
        _ ->
            Other
    end.

-spec maybe_track_adr_offer(
    Device :: router_device:device(),
    ADREngine0 :: undefined | lorawan_adr:handle(),
    Offer :: blockchain_state_channel_offer_v1:offer()
) -> undefined | lorawan_adr:handle().
maybe_track_adr_offer(Device, ADREngine0, Offer) ->
    Metadata = router_device:metadata(Device),
    case maps:get(adr_allowed, Metadata, false) of
        false ->
            undefined;
        true ->
            Region = blockchain_state_channel_offer_v1:region(Offer),
            ADREngine1 = maybe_construct_adr_engine(ADREngine0, Region),
            AdrOffer = #adr_offer{
                hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
                packet_hash = blockchain_state_channel_offer_v1:packet_hash(Offer)
            },
            lorawan_adr:track_offer(ADREngine1, AdrOffer)
    end.

-spec maybe_track_adr_packet(
    Device :: router_device:device(),
    ADREngine0 :: undefined | lorawan_adr:handle(),
    FrameCache :: #frame_cache{}
) -> {undefined | lorawan_adr:handle(), lorawan_adr:adjustment()}.
maybe_track_adr_packet(Device, ADREngine0, FrameCache) ->
    Metadata = router_device:metadata(Device),
    case maps:get(adr_allowed, Metadata, false) of
        %% The device owner can disable ADR (wants_adr == false) and
        %% supersede the device's desire to be ADR controlled.
        false ->
            {undefined, hold};
        true ->
            #frame_cache{
                rssi = RSSI,
                packet = Packet,
                pubkey_bin = PubKeyBin,
                frame = Frame,
                region = Region
            } = FrameCache,
            #frame{fopts = FOpts, adr = ADRBit, adrackreq = ADRAckReqBit} = Frame,
            ADREngine1 = maybe_construct_adr_engine(ADREngine0, Region),
            AlreadyHasChannelCorrection = router_device:channel_correction(Device),
            ADRAns = lists:keyfind(link_adr_ans, 1, FOpts),
            ADREngine2 =
                case {AlreadyHasChannelCorrection, ADRAns} of
                    %% We are not waiting for a channel correction AND got an
                    %% ADR answer. Inform ADR about that.
                    {true, {link_adr_ans, ChannelMaskAck, DatarateAck, PowerAck}} ->
                        N2B = fun(N) ->
                            case N of
                                0 -> false;
                                1 -> true
                            end
                        end,
                        ADRAnswer = #adr_answer{
                            channel_mask_ack = N2B(ChannelMaskAck),
                            datarate_ack = N2B(DatarateAck),
                            power_ack = N2B(PowerAck)
                        },
                        lorawan_adr:track_adr_answer(ADREngine1, ADRAnswer);
                    {false, {link_adr_ans, _, _, _}} ->
                        lager:debug(
                            "ignoring ADR answer while waiting for channel correction ~p",
                            [
                                ADRAns
                            ]
                        ),
                        ADREngine1;
                    %% Either we're waiting for a channel correction, or this
                    %% is not an ADRAns, so do nothing.
                    _ ->
                        ADREngine1
                end,

            %% TODO: when purchasing multiple packets, is the best SNR/RSSI
            %%       packet reported here? If not, may need to refactor to do so.
            DataRate = blockchain_helium_packet_v1:datarate(Packet),
            DataRateConfig = lorawan_utils:parse_datarate(DataRate),
            AdrPacket = #adr_packet{
                packet_hash = blockchain_helium_packet_v1:packet_hash(Packet),
                wants_adr = ADRBit == 1,
                wants_adr_ack = ADRAckReqBit == 1,
                datarate_config = DataRateConfig,
                snr = blockchain_helium_packet_v1:snr(Packet),
                rssi = RSSI,
                hotspot = PubKeyBin
            },
            lorawan_adr:track_packet(
                ADREngine2,
                AdrPacket
            )
    end.

-spec mk_cflist_for_freqs(list(non_neg_integer())) -> binary().
mk_cflist_for_freqs(Frequencies) ->
    Channels = <<
        <<X:24/integer-unsigned-little>>
        || X <- Frequencies
    >>,
    <<Channels/binary, 0:8/integer>>.

-spec lora_region(atom(), libp2p_crypto:pubkey_bin()) -> atom().
lora_region(Region, PubKeyBin) ->
    case Region of
        'AS923_AS1' ->
            Region;
        'AS923_AS2' ->
            Region;
        'AS923' ->
            case lorawan_location:get_country_code(PubKeyBin) of
                {ok, CountryCode} ->
                    lorawan_location:as923_region_from_country_code(CountryCode);
                {error, _Reason} ->
                    lager:warning(
                        "Failed to get country for AS923: ~p [pubkeybin: ~p] [hotspot: ~p]",
                        [
                            _Reason,
                            PubKeyBin,
                            blockchain_utils:addr2name(PubKeyBin)
                        ]
                    ),
                    %% Default to AS923 region with more countries
                    'AS923_AS2'
            end;
        _ ->
            Region
    end.

-spec packet_datarate_to_dr(Packet :: blockchain_helium_packet_v1:packet(), Region :: atom()) ->
    integer().
packet_datarate_to_dr(Packet, Region) ->
    Datarate = erlang:list_to_binary(
        blockchain_helium_packet_v1:datarate(Packet)
    ),
    lorawan_mac_region:datar_to_dr(
        Region,
        Datarate
    ).
