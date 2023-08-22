%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_worker).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("erlang_lorawan/src/lora_adr.hrl").
-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("lorawan_db.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_offer/2,
    accept_uplink/6,
    handle_join/9,
    handle_frame/9,
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
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(INIT_ASYNC, init_async).
-define(INIT_BLOKCHAIN, init_blockchain).
-define(BACKOFF_MAX, timer:minutes(5)).
%% biggest unsigned number in 23 bits
-define(BITS_23, 8388607).

-define(NET_ID, <<"He2">>).

%% This is only used when NO downlink must be sent to the device.
%% 2 seconds was picked as it is the RX_MAX_WINDOW
-define(DEFAULT_FRAME_TIMEOUT, timer:seconds(2)).

-define(RX_MAX_WINDOW, 2000).

-record(state, {
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle(),
    frame_timeout :: non_neg_integer(),
    device :: router_device:device() | undefined,
    downlink_handled_at = {undefined, erlang:system_time(millisecond)} :: {
        undefined | non_neg_integer(), integer()
    },
    queue_updates :: undefined | {pid(), undefined | binary(), reference()},
    fcnt = undefined :: undefined | non_neg_integer(),
    oui :: undefined | non_neg_integer(),
    channels_worker :: pid() | undefined,
    last_dev_nonce = undefined :: binary() | undefined,
    join_cache = #{} :: #{integer() => #join_cache{}},
    frame_cache = #{} :: #{integer() => #frame_cache{}},
    offer_cache = #{} :: #{{libp2p_crypto:pubkey_bin(), binary()} => non_neg_integer()},
    adr_engine :: undefined | lora_adr:handle(),
    is_active = true :: boolean() | undefined,
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
    PacketFCnt :: non_neg_integer(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    HoldTime :: non_neg_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> boolean().
accept_uplink(WorkerPid, PacketFCnt, Packet, PacketTime, HoldTime, PubKeyBin) ->
    gen_server:call(
        WorkerPid, {accept_uplink, PacketFCnt, Packet, PacketTime, HoldTime, PubKeyBin}
    ).

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
    PacketFCnt :: pos_integer(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: pos_integer(),
    _HoldTime :: pos_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Pid :: pid()
) -> ok.
handle_frame(WorkerPid, NwkSKey, PacketFCnt, Packet, PacketTime, HoldTime, PubKeyBin, Region, Pid) ->
    gen_server:cast(
        WorkerPid,
        {frame, NwkSKey, PacketFCnt, Packet, PacketTime, HoldTime, PubKeyBin, Region, Pid}
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
    DefaultFrameTimeout = maps:get(frame_timeout, Args, router_utils:frame_timeout()),
    OUI = router_utils:get_oui(),
    lager:info("~p init with ~p (frame timeout=~p)", [?SERVER, Args, DefaultFrameTimeout]),
    {ok,
        #state{
            db = DB,
            cf = CF,
            frame_timeout = DefaultFrameTimeout,
            oui = OUI,
            discovery = Discovery
        },
        {continue, {?INIT_ASYNC, ID}}}.

handle_continue({?INIT_ASYNC, ID}, #state{db = DB, cf = CF} = State) ->
    Device = get_device(DB, CF, ID),
    IsActive = router_device:is_active(Device),
    ok = router_utils:lager_md(Device),
    ok = ?MODULE:device_update(self()),
    {ok, Pid} = router_device_channels_worker:start_link(#{
        device_worker => self(), device => Device
    }),
    {noreply, State#state{
        db = DB,
        cf = CF,
        device = Device,
        fcnt = router_device:fcnt(Device),
        is_active = IsActive,
        channels_worker = Pid
    }};
handle_continue(_Msg, State) ->
    lager:warning("rcvd unknown continue msg: ~p", [_Msg]),
    {noreply, State}.

handle_call(
    {accept_uplink, PacketFCnt, Packet, PacketTime, HoldTime, PubKeyBin},
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
                    case PacketFCnt > router_device:fcnt(Device) of
                        false ->
                            lager:info(
                                "refusing, we got a packet (~p) delivered ~p ms too late from ~p (~p)",
                                [
                                    PacketFCnt,
                                    DeliveryTime,
                                    blockchain_utils:addr2name(PubKeyBin),
                                    PHash
                                ]
                            ),
                            ok = router_utils:event_uplink_dropped_late_packet(
                                PacketTime,
                                HoldTime,
                                PacketFCnt,
                                Device,
                                PubKeyBin
                            ),
                            {reply, false, State};
                        true ->
                            lager:info(
                                "accepting even if we got packet (~p) delivered ~p ms too late from ~p (~p)",
                                [
                                    PacketFCnt,
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
                {fcnt, undefined},
                {channel_correction, false}
            ],
            Device1 = router_device:update(DeviceUpdates, Device0),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            {reply, {ok, Device1}, State#state{
                device = Device1,
                downlink_handled_at = {undefined, erlang:system_time(millisecond)},
                fcnt = undefined
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
    #state{
        db = DB,
        cf = CF,
        device = Device0,
        channels_worker = ChannelsWorker,
        is_active = OldIsActive
    } = State
) ->
    DeviceID = router_device:id(Device0),
    case router_console_api:get_device(DeviceID) of
        {error, not_found} ->
            catch router_ics_eui_worker:remove([DeviceID]),
            Removes = router_device:make_skf_removes(Device0),
            catch router_ics_skf_worker:update(Removes),
            %% Important to remove details about the device _before_ the device.
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
                        router_device:devaddrs(Device0);
                    _ ->
                        catch router_ics_eui_worker:remove([DeviceID]),
                        Updates = router_device:make_skf_removes(Device0),
                        catch router_ics_skf_worker:update(Updates),
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

            OldMultiBuy = maps:get(multi_buy, router_device:metadata(Device0), 1),
            NewMultiBuy = maps:get(multi_buy, router_device:metadata(Device1), 1),

            ok = router_device_multibuy:max(router_device:id(Device1), NewMultiBuy),
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),

            case {OldIsActive, IsActive, router_device:devaddrs(Device1)} of
                {_, true, []} ->
                    catch router_ics_eui_worker:add([DeviceID]),
                    lager:debug("device EUI maybe reset, sent EUI add");
                {false, true, _} ->
                    catch router_ics_eui_worker:add([DeviceID]),
                    lager:debug("device un-paused, sent EUI add");
                {true, false, _} ->
                    catch router_ics_eui_worker:remove([DeviceID]),
                    lager:debug("device paused, sent EUI remove");
                _ ->
                    ok
            end,

            case router_device:devaddr_int_nwk_key(Device1) of
                {error, _} ->
                    ok;
                {ok, {_DevAddrInt, _NwkSKey}} ->
                    case {OldIsActive, IsActive} of
                        %% end state is active, multi-buy has changed.
                        {_, true} when OldMultiBuy =/= NewMultiBuy ->
                            catch router_ics_skf_worker:add_device_ids([DeviceID]),
                            lager:debug("device active, multi-buy changed, sent SKF add");
                        %% inactive -> active.
                        {false, true} ->
                            catch router_ics_skf_worker:add_device_ids([DeviceID]),
                            lager:debug("device un-paused, sent SKF add");
                        %% active -> inactive.
                        {true, false} ->
                            catch router_ics_skf_worker:remove_device_ids([DeviceID]),
                            lager:debug("device paused, sent SKF remove");
                        %% active state has not changed, multi-buy remains the same
                        _ ->
                            ok
                    end
            end,
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
                        PubKeyBin,
                        Packet0,
                        Region,
                        BalanceNonce
                    ),
                    {noreply, State#state{
                        device = Device1,
                        join_cache = Cache1,
                        adr_engine = undefined,
                        downlink_handled_at = {undefined, erlang:system_time(millisecond)},
                        fcnt = undefined
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
    {frame, _NwkSKey, PacketFCnt, Packet, PacketTime, _HoldTime, PubKeyBin, _Region, _Pid},
    #state{
        device = Device,
        db = DB,
        cf = CF,
        is_active = false
    } = State
) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    ok = router_device_multibuy:max(PHash, 0),
    ok = router_utils:event_uplink_dropped_device_inactive(
        PacketTime,
        PacketFCnt,
        Device,
        PubKeyBin
    ),
    Device1 = router_device:update([{fcnt, PacketFCnt}], Device),
    ok = save_device(DB, CF, Device1),
    {noreply, State};
handle_cast(
    {frame, UsedNwkSKey, PacketFCnt, Packet0, PacketTime, HoldTime, PubKeyBin, Region, Pid},
    #state{
        frame_timeout = DefaultFrameTimeout,
        device = Device0,
        frame_cache = Cache0,
        offer_cache = OfferCache,
        downlink_handled_at = DownlinkHandledAt,
        fcnt = LastSeenFCnt,
        channels_worker = ChannelsWorker,
        last_dev_nonce = LastDevNonce,
        discovery = Disco,
        adr_engine = ADREngine,
        db = DB,
        cf = CF
    } = State
) ->
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
                D1 = router_device:update([{fcnt, PacketFCnt}], Device0),
                ok = save_device(DB, CF, D1),
                D1;
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
                Keys = router_device:keys(Device0),
                DeviceUpdates = [
                    {keys,
                        lists:filter(
                            fun({NwkSKey, _}) -> NwkSKey == UsedNwkSKey end,
                            Keys
                        )},
                    {dev_nonces, DevNonces},
                    {devaddrs, [DevAddr1]},
                    {fcnt, PacketFCnt}
                ],
                D1 = router_device:update(DeviceUpdates, Device0),
                ok = save_device(DB, CF, D1),

                case erlang:length(Keys) > 1 of
                    false ->
                        ok;
                    true ->
                        MultiBuy = maps:get(multi_buy, router_device:metadata(D1), 0),
                        ToAdd = [{add, DevAddr0, UsedNwkSKey, MultiBuy}],

                        ToRemove0 = router_device:make_skf_removes(
                            Keys,
                            router_device:devaddrs(Device0),
                            MultiBuy
                        ),
                        %% Making sure that the pair that was added is not getting removed (just in case DevAddr assigned is the same)
                        ToRemove1 = ToRemove0 -- [{remove, DevAddr0, UsedNwkSKey, MultiBuy}],
                        ok = router_ics_skf_worker:update(ToAdd ++ ToRemove1),
                        lager:debug("sending update skf ~p", [ToAdd ++ ToRemove1])
                end,

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
            PacketFCnt,
            Packet0,
            PacketTime,
            PubKeyBin,
            Region,
            Device1,
            {LastSeenFCnt, DownlinkHandledAt},
            Cache0,
            OfferCache
        )
    of
        {error, {not_enough_dc, _Reason, Device2}} ->
            ok = router_utils:event_uplink_dropped_not_enough_dc(
                PacketTime,
                PacketFCnt,
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
                        PacketFCnt,
                        Device1,
                        PubKeyBin
                    );
                _ ->
                    ok = router_utils:event_uplink_dropped_invalid_packet(
                        Reason,
                        PacketTime,
                        PacketFCnt,
                        Device1,
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
                case maps:get(PacketFCnt, Cache0, undefined) of
                    undefined ->
                        lager:debug("frame ~p not found in packet cache.", [PacketFCnt]),
                        ok = router_utils:event_uplink(
                            NewFrameCache#frame_cache.uuid,
                            PacketTime,
                            HoldTime,
                            Frame,
                            Device2,
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
                            PacketFCnt,
                            Timeout
                        ]),
                        _ = erlang:send_after(
                            Timeout,
                            self(),
                            {frame_timeout, PacketFCnt, PacketTime, BalanceNonce}
                        ),
                        {NewFrameCache#frame_cache.uuid, State#state{
                            device = Device2,
                            frame_cache = maps:put(PacketFCnt, NewFrameCache, Cache0)
                        }};
                    #frame_cache{
                        uuid = OldUUID,
                        rssi = OldRSSI,
                        pid = OldPid,
                        count = OldCount,
                        pubkey_bins = PubkeyBins
                    } = OldFrameCache ->
                        lager:debug("frame ~p found in frame cache.", [PacketFCnt]),
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
                                        PacketFCnt,
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
                                        PacketFCnt,
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
    #join_accept_args{
        region = Region,
        app_nonce = _N,
        dev_addr = _D,
        app_key = _K
    } = JoinAcceptArgs,
    {Packet, PubKeyBin, _Region, _PacketTime, _HoldTime} = PacketSelected,
    lager:debug("join timeout for ~p / selected ~p out of ~p", [
        DevNonce,
        lager:pr(Packet, blockchain_helium_packet_v1),
        erlang:length(Packets) + 1
    ]),
    Plan = lora_plan:region_to_plan(Region),
    Metadata = lorawan_rxdelay:adjust_on_join(Device),
    Device1 = router_device:metadata(Metadata, Device),
    DownlinkPacket = new_join_downlink(
        craft_join_reply(Device1, JoinAcceptArgs),
        Packet,
        Plan
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
    ok = router_utils:event_join_accept(Device0, PubKeyBin, DownlinkPacket, Region),
    {noreply, State#state{
        last_dev_nonce = DevNonce,
        join_cache = maps:remove(DevNonce, JoinCache)
    }};
handle_info(
    {frame_timeout, FCnt, PacketTime, BalanceNonce},
    #state{
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

    %% Update location with best selected packet
    DeviceUpdates = [{location, PubKeyBin}],
    Device1 = router_device:update(DeviceUpdates, Device0),
    case
        handle_frame_timeout(
            Packet,
            Region,
            Device1,
            Frame,
            Count,
            ADRAdjustment,
            router_device:queue(Device1)
        )
    of
        {ok, Device2} ->
            ok = save_and_update(DB, CF, ChannelsWorker, Device2),
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
                device = Device2,
                last_dev_nonce = undefined,
                adr_engine = ADREngine1,
                frame_cache = Cache1,
                fcnt = FCnt
            }};
        {send, Device2, DownlinkPacket, {ACK, ConfirmedDown, Port, ChannelMap, FOpts}} ->
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
                PubKeyBin,
                DownlinkPacket,
                Region,
                FOpts
            ),
            ok = maybe_send_queue_update(Device2, State),
            case router_utils:mtype_to_ack(Frame#frame.mtype) of
                1 -> router_device_routing:allow_replay(Packet, DeviceID, PacketTime);
                _ -> router_device_routing:clear_replay(DeviceID)
            end,
            ok = save_and_update(DB, CF, ChannelsWorker, Device2),
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
                device = Device2,
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
            ok = save_and_update(DB, CF, ChannelsWorker, Device1),
            {noreply, State#state{
                device = Device1,
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
    OfferCache
) when MType == ?JOIN_REQ ->
    case lists:member(DevNonce, router_device:dev_nonces(Device)) of
        true ->
            {error, bad_nonce};
        false ->
            case router_utils:get_env_bool(charge_joins, true) of
                true ->
                    PayloadSize = erlang:byte_size(Payload),
                    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
                    case maybe_charge(Device, PayloadSize, PubKeyBin, PHash, OfferCache) of
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
                    end;
                false ->
                    OrgID = maps:get(organization_id, router_device:metadata(Device), undefined),
                    {Balance, Nonce} = router_console_dc_tracker:current_balance(OrgID),
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
    Region = dualplan_region(Packet, HotspotRegion),
    DRIdx = packet_datarate_index(Region, Packet),

    NewKeys = [{NwkSKey, AppSKey} | router_device:keys(Device0)],
    NewDevaddrs = [DevAddr | router_device:devaddrs(Device0)],

    DeviceUpdates = [
        {name, DeviceName},
        {dev_eui, DevEUI},
        {app_eui, AppEUI},
        {keys, NewKeys},
        {devaddrs, NewDevaddrs},
        {fcnt, undefined},
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
        {last_known_datarate, DRIdx},
        {region, Region}
    ],
    Device1 = router_device:update(DeviceUpdates, Device0),
    MultiBuy = maps:get(multi_buy, router_device:metadata(Device1), 0),

    ok = handle_join_skf(NewKeys, NewDevaddrs, MultiBuy),

    lager:debug(
        "Join DevEUI ~s with AppEUI ~s tried to join with nonce ~p region ~p via ~s",
        [
            lorawan_utils:binary_to_hex(DevEUI),
            lorawan_utils:binary_to_hex(AppEUI),
            DevNonce,
            HotspotRegion,
            blockchain_utils:addr2name(PubKeyBin)
        ]
    ),
    {ok, Device1, #join_accept_args{
        region = Region,
        app_nonce = AppNonce,
        dev_addr = DevAddr,
        app_key = AppKey
    }}.

%% When adding new credentials during a join, we want to remove the evicted
%% credentials from the config service. If a joining takes more than 25
%% attempts, we won't have the information to remove all the unused keys.
-spec handle_join_skf(
    NewKeys :: list({NwkSKey :: binary(), AppSKey :: binary()}),
    NewDevAddrs :: list(DevAddr :: binary()),
    MaxCopies :: non_neg_integer()
) -> ok.
handle_join_skf([{NwkSKey, _} | _] = NewKeys, [NewDevAddr | _] = NewDevAddrs, MaxCopies) ->
    %% remove evicted keys from the config service for every devaddr.

    KeyRemoves = router_device:make_skf_removes(
        router_device:credentials_to_evict(NewKeys),
        NewDevAddrs
    ),
    %% remove evicted devaddrs from the config service for every nwkskey.
    AddrRemoves = router_device:make_skf_removes(
        NewKeys,
        router_device:credentials_to_evict(NewDevAddrs)
    ),

    %% add the new devaddr, nskwkey.
    <<DevAddrInt:32/integer-unsigned-big>> = lorawan_utils:reverse(NewDevAddr),
    Updates = lists:usort([{add, DevAddrInt, NwkSKey, MaxCopies}] ++ KeyRemoves ++ AddrRemoves),
    ok = router_ics_skf_worker:update(Updates),

    lager:debug("sending update skf for join ~p ~p", [Updates]),
    ok.

%% Dual-Plan Code
%% Logic to support the dual frequency plan which allows an AS923_1 Hotspot
%% to support both AS923_1 and AU915 end-devices.
%% Start
-spec dualplan_region(
    Packet :: blockchain_helium_packet_v1:packet() | atom(),
    HotspotRegion :: atom()
) -> atom().
dualplan_region(Packet, HotspotRegion) ->
    Frequency = blockchain_helium_packet_v1:frequency(Packet),
    DataRate = erlang:list_to_binary(
        blockchain_helium_packet_v1:datarate(Packet)
    ),
    DeviceRegion = lora_plan:dualplan_region(HotspotRegion, Frequency, DataRate),
    lager:debug(
        "Join Frequency ~p DataRate ~p HotspotRegion ~p DeviceRegion ~p",
        [
            Frequency,
            DataRate,
            HotspotRegion,
            DeviceRegion
        ]
    ),
    DeviceRegion.

-spec region_or_default(
    DeviceRegion :: atom() | undefined,
    HotspotRegion :: atom()
) -> atom().
region_or_default(DeviceRegion, HotspotRegion) ->
    case DeviceRegion of
        undefined -> HotspotRegion;
        _ -> DeviceRegion
    end.

%% End
%% Dual-Plan Code

-spec craft_join_reply(router_device:device(), #join_accept_args{}) -> binary().
craft_join_reply(
    Device,
    #join_accept_args{region = Region, app_nonce = AppNonce, dev_addr = DevAddr, app_key = AppKey}
) ->
    Plan = lora_plan:region_to_plan(Region),
    DR = lora_plan:rx2_datarate(Plan),
    DLSettings = <<0:1, 0:3, DR:4/integer-unsigned>>,
    ReplyHdr = <<?JOIN_ACCEPT:3, 0:3, 0:2>>,
    Metadata = router_device:metadata(Device),
    CFList =
        case maps:get(cf_list_enabled, Metadata, true) of
            false -> <<>>;
            true -> lora_chmask:join_cf_list(Region)
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
    PacketFCnt :: non_neg_integer(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Device :: router_device:device(),
    {LastSeenFCnt :: undefined | non_neg_integer(), DownlinkHanldedAt :: {integer(), integer()}},
    FrameCache :: #{integer() => #frame_cache{}},
    OfferCache :: map()
) ->
    {error, any()}
    | {ok, #frame{}, router_device:device(), SendToChannel :: boolean(),
        {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}, Replay :: boolean()}.
validate_frame(
    PacketFCnt,
    Packet,
    PacketTime,
    PubKeyBin,
    Region,
    Device0,
    {LastSeenFCnt, {DownlinkHandledAtFCnt, DownlinkHandledAtTime}},
    FrameCache,
    OfferCache
) ->
    <<MType:3, _MHDRRFU:3, _Major:2, _DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
        _FOptsLen:4, _FCnt:16, _FOpts:_FOptsLen/binary,
        _PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),
    case MType of
        MType when MType == ?CONFIRMED_UP orelse MType == ?UNCONFIRMED_UP ->
            FrameAck = router_utils:mtype_to_ack(MType),
            Window = PacketTime - DownlinkHandledAtTime,
            case maps:get(PacketFCnt, FrameCache, undefined) of
                #frame_cache{} ->
                    validate_frame_(
                        PacketFCnt,
                        Packet,
                        PubKeyBin,
                        Region,
                        Device0,
                        OfferCache,
                        false
                    );
                undefined when FrameAck == 0 andalso LastSeenFCnt == undefined ->
                    lager:debug("we got a first packet [fcnt: ~p]", [PacketFCnt]),
                    validate_frame_(
                        PacketFCnt,
                        Packet,
                        PubKeyBin,
                        Region,
                        Device0,
                        OfferCache,
                        false
                    );
                undefined when FrameAck == 0 andalso PacketFCnt =< LastSeenFCnt ->
                    lager:debug("we got a late unconfirmed up packet for ~p: LastSeenFCnt: ~p", [
                        PacketFCnt,
                        LastSeenFCnt
                    ]),
                    {error, late_packet};
                undefined when
                    FrameAck == 1 andalso PacketFCnt == DownlinkHandledAtFCnt andalso
                        Window < ?RX_MAX_WINDOW
                ->
                    lager:debug(
                        "we got a late confirmed up packet for ~p: DownlinkHandledAt: ~p within window ~p",
                        [PacketFCnt, DownlinkHandledAtFCnt, Window]
                    ),
                    {error, late_packet};
                undefined when
                    FrameAck == 1 andalso PacketFCnt == DownlinkHandledAtFCnt andalso
                        Window >= ?RX_MAX_WINDOW
                ->
                    lager:debug(
                        "we got a replay confirmed up packet for ~p: DownlinkHandledAt: ~p outside window ~p",
                        [PacketFCnt, DownlinkHandledAtFCnt, Window]
                    ),
                    validate_frame_(
                        PacketFCnt,
                        Packet,
                        PubKeyBin,
                        Region,
                        Device0,
                        OfferCache,
                        true
                    );
                undefined ->
                    lager:debug("we got a fresh packet [fcnt: ~p]", [PacketFCnt]),
                    validate_frame_(
                        PacketFCnt,
                        Packet,
                        PubKeyBin,
                        Region,
                        Device0,
                        OfferCache,
                        false
                    )
            end;
        MType ->
            lager:warning("got wrong mtype ~p", [{MType, router_utils:mtype_to_ack(MType)}]),
            {error, bad_message_type}
    end.

-spec validate_frame_(
    PacketFCnt :: non_neg_integer(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    HotspotRegion :: atom(),
    Device :: router_device:device(),
    OfferCache :: map(),
    Replay :: boolean()
) ->
    {ok, #frame{}, router_device:device(), SendToChannel :: boolean(),
        {Balance :: non_neg_integer(), Nonce :: non_neg_integer()}, Replay :: boolean()}
    | {error, any()}.
validate_frame_(PacketFCnt, Packet, PubKeyBin, HotspotRegion, Device0, OfferCache, Replay) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1, FOptsLen:4,
        _FCnt:16, FOpts:FOptsLen/binary,
        PayloadAndMIC/binary>> = blockchain_helium_packet_v1:payload(Packet),
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    DevEUI = router_device:dev_eui(Device0),
    AppEUI = router_device:app_eui(Device0),
    AName = blockchain_utils:addr2name(PubKeyBin),
    TS = blockchain_helium_packet_v1:timestamp(Packet),
    lager:debug("validating frame ~p @ ~p (devaddr: ~p) region ~p from ~p", [
        PacketFCnt, TS, DevAddr, HotspotRegion, AName
    ]),
    PayloadSize = erlang:byte_size(FRMPayload),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    case maybe_charge(Device0, PayloadSize, PubKeyBin, PHash, OfferCache) of
        {error, Reason} ->
            %% REVIEW: Do we want to update region and datarate for an uncharged packet?
            DeviceUpdates = [{fcnt, PacketFCnt}, {location, PubKeyBin}],
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
                        lorawan_utils:cipher(FRMPayload, NwkSKey, MType band 1, DevAddr, PacketFCnt)
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
                    Region = region_or_default(router_device:region(Device0), HotspotRegion),
                    DRIdx = packet_datarate_index(Region, Packet),
                    BaseDeviceUpdates = [
                        {fcnt, PacketFCnt},
                        {region, Region},
                        {last_known_datarate, DRIdx}
                    ],
                    %% If frame countain ACK=1 we should clear message from queue and go on next
                    QueueDeviceUpdates =
                        case {ACK, router_device:queue(Device0)} of
                            %% Check if acknowledging confirmed downlink
                            {1, [#downlink{confirmed = true} | T]} ->
                                [{queue, T}, {fcntdown, router_device:fcntdown_next_val(Device0)}];
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
                        fcnt = PacketFCnt,
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
                        lorawan_utils:cipher(FRMPayload, AppSKey, MType band 1, DevAddr, PacketFCnt)
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
                            PacketFCnt,
                            Data,
                            AName
                        ]
                    ),
                    Region = region_or_default(router_device:region(Device0), HotspotRegion),
                    DRIdx = packet_datarate_index(Region, Packet),
                    BaseDeviceUpdates = [
                        {fcnt, PacketFCnt},
                        {region, Region},
                        {last_known_datarate, DRIdx}
                    ],
                    %% If frame countain ACK=1 we should clear message from queue and go on next
                    QueueDeviceUpdates =
                        case {ACK, router_device:queue(Device0)} of
                            %% Check if acknowledging confirmed downlink
                            {1, [#downlink{confirmed = true} | T]} ->
                                [{queue, T}, {fcntdown, router_device:fcntdown_next_val(Device0)}];
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
                        fcnt = PacketFCnt,
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
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    PHash :: binary(),
    OfferCache :: map()
) -> {ok, non_neg_integer(), non_neg_integer()} | {error, any()}.
maybe_charge(Device, PayloadSize, _PubKeyBin, _PHash, _OfferCache) ->
    router_console_dc_tracker:charge(Device, PayloadSize).

%%%-------------------------------------------------------------------
%% @doc
%% Check device's message queue to potentially wait or send reply
%% right away
%% @end
%%%-------------------------------------------------------------------
-spec handle_frame_timeout(
    Packet0 :: blockchain_helium_packet_v1:packet(),
    HotspotRegion :: atom(),
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
    _HotspotRegion,
    Device0,
    Frame,
    Count,
    ADRAdjustment,
    []
) ->
    ACK = router_utils:mtype_to_ack(Frame#frame.mtype),
    Region = router_device:region(Device0),
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
            Plan = lora_plan:region_to_plan(Region),
            Packet1 = new_data_downlink(Reply, Packet0, Plan, RxDelay),

            DeviceUpdates = [
                {channel_correction, ChannelsCorrected},
                {fcntdown, router_device:fcntdown_next_val(Device0)},
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
    _HotspotRegion,
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
    Region = router_device:region(Device0),
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
    Plan = lora_plan:region_to_plan(Region),
    Packet1 = new_data_downlink(Reply, Packet0, Plan, RxDelay),

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
                {fcntdown, router_device:fcntdown_next_val(Device0)}
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
    lora_adr:adjustment()
) -> {boolean(), list()}.
channel_correction_and_fopts(Packet, _HotspotRegion, Device, Frame, Count, ADRAdjustment) ->
    Region = router_device:region(Device),
    Plan = lora_plan:region_to_plan(Region),
    ChannelsCorrected = were_channels_corrected(Frame, Region),
    DataRateBinary = erlang:list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
    ChannelCorrection = router_device:channel_correction(Device),
    ChannelCorrectionNeeded = ChannelCorrection == false,
    FOpts1 =
        case {ChannelCorrectionNeeded, ChannelsCorrected, ADRAdjustment} of
            {true, false, _} ->
                lora_chmask:build_link_adr_req(Plan, {0, DataRateBinary}, []);
            {false, _, {NewDataRateIdx, NewTxPowerIdx}} ->
                lora_chmask:build_link_adr_req(Plan, {NewTxPowerIdx, NewDataRateIdx}, []);
            _ ->
                []
        end,
    FOpts2 =
        case lists:member(link_check_req, Frame#frame.fopts) of
            true ->
                SNR = blockchain_helium_packet_v1:snr(Packet),
                MaxUplinkSNR = lora_plan:max_uplink_snr(Plan, DataRateBinary),
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
    FOpts = lora_core:encode_fopts(Frame#frame.fopts),
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

-spec new_join_downlink(
    Reply :: binary(),
    Packet :: blockchain_helium_packet_v1:packet(),
    Plan :: lora_plan:plan()
) -> blockchain_helium_packet_v1:packet().
new_join_downlink(Reply, Packet, Plan) ->
    Rxq = packet_to_rxq(Packet),
    Rx1Window = lora_plan:join1_window(Plan, 0, Rxq),
    Rx2Window = lora_plan:join2_window(Plan, Rxq),

    #txq{time = TxTime, datr = TxDataRate, freq = TxFreq} = Rx1Window,

    blockchain_helium_packet_v1:new_downlink(
        Reply,
        lora_plan:max_tx_power(Plan, TxFreq),
        TxTime,
        TxFreq,
        binary_to_list(TxDataRate),
        window_from_txq(Rx2Window)
    ).

-spec new_data_downlink(
    Reply :: binary(),
    Packet :: blockchain_helium_packet_v1:packet(),
    Plan :: lora_plan:plan(),
    RxDelay :: number()
) -> blockchain_helium_packet_v1:packet().
new_data_downlink(Reply, Packet, Plan, RxDelay) ->
    Rxq = packet_to_rxq(Packet),
    Rx1 = lora_plan:rx1_or_rx2_window(Plan, RxDelay, 0, Rxq),
    Rx2 = lora_plan:rx2_window(Plan, RxDelay, Rxq),

    {Rx1Window, Rx2Window} =
        case {Rx1, Rx2} of
            {Same, Same} -> {Rx1, undefined};
            Windows -> Windows
        end,
    #txq{time = TxTime, datr = TxDataRate, freq = TxFreq} = Rx1Window,

    blockchain_helium_packet_v1:new_downlink(
        Reply,
        lora_plan:max_tx_power(Plan, TxFreq),
        adjust_rx_time(TxTime),
        TxFreq,
        binary_to_list(TxDataRate),
        window_from_txq(Rx2Window)
    ).

-spec window_from_txq
    (undefined) -> undefined;
    (#txq{}) -> blockchain_helium_packet_v1:window().
window_from_txq(undefined) ->
    undefined;
window_from_txq(#txq{time = TxTime, datr = TxDataRate, freq = TxFreq}) ->
    blockchain_helium_packet_v1:window(
        adjust_rx_time(TxTime),
        TxFreq,
        binary_to_list(TxDataRate)
    ).

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

-spec save_device(rocksdb:db_handle(), rocksdb:cf_handle(), router_device:device()) -> ok.
save_device(DB, CF, Device) ->
    {ok, _} = router_device_cache:save(Device),
    {ok, _} = router_device:save(DB, CF, Device),
    ok.

-spec save_and_update(rocksdb:db_handle(), rocksdb:cf_handle(), pid(), router_device:device()) ->
    ok.
save_and_update(DB, CF, Pid, Device) ->
    ok = save_device(DB, CF, Device),
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

-spec maybe_construct_adr_engine(undefined | lora_adr:handle(), atom()) -> lora_adr:handle().

maybe_construct_adr_engine(Other, Region) ->
    case Other of
        undefined ->
            lora_adr:new(Region);
        _ ->
            Other
    end.

-spec maybe_track_adr_offer(
    Device :: router_device:device(),
    ADREngine0 :: undefined | lora_adr:handle(),
    Offer :: blockchain_state_channel_offer_v1:offer()
) -> undefined | lora_adr:handle().
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
            lora_adr:track_offer(ADREngine1, AdrOffer)
    end.

-spec maybe_track_adr_packet(
    Device :: router_device:device(),
    ADREngine0 :: undefined | lora_adr:handle(),
    FrameCache :: #frame_cache{}
) -> {undefined | lora_adr:handle(), lora_adr:adjustment()}.
maybe_track_adr_packet(Device, ADREngine0, FrameCache) ->
    Metadata = router_device:metadata(Device),
    Region = router_device:region(Device),
    #frame_cache{
        rssi = RSSI,
        packet = Packet,
        pubkey_bin = PubKeyBin,
        frame = Frame,
        region = _HotspotRegion
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
            Plan = lora_plan:region_to_plan(Region),
            DataRate = erlang:list_to_binary(
                blockchain_helium_packet_v1:datarate(Packet)
            ),
            DataRateIdx = lora_plan:datarate_to_index(Plan, DataRate),
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
                        lora_adr:track_adr_answer(ADREngine1, ADRAnswer);
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
            lora_adr:track_packet(
                ADREngine2,
                AdrPacket
            )
    end.

-spec packet_datarate_index(
    Region :: atom(),
    Packet :: blockchain_helium_packet_v1:packet()
) -> integer().
packet_datarate_index(Region, Packet) ->
    %% ToDo: Our goal is for Plan data to be retrieved from chain var
    Plan = lora_plan:region_to_plan(Region),
    DataRate = erlang:list_to_binary(
        blockchain_helium_packet_v1:datarate(Packet)
    ),
    DRIdx = lora_plan:datarate_to_index(Plan, DataRate),
    DRIdx.

-spec calculate_packet_timeout(
    Device :: rourter_device:device(),
    Frame :: #frame{},
    PacketTime :: non_neg_integer(),
    ADRAdjustment :: lora_adr:adjustment(),
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
