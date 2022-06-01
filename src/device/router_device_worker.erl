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
    accept_uplink/5,
    handle_join/9,
    handle_frame/8,
    get_queue_updates/3,
    stop_queue_updates/1,
    queue_downlink/2,
    queue_downlink/3,
    device_update/1,
    clear_queue/1,
    fake_join/2
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

%% This is only used when NO downlink must be sent to the device.
%% 2 seconds was picked as it is the RX_MAX_WINDOW
-define(DEFAULT_FRAME_TIMEOUT, timer:seconds(2)).

-define(RX_MAX_WINDOW, 2000).

-record(state, {
    chain :: blockchain:blockchain(),
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle(),
    frame_timeout :: non_neg_integer(),
    device :: router_device:device(),
    downlink_handled_at = {-1, erlang:system_time(millisecond)} :: {integer(), integer()},
    queue_updates :: undefined | {pid(), undefined | binary(), reference()},
    fcnt = -1 :: integer(),
    oui :: undefined | non_neg_integer(),
    channels_worker :: pid(),
    last_dev_nonce = undefined :: binary() | undefined,
    join_cache = #{} :: #{integer() => #join_cache{}},
    frame_cache = #{} :: #{integer() => #frame_cache{}},
    offer_cache = #{} :: #{{libp2p_crypto:pubkey_bin(), binary()} => non_neg_integer()},
    adr_engine :: undefined | lorawan_adr:handle(),
    is_active = true :: boolean(),
    discovery = false :: boolean()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_offer(pid(), blockchain_state_channel_offer_v1:offer()) -> ok.
handle_offer(WorkerPid, Offer) ->
    gen_server:cast(WorkerPid, {handle_offer, Offer}).

-spec accept_uplink(
    WorkerPid :: pid(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    HoldTime :: non_neg_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> boolean().
accept_uplink(WorkerPid, Packet, PacketTime, HoldTime, PubKeyBin) ->
    gen_server:call(WorkerPid, {accept_uplink, Packet, PacketTime, HoldTime, PubKeyBin}).

-spec handle_join(
    WorkerPid :: pid(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: pos_integer(),
    _HoldTime :: pos_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    APIDevice :: router_device:device(),
    AppKey :: binary(),
    Pid :: pid()
) -> ok.
handle_join(WorkerPid, Packet, PacketTime, HoldTime, PubKeyBin, Region, APIDevice, AppKey, Pid) ->
    gen_server:cast(
        WorkerPid,
        {join, Packet, PacketTime, HoldTime, PubKeyBin, Region, APIDevice, AppKey, Pid}
    ).

-spec handle_frame(
    WorkerPid :: pid(),
    NwkSKey :: binary(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: pos_integer(),
    _HoldTime :: pos_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Pid :: pid()
) -> ok.
handle_frame(WorkerPid, NwkSKey, Packet, PacketTime, HoldTime, PubKeyBin, Region, Pid) ->
    gen_server:cast(
        WorkerPid,
        {frame, NwkSKey, Packet, PacketTime, HoldTime, PubKeyBin, Region, Pid}
    ).

-spec get_queue_updates(Pid :: pid(), ForwardPid :: pid(), LabelID :: undefined | binary()) -> ok.
get_queue_updates(Pid, ForwardPid, LabelID) ->
    gen_server:cast(Pid, {get_queue_updates, ForwardPid, LabelID}).

-spec stop_queue_updates(Pid :: pid()) -> ok.
stop_queue_updates(Pid) ->
    Pid ! stop_queue_updates,
    ok.

-spec queue_downlink(pid(), #downlink{}) -> ok.
queue_downlink(Pid, #downlink{} = Downlink) ->
    ?MODULE:queue_downlink(Pid, Downlink, last).

-spec queue_downlink(pid(), #downlink{}, first | last) -> ok.
queue_downlink(Pid, #downlink{} = Downlink, Position) ->
    gen_server:cast(Pid, {queue_downlink, Downlink, Position}).

-spec clear_queue(Pid :: pid()) -> ok.
clear_queue(Pid) ->
    gen_server:cast(Pid, clear_queue).

-spec device_update(Pid :: pid()) -> ok.
device_update(Pid) ->
    gen_server:cast(Pid, device_update).

-spec fake_join(Pid :: pid(), PubkeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, router_device:device()} | {error, any(), router_device:device()}.
fake_join(Pid, PubkeyBin) ->
    gen_server:call(Pid, {fake_join, PubkeyBin}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{db := DB, cf := CF, id := ID} = Args) ->
    Discovery =
        case maps:get(discovery, Args, false) of
            true ->
                true;
            _ ->
                false
        end,
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
    DefaultFrameTimeout = maps:get(frame_timeout, Args, router_utils:frame_timeout()),
    lager:info("~p init with ~p (frame timeout=~p)", [?SERVER, Args, DefaultFrameTimeout]),
    {ok, #state{
        chain = Blockchain,
        db = DB,
        cf = CF,
        frame_timeout = DefaultFrameTimeout,
        device = Device,
        fcnt = router_device:fcnt(Device),
        oui = OUI,
        channels_worker = Pid,
        is_active = IsActive,
        discovery = Discovery
    }}.

handle_call(
    {accept_uplink, Packet, PacketTime, HoldTime, PubKeyBin},
    _From,
    #state{device = Device, offer_cache = OfferCache0} = State
) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    case maps:get({PubKeyBin, PHash}, OfferCache0, undefined) of
        undefined ->
            lager:debug("accepting, we got a packet from ~p with no matching offer (~p)", [
                blockchain_utils:addr2name(PubKeyBin),
                PHash
            ]),
            {reply, true, State};
        OfferTime ->
            DeliveryTime = erlang:system_time(millisecond) - OfferTime,
            case DeliveryTime >= ?RX_MAX_WINDOW of
                true ->
                    <<_MType:3, _MHDRRFU:3, _Major:2, _DevAddr:4/binary, _ADR:1, _ADRACKReq:1,
                        _ACK:1, _RFU:1, _FOptsLen:4, FCnt:16/little-unsigned-integer,
                        _FOpts:_FOptsLen/binary,
                        _PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),
                    case FCnt > router_device:fcnt(Device) of
                        false ->
                            lager:info(
                                "refusing, we got a packet (~p) delivered ~p ms too late from ~p (~p)",
                                [
                                    FCnt,
                                    DeliveryTime,
                                    blockchain_utils:addr2name(PubKeyBin),
                                    PHash
                                ]
                            ),
                            ok = router_utils:event_uplink_dropped_late_packet(
                                PacketTime,
                                HoldTime,
                                FCnt,
                                Device,
                                PubKeyBin
                            ),
                            {reply, false, State};
                        true ->
                            lager:info(
                                "accepting even if we got packet (~p) delivered ~p ms too late from ~p (~p)",
                                [
                                    FCnt,
                                    DeliveryTime,
                                    blockchain_utils:addr2name(PubKeyBin),
                                    PHash
                                ]
                            ),
                            {reply, true, State}
                    end;
                false ->
                    lager:debug("accepting, we got a packet from ~p (~p)", [
                        blockchain_utils:addr2name(PubKeyBin),
                        PHash
                    ]),
                    {reply, true, State}
            end
    end;
handle_call(
    {fake_join, PubKeyBin},
    _From,
    #state{
        db = DB,
        cf = CF,
        device = Device0,
        channels_worker = ChannelsWorker
    } = State
) ->
    lager:info("faking join"),
    DevEui = router_device:dev_eui(Device0),
    AppEui = router_device:app_eui(Device0),
    case router_console_api:get_devices_by_deveui_appeui(DevEui, AppEui) of
        [] ->
            lager:error("failed to get app key for device ~p with DevEUI=~p AppEUI=~p", [
                router_device:id(Device0),
                lorawan_utils:binary_to_hex(DevEui),
                lorawan_utils:binary_to_hex(AppEui)
            ]),
            {reply, {error, no_app_key, Device0}, State};
        [{AppKey, _} | _] ->
            AppNonce = crypto:strong_rand_bytes(3),
            DevNonce = crypto:strong_rand_bytes(2),
            NwkSKey = crypto:crypto_one_time(
                aes_128_ecb,
                AppKey,
                lorawan_utils:padded(
                    16,
                    <<16#01, AppNonce/binary, ?NET_ID/binary, DevNonce/binary>>
                ),
                true
            ),
            AppSKey = crypto:crypto_one_time(
                aes_128_ecb,
                AppKey,
                lorawan_utils:padded(
                    16,
                    <<16#02, AppNonce/binary, ?NET_ID/binary, DevNonce/binary>>
                ),
                true
            ),
            {ok, DevAddr} = router_device_devaddr:allocate(Device0, PubKeyBin),
            DeviceUpdates = [
                {keys, [{NwkSKey, AppSKey}]},
                {devaddrs, [DevAddr]},
                {fcntdown, 0},
                {channel_correction, false}
            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            {reply, {ok, Device1}, State#state{
                device = Device1,
                downlink_handled_at = {-1, erlang:system_time(millisecond)},
                fcnt = -1
            }}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {handle_offer, Offer},
    #state{device = Device, offer_cache = OfferCache0, adr_engine = ADREngine0} = State
) ->
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),
    lager:debug("handle offer for ~p PHash=~p", [
        blockchain_utils:addr2name(PubKeyBin),
        PHash
    ]),
    OfferCache1 = maps:put({PubKeyBin, PHash}, erlang:system_time(millisecond), OfferCache0),
    ADREngine1 = maybe_track_adr_offer(Device, ADREngine0, Offer),

    Now = erlang:system_time(millisecond),
    TenMin = application:get_env(router, offer_cache_timeout, timer:minutes(2)),
    FilterFun = fun(_, OfferTime) ->
        Now - OfferTime < TenMin
    end,
    OfferCache2 = maps:filter(FilterFun, OfferCache1),
    lager:debug("we got ~p offers in cache", [maps:size(OfferCache2)]),

    {noreply, State#state{offer_cache = OfferCache2, adr_engine = ADREngine1}};
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
            DevAddrs =
                case
                    {
                        {router_device:app_eui(Device0), router_device:app_eui(APIDevice)},
                        {router_device:dev_eui(Device0), router_device:dev_eui(APIDevice)}
                    }
                of
                    {{App, App}, {Dev, Dev}} ->
                        [router_device:devaddr(Device0)];
                    _ ->
                        lager:info("app_eui or dev_eui changed, unsetting devaddr"),
                        []
                end,

            DeviceUpdates = [
                {name, router_device:name(APIDevice)},
                {dev_eui, router_device:dev_eui(APIDevice)},
                {app_eui, router_device:app_eui(APIDevice)},
                {devaddrs, DevAddrs},
                {metadata,
                    maps:merge(
                        lorawan_rxdelay:maybe_update(APIDevice, Device0),
                        router_device:metadata(APIDevice)
                    )},
                {is_active, IsActive}
            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            MultiBuyValue = maps:get(multi_buy, router_device:metadata(Device1), 1),
            ok = router_device_multibuy:max(router_device:id(Device1), MultiBuyValue),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            {noreply, State#state{device = Device1, is_active = IsActive}}
    end;
handle_cast(
    {get_queue_updates, ForwardPid, LabelID},
    #state{
        device = Device,
        queue_updates = QueueUpdates
    } = State0
) ->
    lager:debug("queue updates requested by ~p", [ForwardPid]),
    TRef = erlang:send_after(timer:minutes(10), self(), stop_queue_updates),
    case QueueUpdates of
        undefined ->
            ok;
        {_, _, OldTRef} ->
            erlang:cancel_timer(OldTRef)
    end,
    State1 = State0#state{queue_updates = {ForwardPid, LabelID, TRef}},
    ok = maybe_send_queue_update(Device, State1),
    {noreply, State1};
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
    ok = maybe_send_queue_update(Device1, State),
    {noreply, State#state{device = Device1}};
handle_cast(
    {queue_downlink,
        #downlink{port = Port, payload = Payload, channel = Channel, region = Region} = Downlink,
        Position},
    #state{
        db = DB,
        cf = CF,
        device = Device0,
        channels_worker = ChannelsWorker
    } = State
) ->
    case router_device:can_queue_payload(Payload, Region, Device0) of
        {false, Size, MaxSize, Datarate} ->
            Desc = io_lib:format(
                "Payload too big for DR~p max size is ~p (payload was ~p)",
                [Datarate, MaxSize, Size]
            ),
            ok = router_utils:event_downlink_dropped_payload_size_exceeded(
                erlang:list_to_binary(Desc),
                Port,
                Payload,
                Device0,
                router_channel:to_map(Channel)
            ),
            lager:debug(
                "failed to queue downlink message, too big (~p > ~p), using datarate DR~p",
                [Size, MaxSize, Datarate]
            ),
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
            ok = maybe_send_queue_update(Device1, State),
            lager:debug("queued downlink message of size ~p < ~p", [Size, MaxSize]),
            {noreply, State#state{device = Device1}};
        {error, _Reason} ->
            Desc = io_lib:format("Failed to queue downlink: ~p", [_Reason]),
            ok = router_utils:event_downlink_dropped_misc(
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
    {join, Packet0, PacketTime, HoldTime, PubKeyBin, Region, APIDevice, AppKey, Pid},
    #state{
        chain = Chain,
        db = DB,
        cf = CF,
        device = Device0,
        join_cache = Cache0,
        offer_cache = OfferCache,
        channels_worker = ChannelsWorker,
        last_dev_nonce = LastDevNonce
    } = State
) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet0),
    lager:debug("got join packet (~p) ~p", [PHash, lager:pr(Packet0, blockchain_helium_packet_v1)]),
    ok = router_metrics:packet_hold_time_observe(join, HoldTime),
    %% TODO we should really just call this once per join nonce
    %% and have a seperate function for getting the join nonce so we can check
    %% the cache
    case
        validate_join(
            Packet0,
            PubKeyBin,
            Region,
            APIDevice,
            AppKey,
            Device0,
            Chain,
            OfferCache
        )
    of
        {error, _Reason} ->
            lager:debug("failed to validate join ~p", [_Reason]),
            {noreply, State};
        {ok, Device1, DevNonce, JoinAcceptArgs, BalanceNonce} ->
            NewRSSI = blockchain_helium_packet_v1:signal_strength(Packet0),
            case maps:get(DevNonce, Cache0, undefined) of
                undefined when LastDevNonce == DevNonce ->
                    lager:debug("got a late join: ~p", [DevNonce]),
                    {noreply, State};
                undefined ->
                    lager:debug("got a first join: ~p", [DevNonce]),
                    JoinCache = #join_cache{
                        uuid = router_utils:uuid_v4(),
                        rssi = NewRSSI,
                        join_accept_args = JoinAcceptArgs,
                        packet_selected = {Packet0, PubKeyBin, Region, PacketTime, HoldTime},
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
                        Region,
                        BalanceNonce
                    ),
                    {noreply, State#state{
                        device = Device1,
                        join_cache = Cache1,
                        adr_engine = undefined,
                        downlink_handled_at = {-1, erlang:system_time(millisecond)},
                        fcnt = -1
                    }};
                #join_cache{
                    uuid = UUID,
                    rssi = OldRSSI,
                    packet_selected = {OldPacket, _, _, _, _} = OldSelected,
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
                        Region,
                        BalanceNonce
                    ),
                    case NewRSSI > OldRSSI of
                        false ->
                            lager:debug("got another join for ~p with worst RSSI ~p", [
                                DevNonce,
                                {NewRSSI, OldRSSI}
                            ]),
                            catch blockchain_state_channel_common:send_response(
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
                                        {Packet0, PubKeyBin, Region, PacketTime, HoldTime}
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
                            catch blockchain_state_channel_common:send_response(
                                OldPid,
                                blockchain_state_channel_response_v1:new(true)
                            ),
                            NewPackets = [OldSelected | lists:keydelete(OldPacket, 1, OldPackets)],
                            Cache1 = maps:put(
                                DevNonce,
                                JoinCache1#join_cache{
                                    rssi = NewRSSI,
                                    packet_selected =
                                        {Packet0, PubKeyBin, Region, PacketTime, HoldTime},
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
    {frame, _NwkSKey, Packet, PacketTime, HoldTime, PubKeyBin, _Region, _Pid},
    #state{
        device = Device,
        is_active = false
    } = State
) ->
    ok = router_metrics:packet_hold_time_observe(packet, HoldTime),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    ok = router_device_multibuy:max(PHash, 0),
    <<_MType:3, _MHDRRFU:3, _Major:2, _DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
        _FOptsLen:4, FCnt:16/little-unsigned-integer, _FOpts:_FOptsLen/binary,
        _PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),
    ok = router_utils:event_uplink_dropped_device_inactive(
        PacketTime,
        FCnt,
        Device,
        PubKeyBin
    ),
    {noreply, State};
handle_cast(
    {frame, UsedNwkSKey, Packet0, PacketTime, HoldTime, PubKeyBin, Region, Pid},
    #state{
        chain = Blockchain,
        frame_timeout = DefaultFrameTimeout,
        device = Device0,
        frame_cache = Cache0,
        offer_cache = OfferCache,
        downlink_handled_at = DownlinkHandledAt,
        fcnt = LastSeenFCnt,
        channels_worker = ChannelsWorker,
        last_dev_nonce = LastDevNonce,
        discovery = Disco,
        adr_engine = ADREngine
    } = State
) ->
    ok = router_metrics:packet_hold_time_observe(packet, HoldTime),
    MetricPacketType =
        case Disco of
            true -> discovery_packet;
            false -> packet
        end,
    PHash = blockchain_helium_packet_v1:packet_hash(Packet0),
    router_device_routing:cache_device_for_hash(PHash, Device0),
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
                {devaddr, DevAddr0} = blockchain_helium_packet_v1:routing_info(Packet0),
                DevAddr1 = lorawan_utils:reverse(<<DevAddr0:32/integer-unsigned-big>>),
                DeviceUpdates = [
                    {keys,
                        lists:filter(
                            fun({NwkSKey, _}) -> NwkSKey == UsedNwkSKey end,
                            router_device:keys(Device0)
                        )},
                    {dev_nonces, DevNonces},
                    {devaddrs, [DevAddr1]}
                ],
                D1 = router_device:update(DeviceUpdates, Device0),
                lager:debug(
                    "we got our first uplink after join dev nonces=~p keys=~p, DevAddrs=~p", [
                        router_device:dev_nonces(D1),
                        router_device:keys(D1),
                        router_device:devaddrs(D1)
                    ]
                ),
                D1
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
            Cache0,
            OfferCache
        )
    of
        {error, {not_enough_dc, _Reason, Device2}} ->
            ok = router_utils:event_uplink_dropped_not_enough_dc(
                PacketTime,
                router_device:fcnt(Device2),
                Device2,
                PubKeyBin
            ),
            lager:debug("did not have enough dc (~p) to send data", [_Reason]),
            ok = router_device_multibuy:max(PHash, 0),
            ok = router_metrics:packet_trip_observe_end(
                PHash,
                PubKeyBin,
                erlang:system_time(millisecond),
                MetricPacketType,
                false
            ),
            {noreply, State#state{device = Device2}};
        {error, Reason} ->
            lager:debug("packet not validated: ~p", [Reason]),
            case Reason of
                late_packet ->
                    ok = router_utils:event_uplink_dropped_late_packet(
                        PacketTime,
                        HoldTime,
                        router_device:fcnt(Device1),
                        Device1,
                        PubKeyBin
                    );
                _ ->
                    ok = router_utils:event_uplink_dropped_invalid_packet(
                        Reason,
                        PacketTime,
                        router_device:fcnt(Device1),
                        Device1,
                        Blockchain,
                        PubKeyBin,
                        Packet0,
                        Region
                    )
            end,
            ok = router_device_multibuy:max(PHash, 0),
            ok = router_metrics:packet_trip_observe_end(
                PHash,
                PubKeyBin,
                erlang:system_time(millisecond),
                MetricPacketType,
                false
            ),
            {noreply, State};
        {ok, Frame, Device2, SendToChannels, BalanceNonce, Replay} ->
            RSSI0 = blockchain_helium_packet_v1:signal_strength(Packet0),
            FCnt = router_device:fcnt(Device2),
            NewFrameCache = #frame_cache{
                uuid = router_utils:uuid_v4(),
                rssi = RSSI0,
                packet = Packet0,
                pubkey_bin = PubKeyBin,
                frame = Frame,
                pid = Pid,
                region = Region,
                pubkey_bins = [PubKeyBin]
            },
            {UUID, State1} =
                case maps:get(FCnt, Cache0, undefined) of
                    undefined ->
                        ok = router_utils:event_uplink(
                            NewFrameCache#frame_cache.uuid,
                            PacketTime,
                            HoldTime,
                            Frame,
                            Device2,
                            Blockchain,
                            PubKeyBin,
                            Packet0,
                            Region,
                            BalanceNonce
                        ),
                        %% REVIEW: ADR adjustments are only considered for the
                        %% first received frame. This frame could be replaced by
                        %% a later frame with better signal that then causes an
                        %% adjustment downlink, but it will miss the downlink
                        %% window. Could argue that ADR should not be happening
                        %% if different frames cause different ADR results.
                        {_, ADRAdjustment} = maybe_track_adr_packet(
                            Device2,
                            ADREngine,
                            NewFrameCache
                        ),
                        Timeout = calculate_packet_timeout(
                            Device2,
                            Frame,
                            PacketTime,
                            ADRAdjustment,
                            DefaultFrameTimeout
                        ),
                        lager:debug("setting frame timeout [fcnt: ~p] [timeout: ~p]", [
                            FCnt,
                            Timeout
                        ]),
                        _ = erlang:send_after(
                            Timeout,
                            self(),
                            {frame_timeout, FCnt, PacketTime, BalanceNonce}
                        ),
                        {NewFrameCache#frame_cache.uuid, State#state{
                            device = Device2,
                            frame_cache = maps:put(FCnt, NewFrameCache, Cache0)
                        }};
                    #frame_cache{
                        uuid = OldUUID,
                        rssi = OldRSSI,
                        pid = OldPid,
                        count = OldCount,
                        pubkey_bins = PubkeyBins
                    } = OldFrameCache ->
                        case lists:member(PubKeyBin, PubkeyBins) of
                            true ->
                                ok;
                            false ->
                                ok = router_utils:event_uplink(
                                    OldUUID,
                                    PacketTime,
                                    HoldTime,
                                    Frame,
                                    Device2,
                                    Blockchain,
                                    PubKeyBin,
                                    Packet0,
                                    Region,
                                    BalanceNonce
                                )
                        end,
                        case RSSI0 > OldRSSI of
                            false ->
                                catch blockchain_state_channel_common:send_response(
                                    Pid,
                                    blockchain_state_channel_response_v1:new(true)
                                ),
                                ok = router_metrics:packet_trip_observe_end(
                                    PHash,
                                    PubKeyBin,
                                    erlang:system_time(millisecond),
                                    MetricPacketType,
                                    false
                                ),
                                {OldUUID, State#state{
                                    device = Device2,
                                    frame_cache = maps:put(
                                        FCnt,
                                        OldFrameCache#frame_cache{
                                            count = OldCount + 1,
                                            pubkey_bins = [PubKeyBin | PubkeyBins]
                                        },
                                        Cache0
                                    )
                                }};
                            true ->
                                catch blockchain_state_channel_common:send_response(
                                    OldPid,
                                    blockchain_state_channel_response_v1:new(true)
                                ),
                                {OldUUID, State#state{
                                    device = Device2,
                                    frame_cache = maps:put(
                                        FCnt,
                                        NewFrameCache#frame_cache{
                                            uuid = OldUUID,
                                            count = OldCount + 1,
                                            pubkey_bins = [PubKeyBin | PubkeyBins]
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
                        PacketTime,
                        HoldTime,
                        Replay
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

handle_info(stop_queue_updates, State) ->
    lager:debug("stopped queue updates"),
    {noreply, State#state{queue_updates = undefined}};
handle_info(
    {join_timeout, DevNonce},
    #state{
        chain = Blockchain,
        channels_worker = ChannelsWorker,
        device = Device,
        join_cache = JoinCache
    } = State
) ->
    Join =
        #join_cache{
            join_accept_args = JoinAcceptArgs,
            packet_selected = PacketSelected,
            packets = Packets,
            device = Device0,
            pid = Pid
        } = maps:get(DevNonce, JoinCache),
    {Packet, PubKeyBin, Region, _PacketTime, _HoldTime} = PacketSelected,
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
    Rx2Window =
        try join2_from_packet(Region, Packet) of
            V -> V
        catch
            _:_ ->
                lager:warning("could not get join_rx2 [region: ~p]", [Region]),
                undefined
        end,
    Metadata = lorawan_rxdelay:adjust_on_join(Device),
    Device1 = router_device:metadata(Metadata, Device),
    DownlinkPacket = blockchain_helium_packet_v1:new_downlink(
        craft_join_reply(Device1, JoinAcceptArgs),
        lorawan_mac_region:downlink_signal_strength(Region, TxFreq),
        TxTime,
        TxFreq,
        binary_to_list(TxDataRate),
        Rx2Window
    ),
    lager:debug("sending join response ~p", [DownlinkPacket]),
    catch blockchain_state_channel_common:send_response(
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
    ok = router_device_channels_worker:handle_join(ChannelsWorker, Join),
    _ = erlang:spawn(router_utils, maybe_update_trace, [router_device:id(Device0)]),
    ok = router_utils:event_join_accept(Device0, Blockchain, PubKeyBin, DownlinkPacket, Region),
    {noreply, State#state{
        last_dev_nonce = DevNonce,
        join_cache = maps:remove(DevNonce, JoinCache)
    }};
handle_info(
    {frame_timeout, FCnt, PacketTime, BalanceNonce},
    #state{
        chain = Blockchain,
        db = DB,
        cf = CF,
        frame_timeout = DefaultFrameTimeout,
        device = Device0,
        channels_worker = ChannelsWorker,
        frame_cache = Cache0,
        adr_engine = ADREngine0,
        discovery = Disco
    } = State
) ->
    MetricPacketType =
        case Disco of
            true -> discovery_packet;
            false -> packet
        end,
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
    ok = router_device_multibuy:delete(blockchain_helium_packet_v1:packet_hash(Packet)),
    ok = router_device_channels_worker:frame_timeout(ChannelsWorker, UUID, BalanceNonce),
    lager:debug("frame timeout for ~p / device ~p", [FCnt, lager:pr(Device0, router_device)]),
    {ADREngine1, ADRAdjustment} = maybe_track_adr_packet(Device0, ADREngine0, FrameCache),
    DeviceID = router_device:id(Device0),
    %% NOTE: Disco-mode has a special frame_timeout well above what we're trying
    %% to achieve here. We ignore those packets in metrics so they don't skew
    %% our alerting.
    IgnoreMetrics = DefaultFrameTimeout > router_utils:frame_timeout(),
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
            lager:debug("sending frame response with no downlink"),
            catch blockchain_state_channel_common:send_response(
                Pid,
                blockchain_state_channel_response_v1:new(true)
            ),
            router_device_routing:clear_replay(DeviceID),
            ok = router_metrics:packet_trip_observe_end(
                blockchain_helium_packet_v1:packet_hash(Packet),
                PubKeyBin,
                erlang:system_time(millisecond),
                MetricPacketType,
                false,
                IgnoreMetrics
            ),
            {noreply, State#state{
                device = Device1,
                last_dev_nonce = undefined,
                adr_engine = ADREngine1,
                frame_cache = Cache1,
                fcnt = FCnt
            }};
        {send, Device1, DownlinkPacket, {ACK, ConfirmedDown, Port, ChannelMap, FOpts}} ->
            IsDownlinkAck =
                case ACK of
                    1 -> true;
                    0 -> false
                end,
            ok = router_utils:event_downlink(
                IsDownlinkAck,
                ConfirmedDown,
                Port,
                Device0,
                ChannelMap,
                Blockchain,
                PubKeyBin,
                DownlinkPacket,
                Region,
                FOpts
            ),
            ok = maybe_send_queue_update(Device1, State),
            case router_utils:mtype_to_ack(Frame#frame.mtype) of
                1 -> router_device_routing:allow_replay(Packet, DeviceID, PacketTime);
                _ -> router_device_routing:clear_replay(DeviceID)
            end,
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            lager:debug("sending downlink for fcnt: ~p, ~p", [FCnt, DownlinkPacket]),
            catch blockchain_state_channel_common:send_response(
                Pid,
                blockchain_state_channel_response_v1:new(true, DownlinkPacket)
            ),
            ok = router_metrics:packet_trip_observe_end(
                blockchain_helium_packet_v1:packet_hash(Packet),
                PubKeyBin,
                erlang:system_time(millisecond),
                MetricPacketType,
                true,
                IgnoreMetrics
            ),
            {noreply, State#state{
                device = Device1,
                last_dev_nonce = undefined,
                adr_engine = ADREngine1,
                frame_cache = Cache1,
                downlink_handled_at = {FCnt, erlang:system_time(millisecond)},
                fcnt = FCnt
            }};
        noop ->
            catch blockchain_state_channel_common:send_response(
                Pid,
                blockchain_state_channel_response_v1:new(true)
            ),
            router_device_routing:clear_replay(DeviceID),
            ok = router_metrics:packet_trip_observe_end(
                blockchain_helium_packet_v1:packet_hash(Packet),
                PubKeyBin,
                erlang:system_time(millisecond),
                MetricPacketType,
                false,
                IgnoreMetrics
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

-spec downlink_to_map(#downlink{}) -> map().
downlink_to_map(Downlink) ->
    #{
        confirmed => Downlink#downlink.confirmed,
        port => Downlink#downlink.port,
        payload => base64:encode(Downlink#downlink.payload),
        channel => router_channel:to_map(Downlink#downlink.channel)
    }.

-spec maybe_send_queue_update(router_device:device(), #state{}) -> ok.
maybe_send_queue_update(_Device, #state{queue_updates = undefined}) ->
    ok;
maybe_send_queue_update(Device, #state{queue_updates = {ForwardPid, LabelID, _}}) ->
    ForwardPid !
        {?MODULE, queue_update, LabelID, router_device:id(Device), [
            downlink_to_map(D)
         || D <- router_device:queue(Device)
        ]},
    ok.

-spec validate_join(
    Packet :: blockchain_helium_packet_v1:packet(),
    PubKeyBin :: libp2p_crypto:pubkey_to_bin(),
    Region :: atom(),
    APIDevice :: router_device:device(),
    AppKey :: binary(),
    Device :: router_device:device(),
    Blockchain :: blockchain:blockchain(),
    OfferCache :: map()
) ->
    {ok, router_device:device(), binary(), #join_accept_args{}, {
        Balance :: non_neg_integer(), Nonce :: non_neg_integer()
    }}
    | {error, any()}.
validate_join(
    #packet_pb{
        payload =
            <<MType:3, _MHDRRFU:3, _Major:2, _AppEUI0:8/binary, _DevEUI0:8/binary,
                DevNonce:2/binary, _MIC:4/binary>> = Payload
    } = Packet,
    PubKeyBin,
    Region,
    APIDevice,
    AppKey,
    Device,
    Blockchain,
    OfferCache
) when MType == ?JOIN_REQ ->
    case lists:member(DevNonce, router_device:dev_nonces(Device)) of
        true ->
            {error, bad_nonce};
        false ->
            PayloadSize = erlang:byte_size(Payload),
            PHash = blockchain_helium_packet_v1:packet_hash(Packet),
            case maybe_charge(Device, PayloadSize, Blockchain, PubKeyBin, PHash, OfferCache) of
                {error, _} = Error ->
                    Error;
                {ok, Balance, Nonce} ->
                    {ok, UpdatedDevice, JoinAcceptArgs} = handle_join(
                        Packet,
                        PubKeyBin,
                        Region,
                        APIDevice,
                        AppKey,
                        Device
                    ),
                    {ok, UpdatedDevice, DevNonce, JoinAcceptArgs, {Balance, Nonce}}
            end
    end;
validate_join(
    _Packet,
    _PubKeyBin,
    _Region,
    _APIDevice,
    _AppKey,
    _Device,
    _Blockchain,
    _OfferCache
) ->
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
    router_device:device(),
    binary(),
    router_device:device()
) -> {ok, router_device:device(), #join_accept_args{}}.
handle_join(
    #packet_pb{
        payload =
            <<_MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, DevNonce:2/binary,
                _MIC:4/binary>>
    } = Packet,
    PubKeyBin,
    HotspotRegion,
    APIDevice,
    AppKey,
    Device0
) ->
    AppNonce = crypto:strong_rand_bytes(3),
    NwkSKey = crypto:crypto_one_time(
        aes_128_ecb,
        AppKey,
        lorawan_utils:padded(16, <<16#01, AppNonce/binary, ?NET_ID/binary, DevNonce/binary>>),
        true
    ),
    AppSKey = crypto:crypto_one_time(
        aes_128_ecb,
        AppKey,
        lorawan_utils:padded(16, <<16#02, AppNonce/binary, ?NET_ID/binary, DevNonce/binary>>),
        true
    ),
    {ok, DevAddr} = router_device_devaddr:allocate(Device0, PubKeyBin),
    DeviceName = router_device:name(APIDevice),
    %% don't set the join nonce here yet as we have not chosen the best join request yet
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    {Region, DR} = packet_datarate(Device0, Packet, HotspotRegion),
    DeviceUpdates = [
        {name, DeviceName},
        {dev_eui, DevEUI},
        {app_eui, AppEUI},
        {keys, [{NwkSKey, AppSKey} | router_device:keys(Device0)]},
        {devaddrs, [DevAddr | router_device:devaddrs(Device0)]},
        {fcntdown, 0},
        %% only do channel correction for 915 right now
        {channel_correction, Region /= 'US915'},
        {location, PubKeyBin},
        {metadata,
            lorawan_rxdelay:bootstrap(
                maps:merge(
                    router_device:metadata(Device0),
                    router_device:metadata(APIDevice)
                )
            )},
        {last_known_datarate, DR},
        {region, Region}
    ],
    Device1 = router_device:update(DeviceUpdates, Device0),
    lager:debug(
        "DevEUI ~s with AppEUI ~s tried to join with nonce ~p via ~s",
        [
            lorawan_utils:binary_to_hex(DevEUI),
            lorawan_utils:binary_to_hex(AppEUI),
            DevNonce,
            blockchain_utils:addr2name(PubKeyBin)
        ]
    ),
    {ok, Device1, #join_accept_args{
        region = Region,
        app_nonce = AppNonce,
        dev_addr = DevAddr,
        app_key = AppKey
    }}.

-spec craft_join_reply(router_device:device(), #join_accept_args{}) -> binary().
craft_join_reply(
    Device,
    #join_accept_args{region = Region, app_nonce = AppNonce, dev_addr = DevAddr, app_key = AppKey}
) ->
    DR = lorawan_mac_region:window2_dr(lorawan_mac_region:top_level_region(Region)),
    DLSettings = <<0:1, 0:3, DR:4/integer-unsigned>>,
    ReplyHdr = <<?JOIN_ACCEPT:3, 0:3, 0:2>>,
    Metadata = router_device:metadata(Device),
    CFList =
        case maps:get(cf_list_enabled, Metadata, true) of
            false -> <<>>;
            true -> lorawan_mac_region:mk_join_accept_cf_list(Region)
        end,
    RxDelaySeconds =
        case lorawan_rxdelay:get(Metadata, default) of
            default -> <<?RX_DELAY:8/integer-unsigned>>;
            Seconds -> <<0:4, Seconds:4/integer-unsigned>>
        end,
    ReplyPayload =
        <<AppNonce/binary, ?NET_ID/binary, DevAddr/binary, DLSettings/binary, RxDelaySeconds/binary,
            CFList/binary>>,
    ReplyMIC = crypto:macN(cmac, aes_128_cbc, AppKey, <<ReplyHdr/binary, ReplyPayload/binary>>, 4),
    EncryptedReply = crypto:crypto_one_time(
        aes_128_ecb,
        AppKey,
        lorawan_utils:padded(16, <<ReplyPayload/binary, ReplyMIC/binary>>),
        false
    ),
    <<ReplyHdr/binary, EncryptedReply/binary>>.

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
    {LastSeenFCnt :: non_neg_integer(), DownlinkHanldedAt :: {integer(), integer()}},
    FrameCache :: #{integer() => #frame_cache{}},
    OfferCache :: map()
) ->
    {error, any()}
    | {ok, #frame{}, router_device:device(), SendToChannel :: boolean(),
        {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}, Replay :: boolean()}.
validate_frame(
    Packet,
    PacketTime,
    PubKeyBin,
    Region,
    Device0,
    Blockchain,
    {LastSeenFCnt, {DownlinkHandledAtFCnt, DownlinkHandledAtTime}},
    FrameCache,
    OfferCache
) ->
    <<MType:3, _MHDRRFU:3, _Major:2, _DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
        _FOptsLen:4, FCnt:16/little-unsigned-integer, _FOpts:_FOptsLen/binary,
        _PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),
    FrameAck = router_utils:mtype_to_ack(MType),
    Window = PacketTime - DownlinkHandledAtTime,
    case maps:get(FCnt, FrameCache, undefined) of
        #frame_cache{} ->
            validate_frame_(Packet, PubKeyBin, Region, Device0, OfferCache, Blockchain, false);
        undefined when FrameAck == 0 andalso FCnt =< LastSeenFCnt ->
            lager:debug("we got a late unconfirmed up packet for ~p: lastSeendFCnt: ~p", [
                FCnt,
                LastSeenFCnt
            ]),
            {error, late_packet};
        undefined when
            FrameAck == 1 andalso FCnt == DownlinkHandledAtFCnt andalso Window < ?RX_MAX_WINDOW
        ->
            lager:debug(
                "we got a late confirmed up packet for ~p: DownlinkHandledAt: ~p within window ~p",
                [FCnt, DownlinkHandledAtFCnt, Window]
            ),
            {error, late_packet};
        undefined when
            FrameAck == 1 andalso FCnt == DownlinkHandledAtFCnt andalso Window >= ?RX_MAX_WINDOW
        ->
            lager:debug(
                "we got a replay confirmed up packet for ~p: DownlinkHandledAt: ~p outside window ~p",
                [FCnt, DownlinkHandledAtFCnt, Window]
            ),
            validate_frame_(Packet, PubKeyBin, Region, Device0, OfferCache, Blockchain, true);
        undefined ->
            validate_frame_(Packet, PubKeyBin, Region, Device0, OfferCache, Blockchain, false)
    end.

-spec validate_frame_(
    Packet :: blockchain_helium_packet_v1:packet(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Device :: router_device:device(),
    OfferCache :: map(),
    Blockchain :: blockchain:blockchain(),
    Replay :: boolean()
) ->
    {ok, #frame{}, router_device:device(), SendToChannel :: boolean(),
        {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}, Replay :: boolean()}
    | {error, any()}.
validate_frame_(Packet, PubKeyBin, HotspotRegion, Device0, OfferCache, Blockchain, Replay) ->
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
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    case maybe_charge(Device0, PayloadSize, Blockchain, PubKeyBin, PHash, OfferCache) of
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
                    {Region, DR} = packet_datarate(Device0, Packet, HotspotRegion),
                    BaseDeviceUpdates = [
                        {fcnt, FCnt},
                        {location, PubKeyBin},
                        {region, Region},
                        {last_known_datarate, DR}
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
                    {ok, Frame, Device1, false, {Balance, Nonce}, Replay};
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
                    {Region, DR} = packet_datarate(Device0, Packet, HotspotRegion),
                    BaseDeviceUpdates = [
                        {fcnt, FCnt},
                        {region, Region},
                        {last_known_datarate, DR}
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
                    {ok, Frame, Device1, true, {Balance, Nonce}, Replay}
            end
    end.

-spec maybe_charge(
    Device :: router_device:device(),
    PayloadSize :: non_neg_integer(),
    Blockchain :: blockchain:blockchain(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    PHash :: binary(),
    OfferCache :: map()
) -> {ok, non_neg_integer(), non_neg_integer()} | {error, any()}.
maybe_charge(Device, PayloadSize, Blockchain, PubKeyBin, PHash, OfferCache) ->
    case maps:get({PubKeyBin, PHash}, OfferCache, undefined) of
        undefined ->
            case charge_when_no_offer() of
                false ->
                    Metadata = router_device:metadata(Device),
                    {Balance, Nonce} =
                        case maps:get(organization_id, Metadata, undefined) of
                            undefined ->
                                {0, 0};
                            OrgID ->
                                router_console_dc_tracker:current_balance(OrgID)
                        end,
                    {ok, Balance, Nonce};
                true ->
                    router_console_dc_tracker:charge(Device, PayloadSize, Blockchain)
            end;
        _ ->
            router_console_dc_tracker:charge(Device, PayloadSize, Blockchain)
    end.

-spec charge_when_no_offer() -> boolean().
charge_when_no_offer() ->
    case application:get_env(router, charge_when_no_offer, true) of
        "true" -> true;
        true -> true;
        _ -> false
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
    [#downlink{} | any()]
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
            {RxDelay, Metadata, FOpts2} =
                lorawan_rxdelay:adjust(Device0, Frame#frame.fopts, FOpts1),
            Reply = frame_to_packet_payload(
                #frame{
                    mtype = MType,
                    devaddr = Frame#frame.devaddr,
                    fcnt = FCntDown,
                    fopts = FOpts2,
                    fport = Port,
                    adr = Frame#frame.adr,
                    ack = ACK,
                    data = <<>>
                },
                Device0
            ),
            #txq{
                time = TxTime,
                datr = TxDataRate,
                freq = TxFreq
            } = lorawan_mac_region:rx1_or_rx2_window(
                Region,
                RxDelay,
                0,
                packet_to_rxq(Packet0)
            ),
            Rx2Window =
                try rx2_from_packet(Region, Packet0, RxDelay) of
                    V -> V
                catch
                    _:_ ->
                        lager:warning("could not get rx2 [region: ~p]", [Region]),
                        undefined
                end,
            Packet1 = blockchain_helium_packet_v1:new_downlink(
                Reply,
                lorawan_mac_region:downlink_signal_strength(Region, TxFreq),
                adjust_rx_time(TxTime),
                TxFreq,
                binary_to_list(TxDataRate),
                Rx2Window
            ),
            DeviceUpdates = [
                {channel_correction, ChannelsCorrected},
                {fcntdown, (FCntDown + 1)},
                {metadata, Metadata}
            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            EventTuple =
                {ACK, ConfirmedDown, Port, #{id => undefined, name => <<"router">>}, FOpts2},
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
    {RxDelay, Metadata, FOpts2} =
        lorawan_rxdelay:adjust(Device0, Frame#frame.fopts, FOpts1),
    Reply = frame_to_packet_payload(
        #frame{
            mtype = MType,
            devaddr = Frame#frame.devaddr,
            fcnt = FCntDown,
            fopts = FOpts2,
            fport = Port,
            adr = Frame#frame.adr,
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
    } = lorawan_mac_region:rx1_or_rx2_window(
        Region,
        RxDelay,
        0,
        packet_to_rxq(Packet0)
    ),
    Rx2Window =
        try rx2_from_packet(Region, Packet0, RxDelay) of
            V -> V
        catch
            _:_ ->
                lager:warning("could not get rx2 [region: ~p]", [Region]),
                undefined
        end,
    Packet1 = blockchain_helium_packet_v1:new_downlink(
        Reply,
        lorawan_mac_region:downlink_signal_strength(Region, TxFreq),
        adjust_rx_time(TxTime),
        TxFreq,
        binary_to_list(TxDataRate),
        Rx2Window
    ),
    EventTuple = {ACK, ConfirmedDown, Port, router_channel:to_map(Channel), FOpts2},
    DeviceUpdateMetadata = {metadata, Metadata},
    case ConfirmedDown of
        true ->
            Device1 = router_device:channel_correction(ChannelsCorrected, Device0),
            Device2 = router_device:update([DeviceUpdateMetadata], Device1),
            {send, Device2, Packet1, EventTuple};
        false ->
            DeviceUpdates = [
                DeviceUpdateMetadata,
                {queue, T},
                {channel_correction, ChannelsCorrected},
                {fcntdown, (FCntDown + 1)}
            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            {send, Device1, Packet1, EventTuple}
    end;
%% This is due to some old downlink being left in the queue
handle_frame_timeout(
    Packet0,
    Region,
    Device0,
    Frame,
    Count,
    ADRAdjustment,
    [
        UknownDonlinkFormat
        | T
    ]
) ->
    lager:info("we skipped an old downlink ~p", [UknownDonlinkFormat]),
    handle_frame_timeout(
        Packet0,
        Region,
        Device0,
        Frame,
        Count,
        ADRAdjustment,
        T
    ).

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
                case Region of
                    'US915' ->
                        lorawan_mac_region:set_channels(
                            Region,
                            {0, <<"NoChange">>, [Channels]},
                            []
                        );
                    'AU915' ->
                        lorawan_mac_region:set_channels(
                            Region,
                            {0, <<"NoChange">>, [Channels]},
                            []
                        );
                    _ ->
                        lorawan_mac_region:set_channels(
                            Region,
                            {0, erlang:list_to_binary(DataRate), [Channels]},
                            []
                        )
                end;
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
        <<
            (Frame#frame.mtype):3,
            0:3,
            0:2,
            (Frame#frame.devaddr)/binary,
            (Frame#frame.adr):1,
            0:1,
            (Frame#frame.ack):1,
            (Frame#frame.fpending):1,
            FOptsLen:4,
            (Frame#frame.fcnt):16/integer-unsigned-little,
            FOpts:FOptsLen/binary
        >>,
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
    MIC = crypto:macN(
        cmac,
        aes_128_cbc,
        NwkSKey,
        <<
            (router_utils:b0(1, Frame#frame.devaddr, Frame#frame.fcnt, byte_size(Msg)))/binary,
            Msg/binary
        >>,
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

-spec rx2_from_packet(atom(), blockchain_helium_packet_v1:packet(), number()) ->
    blockchain_helium_packet_v1:window().
rx2_from_packet(Region, Packet, RxDelay) ->
    Rxq = packet_to_rxq(Packet),
    #txq{
        time = TxTime,
        datr = TxDataRate,
        freq = TxFreq
    } = lorawan_mac_region:rx2_window(Region, RxDelay, Rxq),
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
get_device(DB, CF, DeviceID) ->
    Device0 =
        case router_device:get_by_id(DB, CF, DeviceID) of
            {ok, D} -> D;
            _ -> router_device:new(DeviceID)
        end,
    Device1 =
        case router_console_api:get_device(DeviceID) of
            {error, not_found} ->
                lager:info("device not found"),
                Device0;
            {error, _Reason} ->
                lager:error("failed to get device ~p", [_Reason]),
                Device0;
            {ok, APIDevice} ->
                lager:info("got device: ~p", [APIDevice]),

                IsActive = router_device:is_active(APIDevice),
                DeviceUpdates = [
                    {name, router_device:name(APIDevice)},
                    {dev_eui, router_device:dev_eui(APIDevice)},
                    {app_eui, router_device:app_eui(APIDevice)},
                    {metadata,
                        maps:merge(
                            lorawan_rxdelay:maybe_update(APIDevice, Device0),
                            router_device:metadata(APIDevice)
                        )},
                    {is_active, IsActive}
                ],
                router_device:update(DeviceUpdates, Device0)
        end,
    MultiBuyValue = maps:get(multi_buy, router_device:metadata(Device1), 1),
    ok = router_device_multibuy:max(router_device:id(Device1), MultiBuyValue),
    Device1.

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
    #frame_cache{
        rssi = RSSI,
        packet = Packet,
        pubkey_bin = PubKeyBin,
        frame = Frame,
        region = Region
    } = FrameCache,
    #frame{fopts = FOpts, adr = ADRBit, adrackreq = ADRAckReqBit} = Frame,
    ADRAllowed = maps:get(adr_allowed, Metadata, false),
    case {ADRAllowed, ADRAckReqBit == 1} of
        %% ADR is disallowed for this device AND this is packet does
        %% not have ADRAckReq bit set. Do nothing.
        {false, false} ->
            {undefined, hold};
        %% ADR is disallowed for this device, but it set
        %% ADRAckReq. We'll downlink an ADRRequest with packet's
        %% datarate and default power. Ideally, we'd request the same
        %% power this packet transmitted at, but that value is
        %% unknowable.
        {false, true} ->
            DataRateStr = blockchain_helium_packet_v1:datarate(Packet),
            DataRateIdx = lorawan_mac_region:datar_to_dr(Region, DataRateStr),
            TxPowerIdx = 0,
            {undefined, {DataRateIdx, TxPowerIdx}};
        %% ADR is allowed for this device so no special handling for
        %% this packet.
        {true, _} ->
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
            DataRateStr = blockchain_helium_packet_v1:datarate(Packet),
            DataRatePair = lorawan_utils:parse_datarate(DataRateStr),
            AdrPacket = #adr_packet{
                packet_hash = blockchain_helium_packet_v1:packet_hash(Packet),
                wants_adr = ADRBit == 1,
                wants_adr_ack = ADRAckReqBit == 1,
                datarate_config = DataRatePair,
                snr = blockchain_helium_packet_v1:snr(Packet),
                rssi = RSSI,
                hotspot = PubKeyBin
            },
            lorawan_adr:track_packet(
                ADREngine2,
                AdrPacket
            )
    end.

-spec packet_datarate(
    Device :: router_device:device() | binary(),
    Packet :: blockchain_helium_packet_v1:packet() | atom(),
    Region :: atom()
) -> {atom(), integer()}.
packet_datarate(Device, Packet, Region) ->
    Datarate = erlang:list_to_binary(
        blockchain_helium_packet_v1:datarate(Packet)
    ),
    DeviceRegion = router_device:region(Device),
    packet_datarate(Datarate, {Region, DeviceRegion}).

-spec packet_datarate(
    Datarate :: binary(),
    {atom(), atom()}
) -> {atom(), integer()}.
packet_datarate(Datarate, {Region, Region}) ->
    {Region, lorawan_mac_region:datar_to_dr(Region, Datarate)};
packet_datarate(Datarate, {Region, DeviceRegion}) ->
    try lorawan_mac_region:datar_to_dr(Region, Datarate) of
        DR ->
            {Region, DR}
    catch
        _E:_R ->
            lager:info("failed to get DR for ~p ~p, reverting to device's region (~p)", [
                Region,
                Datarate,
                DeviceRegion
            ]),
            {DeviceRegion, lorawan_mac_region:datar_to_dr(DeviceRegion, Datarate)}
    end.

-spec calculate_packet_timeout(
    Device :: rourter_device:device(),
    Frame :: #frame{},
    PacketTime :: non_neg_integer(),
    ADRAdjustment :: lorawan_adr:adjustment(),
    DefaultFrameTimeout :: non_neg_integer()
) -> non_neg_integer().
calculate_packet_timeout(Device, Frame, PacketTime, ADRAdjustment, DefaultFrameTimeout) ->
    case
        ADRAdjustment /= hold orelse
            maybe_will_downlink(Device, Frame) orelse
            application:get_env(router, testing, false)
    of
        false ->
            ?DEFAULT_FRAME_TIMEOUT;
        true ->
            max(
                0,
                DefaultFrameTimeout -
                    (erlang:system_time(millisecond) - PacketTime)
            )
    end.

-spec maybe_will_downlink(rourter_device:device(), #frame{}) -> boolean().
maybe_will_downlink(Device, #frame{mtype = MType, adrackreq = ADRAckReqBit}) ->
    DeviceQueue = router_device:queue(Device),
    ACK = router_utils:mtype_to_ack(MType),
    Metadata = router_device:metadata(Device),
    ADRAllowed = maps:get(adr_allowed, Metadata, false),
    ChannelCorrection = router_device:channel_correction(Device),
    ADR = ADRAllowed andalso ADRAckReqBit == 1,
    DeviceQueue =/= [] orelse ACK == 1 orelse ADR orelse ChannelCorrection == false.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

channel_record_update_test() ->
    %% This test exists to make sure upgrades are considered if anything needs
    %% to touch the #downlink{} record definition.
    ?assertMatch(
        {
            downlink,
            _Confirmed,
            _Port,
            _Payload,
            _Channel,
            _Region
        },
        #downlink{}
    ).
-endif.
