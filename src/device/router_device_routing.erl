%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Routing ==
%%
%% - Offer packet bloomfilter
%% - Replays
%% - Multibuy
%% - Validating
%%   - packet offers
%%   - devaddrs
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_device_routing).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-include("lorawan_vars.hrl").

%% sc_handler API
-export([
    init/0,
    handle_offer/2,
    handle_packet/3,
    handle_packet/4
]).

%% replay API
-export([
    allow_replay/3,
    clear_replay/1
]).

%% Cache API
-export([
    get_device_for_offer/4,
    cache_device_for_hash/2,
    force_evict_packet_hash/1
]).

%% biggest unsigned number in 23 bits
-define(BITS_23, 8388607).
-define(MAX_16_BITS, erlang:trunc(math:pow(2, 16) - 1)).

-define(BF_ETS, router_device_routing_bf_ets).
-define(BF_KEY, bloom_key).
%% https://hur.st/bloomfilter/?n=10000&p=1.0E-6&m=&k=20
-define(BF_UNIQ_CLIENTS_MAX, 10000).
-define(BF_FALSE_POS_RATE, 1.0e-6).
-define(BF_BITMAP_SIZE, 300000).
-define(BF_FILTERS_MAX, 14).
-define(BF_ROTATE_AFTER, 1000).

-define(JOIN_MAX, 5).
-define(PACKET_MAX, 3).

%% Late packet error
-define(LATE_PACKET, late_packet).

%% Replay
-define(REPLAY_ETS, router_device_routing_replay_ets).
-define(REPLAY_MS(DeviceID), [{{'_', '$1', '_'}, [{'==', '$1', {const, DeviceID}}], [true]}]).
-define(RX2_WINDOW, timer:seconds(2)).

%% Devaddr validate
-define(DEVADDR_MALFORMED, devaddr_malformed).
-define(DEVADDR_NOT_IN_SUBNET, devaddr_not_in_subnet).
-define(OUI_UNKNOWN, oui_unknown).
-define(DEVADDR_NO_DEVICE, devaddr_no_device).

%% Packet hash cache
-define(PHASH_TO_DEVICE_CACHE, phash_to_device_cache).
%% e2qc lifetime is in seconds
%% (?RX2WINDOW + 1) to give a better chance for late packets
-define(PHASH_TO_DEVICE_CACHE_LIFETIME, 3).

%% Join offer rejected reasons
-define(CONSOLE_UNKNOWN_DEVICE, console_unknown_device).
-define(DEVICE_INACTIVE, device_inactive).
-define(DEVICE_NO_DC, device_not_enought_dc).

%% Rate Limit (per_second)
-define(THROTTLE_ERROR, limit_exceeded).
-define(HOTSPOT_THROTTLE, router_device_routing_hotspot_throttle).
-define(DEVICE_THROTTLE, router_device_routing_device_throttle).

-define(REPUTATION_ERROR, reputation_denied).
-define(POC_DENYLIST_ERROR, poc_denylist_denied).
-define(ROUTER_DENYLIST_ERROR, router_denylist_denied).

-spec init() -> ok.
init() ->
    Options = [
        public,
        named_table,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ],
    ets:new(?BF_ETS, Options),
    ets:new(?REPLAY_ETS, Options),
    {ok, BloomJoinRef} = bloom:new_forgetful(
        ?BF_BITMAP_SIZE,
        ?BF_UNIQ_CLIENTS_MAX,
        ?BF_FILTERS_MAX,
        ?BF_ROTATE_AFTER
    ),
    true = ets:insert(?BF_ETS, {?BF_KEY, BloomJoinRef}),
    HotspotRateLimit = application:get_env(router, hotspot_rate_limit, 10),
    DeviceRateLimit = application:get_env(router, device_rate_limit, 1),
    ok = throttle:setup(?HOTSPOT_THROTTLE, HotspotRateLimit, per_second),
    ok = throttle:setup(?DEVICE_THROTTLE, DeviceRateLimit, per_second),
    ok.

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
handle_offer(Offer, HandlerPid) ->
    Start = erlang:system_time(millisecond),
    Routing = blockchain_state_channel_offer_v1:routing(Offer),
    {OfferCheckTime, OfferCheck} = timer:tc(fun offer_check/1, [Offer]),
    Resp =
        case OfferCheck of
            {error, _} = Error0 ->
                Error0;
            ok ->
                case Routing of
                    #routing_information_pb{data = {eui, _EUI}} ->
                        join_offer(Offer, HandlerPid);
                    #routing_information_pb{data = {devaddr, _DevAddr}} ->
                        packet_offer(Offer, HandlerPid)
                end
        end,
    End = erlang:system_time(millisecond),
    erlang:spawn(fun() ->
        ok = router_metrics:function_observe('router_device_routing:offer_check', OfferCheckTime),
        ok = router_metrics:packet_trip_observe_start(
            blockchain_state_channel_offer_v1:packet_hash(Offer),
            blockchain_state_channel_offer_v1:hotspot(Offer),
            Start
        ),
        ok = print_handle_offer_resp(Offer, HandlerPid, Resp),
        ok = handle_offer_metrics(Routing, Resp, End - Start)
    end),
    case Resp of
        {ok, Device} ->
            ok = router_hotspot_reputation:track_offer(Offer),
            ok = router_device_stats:track_offer(Offer, Device),
            ok;
        {error, _} = Error1 ->
            Error1
    end.

-spec handle_packet(
    SCPacket ::
        blockchain_state_channel_packet_v1:packet() | blockchain_state_channel_v1:packet_pb(),
    PacketTime :: pos_integer(),
    Pid :: pid()
) -> ok | {error, any()}.
handle_packet(SCPacket, PacketTime, Pid) when is_pid(Pid) ->
    Start = erlang:system_time(millisecond),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    HoldTime = blockchain_state_channel_packet_v1:hold_time(SCPacket),
    Chain = get_chain(),
    case packet(Packet, PacketTime, HoldTime, PubKeyBin, Region, Pid, Chain) of
        {error, Reason} = E ->
            ok = router_hotspot_reputation:track_packet(SCPacket),
            ok = print_handle_packet_resp(SCPacket, Pid, reason_to_single_atom(Reason)),
            ok = handle_packet_metrics(Packet, reason_to_single_atom(Reason), Start),

            E;
        ok ->
            ok = router_hotspot_reputation:track_packet(SCPacket),
            ok = print_handle_packet_resp(SCPacket, Pid, ok),
            ok = router_metrics:routing_packet_observe_start(
                blockchain_helium_packet_v1:packet_hash(Packet),
                PubKeyBin,
                Start
            ),
            ok
    end.

%% This is for CTs only
-spec handle_packet(
    Packet :: blockchain_state_channel_packet_v1:packet() | blockchain_state_channel_v1:packet_pb(),
    PacketTime :: pos_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin() | pid(),
    Region :: atom()
) -> ok | {error, any()}.
handle_packet(Packet, PacketTime, PubKeyBin, Region) ->
    Start = erlang:system_time(millisecond),
    HoldTime = 100,
    Chain = get_chain(),
    case packet(Packet, PacketTime, HoldTime, PubKeyBin, Region, self(), Chain) of
        {error, Reason} = E ->
            lager:info("failed to handle packet ~p : ~p", [Packet, Reason]),
            ok = handle_packet_metrics(Packet, reason_to_single_atom(Reason), Start),
            E;
        ok ->
            ok = router_metrics:routing_packet_observe_start(
                blockchain_helium_packet_v1:packet_hash(Packet),
                PubKeyBin,
                Start
            ),
            ok
    end.

-spec allow_replay(blockchain_helium_packet_v1:packet(), binary(), non_neg_integer()) -> ok.
allow_replay(Packet, DeviceID, PacketTime) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    true = ets:insert(?REPLAY_ETS, {PHash, DeviceID, PacketTime}),
    lager:debug([{device_id, DeviceID}], "allowed replay for packet ~p @ ~p", [PHash, PacketTime]),
    ok.

-spec clear_replay(binary()) -> ok.
clear_replay(DeviceID) ->
    X = ets:select_delete(?REPLAY_ETS, ?REPLAY_MS(DeviceID)),
    lager:debug([{device_id, DeviceID}], "cleared ~p replay", [X]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec offer_check(Offer :: blockchain_state_channel_offer_v1:offer()) -> ok | {error, any()}.
offer_check(Offer) ->
    Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
    ReputationCheck = fun(H) ->
        router_hotspot_reputation:enabled() andalso
            router_hotspot_reputation:denied(H)
    end,
    ThrottleCheck = fun(H) ->
        case throttle:check(?HOTSPOT_THROTTLE, H) of
            {limit_exceeded, _, _} -> true;
            _ -> false
        end
    end,
    Checks = [
        {fun ru_poc_denylist:check/1, ?POC_DENYLIST_ERROR},
        {fun ru_denylist:check/1, ?ROUTER_DENYLIST_ERROR},
        {ReputationCheck, ?REPUTATION_ERROR},
        {ThrottleCheck, ?THROTTLE_ERROR}
    ],
    lists:foldl(
        fun
            ({_Fun, _Error}, {error, _} = Error) ->
                Error;
            ({Fun, Error}, ok) ->
                case Fun(Hotspot) of
                    true -> {error, Error};
                    false -> ok
                end
        end,
        ok,
        Checks
    ).

-spec print_handle_offer_resp(
    Offer :: blockchain_state_channel_offer_v1:offer(),
    HandlerPid :: pid(),
    Resp :: {ok, router_device:device()} | {error, any()}
) -> ok.
print_handle_offer_resp(Offer, HandlerPid, {ok, Device}) ->
    Routing = blockchain_state_channel_offer_v1:routing(Offer),
    Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
    HotspotName = blockchain_utils:addr2name(Hotspot),
    case Routing of
        #routing_information_pb{data = {eui, #eui_pb{deveui = DevEUI0, appeui = AppEUI0}}} ->
            DevEUI1 = eui_to_bin(DevEUI0),
            AppEUI1 = eui_to_bin(AppEUI0),
            DevEUI2 = lorawan_utils:binary_to_hex(DevEUI1),
            AppEUI2 = lorawan_utils:binary_to_hex(AppEUI1),
            lager:debug(
                [{device_id, router_device:id(Device)}],
                "buying join offer deveui=~s appeui=~s (~p/~p) from: ~p (pid: ~p)",
                [DevEUI2, AppEUI2, DevEUI0, AppEUI0, HotspotName, HandlerPid]
            );
        #routing_information_pb{data = {devaddr, DevAddr0}} ->
            DevAddr1 = lorawan_utils:reverse(devaddr_to_bin(DevAddr0)),
            DevAddr2 = lorawan_utils:binary_to_hex(DevAddr1),
            lager:debug(
                [{device_id, router_device:id(Device)}],
                "buying packet offer devaddr=~s (~p) from: ~p (pid: ~p)",
                [DevAddr2, DevAddr0, HotspotName, HandlerPid]
            )
    end;
print_handle_offer_resp(Offer, HandlerPid, Error) ->
    Routing = blockchain_state_channel_offer_v1:routing(Offer),
    Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
    HotspotName = blockchain_utils:addr2name(Hotspot),
    case Routing of
        #routing_information_pb{data = {eui, #eui_pb{deveui = DevEUI0, appeui = AppEUI0}}} ->
            DevEUI1 = eui_to_bin(DevEUI0),
            AppEUI1 = eui_to_bin(AppEUI0),
            DevEUI2 = lorawan_utils:binary_to_hex(DevEUI1),
            AppEUI2 = lorawan_utils:binary_to_hex(AppEUI1),
            lager:debug(
                [{device_id, AppEUI1}, {dev_eui, DevEUI1}],
                "refusing join offer: ~p deveui=~s appeui=~s (~p/~p) from: ~p (pid: ~p)",
                [Error, DevEUI2, AppEUI2, DevEUI0, AppEUI0, HotspotName, HandlerPid]
            );
        #routing_information_pb{data = {devaddr, DevAddr0}} ->
            DevAddr1 = lorawan_utils:reverse(devaddr_to_bin(DevAddr0)),
            DevAddr2 = lorawan_utils:binary_to_hex(DevAddr1),
            lager:debug(
                [{devaddr, DevAddr1}],
                "refusing packet offer: ~p devaddr=~s (~p) from: ~p (pid: ~p)",
                [Error, DevAddr2, DevAddr0, HotspotName, HandlerPid]
            )
    end.

-spec print_handle_packet_resp(
    Offer :: blockchain_state_channel_packet_v1:packet(),
    HandlerPid :: pid(),
    Resp :: any()
) -> ok.
print_handle_packet_resp(SCPacket, HandlerPid, Resp) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    HotspotName = blockchain_utils:addr2name(PubKeyBin),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    case blockchain_helium_packet_v1:routing_info(Packet) of
        {eui, DevEUI0, AppEUI0} ->
            DevEUI1 = eui_to_bin(DevEUI0),
            AppEUI1 = eui_to_bin(AppEUI0),
            DevEUI2 = lorawan_utils:binary_to_hex(DevEUI1),
            AppEUI2 = lorawan_utils:binary_to_hex(AppEUI1),
            lager:debug(
                [{app_eui, AppEUI1}, {dev_eui, DevEUI1}],
                "responded ~p to join deveui=~s appeui=~s (~p/~p) from: ~p (pid: ~p)",
                [Resp, DevEUI2, AppEUI2, DevEUI0, AppEUI0, HotspotName, HandlerPid]
            );
        {devaddr, DevAddr0} ->
            DevAddr1 = lorawan_utils:reverse(devaddr_to_bin(DevAddr0)),
            DevAddr2 = lorawan_utils:binary_to_hex(DevAddr1),
            <<StoredDevAddr:4/binary, _/binary>> = DevAddr1,
            lager:debug(
                [{devaddr, StoredDevAddr}],
                "responded ~p to packet devaddr=~s (~p) from: ~p (pid: ~p)",
                [Resp, DevAddr2, DevAddr0, HotspotName, HandlerPid]
            )
    end.

-spec join_offer(blockchain_state_channel_offer_v1:offer(), pid()) ->
    {ok, router_device:device()} | {error, any()}.
join_offer(Offer, Pid) ->
    Resp = join_offer_(Offer, Pid),
    erlang:spawn(fun() ->
        case Resp of
            {error, _} ->
                ok;
            {ok, Device} ->
                case maybe_start_worker(router_device:id(Device)) of
                    {error, _} ->
                        ok;
                    {ok, WorkerPid} ->
                        router_device_worker:handle_offer(WorkerPid, Offer)
                end
        end
    end),
    Resp.

-spec join_offer_(blockchain_state_channel_offer_v1:offer(), pid()) ->
    {ok, router_device:device()} | {error, any()}.
join_offer_(Offer, _Pid) ->
    #routing_information_pb{
        data = {eui, #eui_pb{deveui = DevEUI0, appeui = AppEUI0}}
    } = blockchain_state_channel_offer_v1:routing(Offer),
    DevEUI1 = eui_to_bin(DevEUI0),
    AppEUI1 = eui_to_bin(AppEUI0),
    case get_devices(DevEUI1, AppEUI1) of
        {error, _Reason} ->
            lager:debug(
                [{app_eui, AppEUI1}, {dev_eui, DevEUI1}],
                "failed to find device matching ~p/~p",
                [
                    {DevEUI1, DevEUI0},
                    {AppEUI1, AppEUI0}
                ]
            ),
            {error, ?CONSOLE_UNKNOWN_DEVICE};
        {ok, []} ->
            lager:debug(
                [{app_eui, AppEUI1}, {dev_eui, DevEUI1}],
                "did not find any device matching ~p/~p",
                [
                    {DevEUI1, DevEUI0},
                    {AppEUI1, AppEUI0}
                ]
            ),
            {error, ?CONSOLE_UNKNOWN_DEVICE};
        {ok, [Device | _] = Devices} ->
            lager:debug(
                [{app_eui, AppEUI1}, {dev_eui, DevEUI1}],
                "found devices ~p matching ~p/~p",
                [
                    [router_device:id(D) || D <- Devices],
                    DevEUI1,
                    AppEUI1
                ]
            ),
            maybe_buy_join_offer(Offer, _Pid, Device)
    end.

-spec maybe_buy_join_offer(
    blockchain_state_channel_offer_v1:offer(),
    pid(),
    router_device:device()
) -> {ok, router_device:device()} | {error, any()}.
maybe_buy_join_offer(Offer, _Pid, Device) ->
    PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
    Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
    case check_device_rate(Hotspot, Device) of
        {error, _Reason} = Error ->
            Error;
        ok ->
            case check_device_is_active(Device, Hotspot) of
                {error, _Reason} = Error ->
                    Error;
                ok ->
                    Chain = get_chain(),
                    case check_device_balance(PayloadSize, Device, Hotspot, Chain) of
                        {error, _Reason} = Error ->
                            Error;
                        ok ->
                            check_device_preferred_hotspots(Device, Offer)
                    end
            end
    end.

-spec check_device_preferred_hotspots(
    router_device:device(), blockchain_state_channel_offer_v1:offer()
) -> {ok, router_device:device()} | {error, any()}.
check_device_preferred_hotspots(Device, Offer) ->
    case router_device:preferred_hotspots(Device) of
        [] ->
            % No preferred hotspots means multibuy is allowed.
            DeviceID = router_device:id(Device),
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            case router_device_multibuy:maybe_buy(DeviceID, PHash) of
                ok -> {ok, Device};
                {error, _} = Error -> Error
            end;
        PreferredHotspots when is_list(PreferredHotspots) ->
            % Device has preferred hotspots, so multibuy is not allowed.
            OfferHotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
            case lists:member(OfferHotspot, PreferredHotspots) of
                true ->
                    {ok, Device};
                _ ->
                    {error, not_preferred_hotspot}
            end
    end.

-spec check_device_rate(Hotspot :: libp2p_crypto:pubkey_bin(), Device :: router_device:device()) ->
    ok | {error, ?THROTTLE_ERROR}.
check_device_rate(Hotspot, Device) ->
    DeviceID = router_device:id(Device),
    case throttle:check(?DEVICE_THROTTLE, {Hotspot, DeviceID}) of
        {limit_exceeded, _, _} ->
            {error, ?THROTTLE_ERROR};
        _ ->
            ok
    end.

-spec packet_offer(blockchain_state_channel_offer_v1:offer(), pid()) ->
    {ok, router_device:device()} | {error, any()}.
packet_offer(Offer, Pid) ->
    Chain = get_chain(),
    Resp = packet_offer_(Offer, Pid, Chain),
    erlang:spawn(fun() ->
        case Resp of
            {ok, Device} ->
                case maybe_start_worker(router_device:id(Device)) of
                    {error, _} ->
                        ok;
                    {ok, WorkerPid} ->
                        router_device_worker:handle_offer(WorkerPid, Offer)
                end;
            _ ->
                ok
        end
    end),
    Resp.

-spec packet_offer_(blockchain_state_channel_offer_v1:offer(), pid(), blockchain:blockchain()) ->
    {ok, router_device:device()} | {error, any()}.
packet_offer_(Offer, Pid, Chain) ->
    case validate_packet_offer(Offer, Pid, Chain) of
        {error, _} = Error ->
            Error;
        {ok, Device} ->
            DeviceID = router_device:id(Device),
            LagerOpts = [{device_id, DeviceID}],
            BFRef = lookup_bf(?BF_KEY),
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            case bloom:set(BFRef, PHash) of
                true ->
                    case lookup_replay(PHash) of
                        {ok, DeviceID, PacketTime} ->
                            case erlang:system_time(millisecond) - PacketTime > ?RX2_WINDOW of
                                true ->
                                    %% Buying replay packet
                                    lager:debug(LagerOpts, "most likely a replay packet buying"),
                                    check_device_preferred_hotspots(Device, Offer);
                                false ->
                                    lager:debug(
                                        LagerOpts,
                                        "most likely a late packet for ~p multi buying",
                                        [
                                            DeviceID
                                        ]
                                    ),
                                    {error, ?LATE_PACKET}
                            end;
                        {ok, OtherDeviceID, PacketTime} ->
                            lager:info(LagerOpts, "this packet was intended for ~p", [OtherDeviceID]),
                            case erlang:system_time(millisecond) - PacketTime > ?RX2_WINDOW of
                                true ->
                                    lager:debug(
                                        [{device_id, OtherDeviceID}],
                                        "most likely a replay packet buying"
                                    ),
                                    router_device_cache:get(OtherDeviceID);
                                false ->
                                    lager:debug(
                                        [{device_id, OtherDeviceID}],
                                        "most likely a late packet for ~p multi buying",
                                        [
                                            OtherDeviceID
                                        ]
                                    ),
                                    {error, ?LATE_PACKET}
                            end;
                        {error, not_found} ->
                            check_device_preferred_hotspots(Device, Offer)
                    end;
                false ->
                    lager:debug(LagerOpts, "buying 1st packet for ~p", [PHash]),
                    check_device_preferred_hotspots(Device, Offer)
            end
    end.

-spec validate_packet_offer(
    blockchain_state_channel_offer_v1:offer(),
    pid(),
    blockchain:blockchain()
) -> {ok, router_device:device()} | {error, any()}.
validate_packet_offer(Offer, _Pid, Chain) ->
    #routing_information_pb{data = {devaddr, DevAddr0}} = blockchain_state_channel_offer_v1:routing(
        Offer
    ),
    case validate_devaddr(DevAddr0, Chain) of
        {error, _} = Error ->
            Error;
        ok ->
            Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
            DevAddr1 = lorawan_utils:reverse(devaddr_to_bin(DevAddr0)),
            case get_device_for_offer(Offer, DevAddr1, Hotspot, Chain) of
                {error, _} = Err ->
                    Err;
                {ok, Device} ->
                    case check_device_rate(Hotspot, Device) of
                        {error, _Reason} = Error ->
                            Error;
                        ok ->
                            case check_device_is_active(Device, Hotspot) of
                                {error, _Reason} = Error ->
                                    Error;
                                ok ->
                                    PayloadSize = blockchain_state_channel_offer_v1:payload_size(
                                        Offer
                                    ),
                                    case
                                        check_device_balance(PayloadSize, Device, Hotspot, Chain)
                                    of
                                        {error, _Reason} = Error -> Error;
                                        ok -> {ok, Device}
                                    end
                            end
                    end
            end
    end.

-spec validate_devaddr(non_neg_integer(), blockchain:blockchain()) -> ok | {error, any()}.
validate_devaddr(DevAddr, Chain) ->
    case <<DevAddr:32/integer-unsigned-little>> of
        <<AddrBase:25/integer-unsigned-little, _DevAddrPrefix:7/integer>> ->
            OUI = router_utils:get_oui(),
            try blockchain_ledger_v1:find_routing(OUI, blockchain:ledger(Chain)) of
                {ok, RoutingEntry} ->
                    Subnets = blockchain_ledger_routing_v1:subnets(RoutingEntry),
                    case
                        lists:any(
                            fun(Subnet) ->
                                <<Base:25/integer-unsigned-big, Mask:23/integer-unsigned-big>> =
                                    Subnet,
                                Size = (((Mask bxor ?BITS_23) bsl 2) + 2#11) + 1,
                                AddrBase >= Base andalso AddrBase < Base + Size
                            end,
                            Subnets
                        )
                    of
                        true ->
                            ok;
                        false ->
                            {error, ?DEVADDR_NOT_IN_SUBNET}
                    end;
                _ ->
                    {error, ?OUI_UNKNOWN}
            catch
                _:_ ->
                    {error, ?OUI_UNKNOWN}
            end;
        _ ->
            {error, ?DEVADDR_MALFORMED}
    end.

-spec lookup_replay(binary()) -> {ok, binary(), non_neg_integer()} | {error, not_found}.
lookup_replay(PHash) ->
    case ets:lookup(?REPLAY_ETS, PHash) of
        [{PHash, DeviceID, PacketTime}] ->
            {ok, DeviceID, PacketTime};
        _ ->
            {error, not_found}
    end.

-spec check_device_is_active(
    Device :: router_device:device(),
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> ok | {error, ?DEVICE_INACTIVE}.
check_device_is_active(Device, PubKeyBin) ->
    case router_device:is_active(Device) of
        false ->
            ok = router_utils:event_uplink_dropped_device_inactive(
                erlang:system_time(millisecond),
                router_device:fcnt(Device),
                Device,
                PubKeyBin
            ),
            {error, ?DEVICE_INACTIVE};
        true ->
            ok
    end.

-spec check_device_balance(
    PayloadSize :: non_neg_integer(),
    Device :: router_device:device(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Chain :: blockchain:blockchain()
) -> ok | {error, ?DEVICE_NO_DC}.
check_device_balance(PayloadSize, Device, PubKeyBin, Chain) ->
    try router_console_dc_tracker:has_enough_dc(Device, PayloadSize, Chain) of
        {error, _Reason} ->
            ok = router_utils:event_uplink_dropped_not_enough_dc(
                erlang:system_time(millisecond),
                router_device:fcnt(Device),
                Device,
                PubKeyBin
            ),
            {error, ?DEVICE_NO_DC};
        {ok, _OrgID, _Balance, _Nonce} ->
            ok
    catch
        What:Why ->
            lager:info("failed to check_device_balance", [{What, Why}]),
            {error, dc_tracker_crashed}
    end.

-spec eui_to_bin(EUI :: undefined | non_neg_integer()) -> binary().
eui_to_bin(undefined) -> <<>>;
eui_to_bin(EUI) -> <<EUI:64/integer-unsigned-big>>.

-spec devaddr_to_bin(Devaddr :: non_neg_integer()) -> binary().
devaddr_to_bin(Devaddr) -> <<Devaddr:32/integer-unsigned-big>>.

-spec lookup_bf(Key :: atom()) -> reference().
lookup_bf(Key) ->
    [{Key, Ref}] = ets:lookup(?BF_ETS, Key),
    Ref.

%%%-------------------------------------------------------------------
%% @doc
%% Route packet_pb and figures out if JOIN_REQ or frame packet
%% @end
%%%-------------------------------------------------------------------
-spec packet(
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: pos_integer(),
    HoldTime :: pos_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Pid :: pid(),
    Chain :: blockchain:blockchain()
) -> ok | {error, any()}.
packet(
    #packet_pb{
        payload =
            <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, _DevNonce:2/binary,
                MIC:4/binary>> = Payload
    } = Packet,
    PacketTime,
    HoldTime,
    PubKeyBin,
    Region,
    Pid,
    Chain
) when MType == ?JOIN_REQ ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    AName = blockchain_utils:addr2name(PubKeyBin),
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
    case get_device(DevEUI, AppEUI, Msg, MIC, Chain) of
        {ok, APIDevice, AppKey} ->
            case router_device:preferred_hotspots(APIDevice) of
                [] ->
                    maybe_start_worker_and_handle_join(
                        APIDevice, Packet, PacketTime, HoldTime, PubKeyBin, Region, AppKey, Pid
                    );
                PreferredHotspots when is_list(PreferredHotspots) ->
                    case lists:member(PubKeyBin, PreferredHotspots) of
                        true ->
                            maybe_start_worker_and_handle_join(
                                APIDevice,
                                Packet,
                                PacketTime,
                                HoldTime,
                                PubKeyBin,
                                Region,
                                AppKey,
                                Pid
                            );
                        _ ->
                            {error, not_preferred_hotspot}
                    end
            end;
        {error, api_not_found} ->
            router_metrics:packet_routing_error(join, api_not_found),
            lager:debug(
                [{app_eui, AppEUI}, {dev_eui, DevEUI}],
                "no key for ~p ~p received by ~s",
                [
                    lorawan_utils:binary_to_hex(DevEUI),
                    lorawan_utils:binary_to_hex(AppEUI),
                    AName
                ]
            ),
            {error, undefined_app_key};
        {error, _Reason} ->
            router_metrics:packet_routing_error(join, bad_mic),
            lager:debug(
                [{app_eui, AppEUI}, {dev_eui, DevEUI}],
                "Device ~s with AppEUI ~s tried to join through ~s " ++
                    "but had a bad Message Intregity Code~n",
                [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]
            ),
            {error, bad_mic}
    end;
packet(
    #packet_pb{
        payload =
            <<_MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1,
                _RFU:1, FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary,
                PayloadAndMIC/binary>> = Payload
    } = Packet,
    PacketTime,
    HoldTime,
    PubKeyBin,
    Region,
    Pid,
    Chain
) ->
    MIC = binary:part(PayloadAndMIC, {erlang:byte_size(PayloadAndMIC), -4}),
    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    case DevAddr of
        <<AddrBase:25/integer-unsigned-little, DevAddrPrefix:7/integer>> ->
            OUI = router_utils:get_oui(),
            try blockchain_ledger_v1:find_routing(OUI, blockchain:ledger(Chain)) of
                {ok, RoutingEntry} ->
                    Subnets = blockchain_ledger_routing_v1:subnets(RoutingEntry),
                    case
                        lists:any(
                            fun(Subnet) ->
                                <<Base:25/integer-unsigned-big, Mask:23/integer-unsigned-big>> =
                                    Subnet,
                                Size = (((Mask bxor ?BITS_23) bsl 2) + 2#11) + 1,
                                AddrBase >= Base andalso AddrBase < Base + Size
                            end,
                            Subnets
                        )
                    of
                        true ->
                            %% ok device is in one of our subnets
                            send_to_device_worker(
                                Packet,
                                PacketTime,
                                HoldTime,
                                Pid,
                                PubKeyBin,
                                Region,
                                DevAddr,
                                MIC,
                                Payload,
                                Chain
                            );
                        false ->
                            {error, {?DEVADDR_NOT_IN_SUBNET, DevAddr}}
                    end;
                _E ->
                    lager:warning("fail to find routing ~p", [_E]),
                    %% TODO: Should fail here
                    %% no subnets
                    send_to_device_worker(
                        Packet,
                        PacketTime,
                        HoldTime,
                        Pid,
                        PubKeyBin,
                        Region,
                        DevAddr,
                        MIC,
                        Payload,
                        Chain
                    )
            catch
                _E:_S ->
                    lager:warning("crashed ~p", [{_E, _S}]),
                    %% TODO: Should fail here
                    %% no subnets
                    send_to_device_worker(
                        Packet,
                        PacketTime,
                        HoldTime,
                        Pid,
                        PubKeyBin,
                        Region,
                        DevAddr,
                        MIC,
                        Payload,
                        Chain
                    )
            end;
        _ ->
            %% wrong devaddr prefix
            {error, {?DEVADDR_MALFORMED, DevAddr}}
    end;
packet(#packet_pb{payload = Payload}, _PacketTime, _HoldTime, AName, _Region, _Pid, _Chain) ->
    {error, {bad_packet, lorawan_utils:binary_to_hex(Payload), AName}}.

maybe_start_worker_and_handle_join(
    Device, Packet, PacketTime, HoldTime, PubKeyBin, Region, AppKey, Pid
) ->
    DeviceID = router_device:id(Device),
    case maybe_start_worker(DeviceID) of
        {error, _Reason} = Error ->
            Error;
        {ok, WorkerPid} ->
            router_device_worker:handle_join(
                WorkerPid,
                Packet,
                PacketTime,
                HoldTime,
                PubKeyBin,
                Region,
                Device,
                AppKey,
                Pid
            )
    end.

-spec get_devices(DevEUI :: binary(), AppEUI :: binary()) ->
    {ok, [router_device:device()]} | {error, api_not_found}.
get_devices(DevEUI, AppEUI) ->
    case router_console_api:get_devices_by_deveui_appeui(DevEUI, AppEUI) of
        [] -> {error, api_not_found};
        KeysAndDevices -> {ok, [Device || {_, Device} <- KeysAndDevices]}
    end.

-spec get_device(
    DevEUI :: binary(),
    AppEUI :: binary(),
    Msg :: binary(),
    MIC :: binary(),
    Chain :: blockchain:blockchain()
) -> {ok, router_device:device(), binary()} | {error, any()}.
get_device(DevEUI, AppEUI, Msg, MIC, Chain) ->
    case router_console_api:get_devices_by_deveui_appeui(DevEUI, AppEUI) of
        [] ->
            {error, api_not_found};
        KeysAndDevices ->
            find_device(Msg, MIC, KeysAndDevices, Chain)
    end.

-spec find_device(
    Msg :: binary(),
    MIC :: binary(),
    [{binary(), router_device:device()}],
    Chain :: blockchain:blockchain()
) -> {ok, Device :: router_device:device(), AppKey :: binary()} | {error, not_found}.
find_device(_Msg, _MIC, [], _Chain) ->
    {error, not_found};
find_device(Msg, MIC, [{AppKey, Device} | T], Chain) ->
    case crypto:macN(cmac, aes_128_cbc, AppKey, Msg, 4) of
        MIC ->
            {ok, Device, AppKey};
        _ ->
            find_device(Msg, MIC, T, Chain)
    end.

-spec send_to_device_worker(
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    HoldTime :: non_neg_integer(),
    Pid :: pid(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    DevAddr :: binary(),
    MIC :: binary(),
    Payload :: binary(),
    Chain :: blockchain:blockchain()
) -> ok | {error, any()}.
send_to_device_worker(
    Packet,
    PacketTime,
    HoldTime,
    Pid,
    PubKeyBin,
    Region,
    DevAddr,
    MIC,
    Payload,
    Chain
) ->
    case find_device(PubKeyBin, DevAddr, MIC, Payload, Chain) of
        {error, _Reason1} = Error ->
            ok = router_hotspot_reputation:track_unknown_device(Packet, PubKeyBin),
            router_metrics:packet_routing_error(packet, device_not_found),
            lager:warning(
                "unable to find device for packet [devaddr: ~p / ~p] [gateway: ~p]",
                [DevAddr, lorawan_utils:binary_to_hex(DevAddr), libp2p_crypto:bin_to_b58(PubKeyBin)]
            ),
            Error;
        {Device, NwkSKey} ->
            ok = router_device_stats:track_packet(Packet, PubKeyBin, Device),
            case router_device:preferred_hotspots(Device) of
                [] ->
                    send_to_device_worker_(
                        Packet, PacketTime, HoldTime, Pid, PubKeyBin, Region, Device, NwkSKey
                    );
                PreferredHotspots when
                    is_list(PreferredHotspots)
                ->
                    case lists:member(PubKeyBin, PreferredHotspots) of
                        true ->
                            send_to_device_worker_(
                                Packet,
                                PacketTime,
                                HoldTime,
                                Pid,
                                PubKeyBin,
                                Region,
                                Device,
                                NwkSKey
                            );
                        _ ->
                            {error, not_preferred_hotspot}
                    end
            end
    end.

send_to_device_worker_(Packet, PacketTime, HoldTime, Pid, PubKeyBin, Region, Device, NwkSKey) ->
    DeviceID = router_device:id(Device),
    case maybe_start_worker(DeviceID) of
        {error, _Reason} = Error ->
            Error;
        {ok, WorkerPid} ->
            % TODO: I dont think we should be doing this? let the device worker decide
            case
                router_device_worker:accept_uplink(
                    WorkerPid,
                    Packet,
                    PacketTime,
                    HoldTime,
                    PubKeyBin
                )
            of
                false ->
                    lager:info("device worker refused to pick up the packet");
                true ->
                    router_device_worker:handle_frame(
                        WorkerPid,
                        NwkSKey,
                        Packet,
                        PacketTime,
                        HoldTime,
                        PubKeyBin,
                        Region,
                        Pid
                    )
            end
    end.

-spec find_device(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    DevAddr :: binary(),
    MIC :: binary(),
    Payload :: binary(),
    Chain :: blockchain:blockchain()
) -> {router_device:device(), binary()} | {error, any()}.
find_device(PubKeyBin, DevAddr, MIC, Payload, Chain) ->
    Devices = get_and_sort_devices(DevAddr, PubKeyBin, Chain),
    B0 = b0_from_payload(Payload, 16),
    case get_device_by_mic(B0, MIC, Payload, Devices) of
        {error, _} = Error ->
            Error;
        undefined ->
            {error, {unknown_device, DevAddr}};
        {Device, NwkSKey} ->
            {Device, NwkSKey}
    end.

%%%-------------------------------------------------------------------
%% @doc
%% If there are devaddr collisions, we don't know the correct device until we
%% get the whole packet with the payload. Once we have that, the device can tell
%% routing the a packet hash belongs to it. That reservation will only last a
%% short while. But it might be enough to have subsequent offers lookup the
%% correct device by the time they come through.
%% @end
%%%-------------------------------------------------------------------
-spec cache_device_for_hash(PHash :: binary(), Device :: router_device:device()) -> ok.
cache_device_for_hash(PHash, Device) ->
    _ = e2qc:cache(
        ?PHASH_TO_DEVICE_CACHE,
        PHash,
        ?PHASH_TO_DEVICE_CACHE_LIFETIME,
        fun() -> Device end
    ),
    ok.

-spec force_evict_packet_hash(PHash :: binary()) -> ok.
force_evict_packet_hash(PHash) ->
    _ = e2qc:evict(?PHASH_TO_DEVICE_CACHE, PHash),
    ok.

-spec get_device_for_offer(
    Offer :: blockchain_state_channel_offer_v1:offer(),
    DevAddr :: binary(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Chain :: blockchain:blockchain()
) -> {ok, router_device:device()} | {error, any()}.
get_device_for_offer(Offer, DevAddr, PubKeyBin, Chain) ->
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    %% interrogate the cache without inserting value
    case e2qc_nif:get(?PHASH_TO_DEVICE_CACHE, PHash) of
        notfound ->
            case get_and_sort_devices(DevAddr, PubKeyBin, Chain) of
                [] ->
                    {error, ?DEVADDR_NO_DEVICE};
                [Device | _] ->
                    %TODO: X% chance of buying packet
                    lager:debug(
                        "best guess device for offer [hash: ~p] [device_id: ~p] [pubkeybin: ~p]",
                        [PHash, router_device:id(Device), PubKeyBin]
                    ),
                    {ok, Device}
            end;
        BinDevice ->
            %% Here we are using the e2qc bin function
            Device = erlang:binary_to_term(BinDevice),
            lager:debug(
                "cached device for offer [hash: ~p] [device_id: ~p] [pubkeybin: ~p]",
                [PHash, router_device:id(Device), PubKeyBin]
            ),
            {ok, Device}
    end.

-spec get_and_sort_devices(
    DevAddr :: binary(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Chain :: blockchain:blockchain()
) -> [router_device:device()].
get_and_sort_devices(DevAddr, PubKeyBin, Chain) ->
    {Time1, Devices0} = timer:tc(router_device_cache, get_by_devaddr, [DevAddr]),
    router_metrics:function_observe('router_device_cache:get_by_devaddr', Time1),
    Devices1 = router_device_devaddr:sort_devices(Devices0, PubKeyBin, Chain),
    Devices1.

-spec get_device_by_mic(binary(), binary(), binary(), [router_device:device()]) ->
    {router_device:device(), binary()} | undefined | {error, any()}.
get_device_by_mic(_B0, _MIC, _Payload, []) ->
    undefined;
get_device_by_mic(B0, MIC, Payload, [Device | Devices]) ->
    case router_device:nwk_s_key(Device) of
        undefined ->
            DeviceID = router_device:id(Device),
            lager:warning([{device_id, DeviceID}], "device did not have a nwk_s_key, deleting"),
            {ok, DB, [_DefaultCF, CF]} = router_db:get(),
            DeviceID = router_device:id(Device),
            ok = router_device:delete(DB, CF, DeviceID),
            ok = router_device_cache:delete(DeviceID),
            get_device_by_mic(B0, MIC, Payload, Devices);
        NwkSKey ->
            case brute_force_mic(NwkSKey, B0, MIC, Payload, Device) of
                true ->
                    {Device, NwkSKey};
                false ->
                    Keys = router_device:keys(Device),
                    case find_right_key(B0, MIC, Payload, Device, Keys) of
                        false ->
                            get_device_by_mic(B0, MIC, Payload, Devices);
                        Else ->
                            Else
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

-spec find_right_key(
    B0 :: binary(),
    MIC :: binary(),
    Payload :: binary(),
    Device :: router_device:device(),
    Keys :: list({binary() | undefined, binary() | undefined})
) -> false | {error, any()} | {router_device:device(), binary()}.
find_right_key(_B0, _MIC, _Payload, _Device, []) ->
    false;
find_right_key(B0, MIC, Payload, Device, [{undefined, _} | Keys]) ->
    find_right_key(B0, MIC, Payload, Device, Keys);
find_right_key(B0, MIC, Payload, Device, [{NwkSKey, _} | Keys]) ->
    case brute_force_mic(NwkSKey, B0, MIC, Payload, Device) of
        true -> {Device, NwkSKey};
        false -> find_right_key(B0, MIC, Payload, Device, Keys);
        {error, _} = Error -> Error
    end.

-spec brute_force_mic(
    NwkSKey :: binary(),
    B0 :: binary(),
    MIC :: binary(),
    Payload :: binary(),
    Device :: router_device:device()
) -> boolean() | {error, any()}.
brute_force_mic(NwkSKey, B0, MIC, Payload, Device) ->
    DeviceID = router_device:id(Device),
    try
        case crypto:macN(cmac, aes_128_cbc, NwkSKey, B0, 4) of
            MIC ->
                true;
            _ ->
                %% Try 32 bits b0 if fcnt close to 65k
                case router_device:fcnt(Device) > ?MAX_16_BITS - 100 of
                    true ->
                        B0_32 = b0_from_payload(Payload, 32),
                        case crypto:macN(cmac, aes_128_cbc, NwkSKey, B0_32, 4) of
                            MIC ->
                                lager:warning(
                                    [{device_id, DeviceID}],
                                    "device went over max 16bits fcnt size"
                                ),
                                {ok, DB, [_DefaultCF, CF]} = router_db:get(),
                                ok = router_device:delete(DB, CF, DeviceID),
                                ok = router_device_cache:delete(DeviceID),
                                {error, {unsupported_fcnt, DeviceID}};
                            _ ->
                                false
                        end;
                    false ->
                        false
                end
        end
    catch
        _:_ ->
            lager:warning([{device_id, DeviceID}], "skipping invalid device ~p", [Device]),
            false
    end.

-spec b0_from_payload(binary(), non_neg_integer()) -> binary().
b0_from_payload(Payload, FCntSize) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
        FOptsLen:4, FCnt:FCntSize/little-unsigned-integer, _FOpts:FOptsLen/binary,
        _PayloadAndMIC/binary>> = Payload,
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
    <<
        (router_utils:b0(
            MType band 1,
            <<DevAddr:4/binary>>,
            FCnt,
            erlang:byte_size(Msg)
        ))/binary,
        Msg/binary
    >>.

%%%-------------------------------------------------------------------
%% @doc
%% Maybe start a router device worker
%% @end
%%%-------------------------------------------------------------------
-spec maybe_start_worker(binary()) -> {ok, pid()} | {error, any()}.
maybe_start_worker(DeviceID) ->
    WorkerID = router_devices_sup:id(DeviceID),
    router_devices_sup:maybe_start_worker(WorkerID, #{}).

-spec get_chain() -> blockchain:blockchain().
get_chain() ->
    router_utils:get_blockchain().

-spec handle_offer_metrics(
    #routing_information_pb{},
    {ok, router_device:device()} | {error, any()},
    non_neg_integer()
) -> ok.
handle_offer_metrics(#routing_information_pb{data = {eui, _}}, {ok, _}, Time) ->
    ok = router_metrics:routing_offer_observe(join, accepted, accepted, Time);
handle_offer_metrics(#routing_information_pb{data = {eui, _}}, {error, Reason}, Time) ->
    ok = router_metrics:routing_offer_observe(join, rejected, Reason, Time);
handle_offer_metrics(#routing_information_pb{data = {devaddr, _}}, {ok, _}, Time) ->
    ok = router_metrics:routing_offer_observe(packet, accepted, accepted, Time);
handle_offer_metrics(
    #routing_information_pb{data = {devaddr, _}},
    {error, ?DEVADDR_NOT_IN_SUBNET},
    Time
) ->
    ok = router_metrics:routing_offer_observe(packet, rejected, ?DEVADDR_NOT_IN_SUBNET, Time);
handle_offer_metrics(#routing_information_pb{data = {devaddr, _}}, {error, Reason}, Time) ->
    ok = router_metrics:routing_offer_observe(packet, rejected, Reason, Time).

-spec reason_to_single_atom(any()) -> any().
reason_to_single_atom(Reason) ->
    case Reason of
        {R, _} -> R;
        {R, _, _} -> R;
        R -> R
    end.

-spec handle_packet_metrics(blockchain_helium_packet_v1:packet(), any(), non_neg_integer()) -> ok.
handle_packet_metrics(
    #packet_pb{
        payload =
            <<MType:3, _MHDRRFU:3, _Major:2, _AppEUI0:8/binary, _DevEUI0:8/binary,
                _DevNonce:2/binary, _MIC:4/binary>>
    },
    Reason,
    Start
) when MType == ?JOIN_REQ ->
    End = erlang:system_time(millisecond),
    ok = router_metrics:routing_packet_observe(join, rejected, Reason, End - Start);
handle_packet_metrics(_Packet, Reason, Start) ->
    End = erlang:system_time(millisecond),
    ok = router_metrics:routing_packet_observe(packet, rejected, Reason, End - Start).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

replay_test() ->
    ets:new(?REPLAY_ETS, [public, named_table, set]),
    Packet0 = blockchain_helium_packet_v1:new({devaddr, 16#deadbeef}, <<"payload">>),
    PHash0 = blockchain_helium_packet_v1:packet_hash(Packet0),
    DeviceID = <<"device_id">>,
    PacketTime = 0,

    ?assertEqual(ok, allow_replay(Packet0, DeviceID, PacketTime)),
    ?assertEqual({ok, DeviceID, PacketTime}, lookup_replay(PHash0)),
    ?assertEqual(ok, clear_replay(DeviceID)),
    ?assertEqual({error, not_found}, lookup_replay(PHash0)),

    lists:foreach(
        fun(X) ->
            Packet = blockchain_helium_packet_v1:new({devaddr, 16#deadbeef}, <<X>>),
            ?MODULE:allow_replay(Packet, DeviceID, X)
        end,
        lists:seq(1, 100)
    ),
    ?assertEqual(100, ets:select_count(?REPLAY_ETS, ?REPLAY_MS(DeviceID))),
    ?assertEqual(ok, clear_replay(DeviceID)),
    ?assertEqual(0, ets:select_count(?REPLAY_ETS, ?REPLAY_MS(DeviceID))),

    ets:delete(?REPLAY_ETS),
    ok.

false_positive_test() ->
    {ok, BFRef} = bloom:new_forgetful(
        ?BF_BITMAP_SIZE,
        ?BF_UNIQ_CLIENTS_MAX,
        ?BF_FILTERS_MAX,
        ?BF_ROTATE_AFTER
    ),
    L = lists:foldl(
        fun(I, Acc) ->
            K = crypto:strong_rand_bytes(32),
            case bloom:set(BFRef, K) of
                true -> [I | Acc];
                false -> Acc
            end
        end,
        [],
        lists:seq(0, 500)
    ),
    Failures = length(L),
    ?assert(Failures < 10),
    ok.

handle_join_offer_test() ->
    application:set_env(router, hotspot_rate_limit, 100),
    application:set_env(router, device_rate_limit, 100),
    application:ensure_all_started(throttle),
    ok = init(),
    ok = router_device_multibuy:init(),

    DeviceID = router_utils:uuid_v4(),
    application:ensure_all_started(lager),
    meck:new(router_console_api, [passthrough]),
    meck:expect(router_console_api, get_devices_by_deveui_appeui, fun(_, _) ->
        [{key, router_device:new(DeviceID)}]
    end),
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> chain end),
    meck:new(router_console_dc_tracker, [passthrough]),
    meck:expect(router_console_dc_tracker, has_enough_dc, fun(_, _, _) -> {ok, orgid, 0, 1} end),
    meck:new(router_metrics, [passthrough]),
    meck:expect(router_metrics, routing_offer_observe, fun(_, _, _, _) -> ok end),
    meck:expect(router_metrics, function_observe, fun(_, _) -> ok end),
    meck:new(router_devices_sup, [passthrough]),
    meck:expect(router_devices_sup, maybe_start_worker, fun(_, _) -> {ok, self()} end),

    router_device_multibuy:max(DeviceID, 5),

    JoinPacket = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
    JoinOffer = blockchain_state_channel_offer_v1:from_packet(JoinPacket, <<"hotspot">>, 'REGION'),

    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertMatch({error, _}, handle_offer(JoinOffer, self())),
    ?assertMatch({error, _}, handle_offer(JoinOffer, self())),

    ?assert(meck:validate(router_console_api)),
    meck:unload(router_console_api),
    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(router_console_dc_tracker)),
    meck:unload(router_console_dc_tracker),
    ?assert(meck:validate(router_metrics)),
    meck:unload(router_metrics),
    ?assert(meck:validate(router_devices_sup)),
    meck:unload(router_devices_sup),
    ets:delete(?BF_ETS),
    ets:delete(?REPLAY_ETS),
    _ = catch ets:delete(router_device_multibuy_ets),
    _ = catch ets:delete(router_device_multibuy_max_ets),
    application:stop(lager),
    ok.

offer_check_success_test_() ->
    {timeout, 15, fun() ->
        {ok, _BaseDir} = offer_check_init(),

        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),
        Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
        Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),

        {Time, Resp} = timer:tc(fun offer_check/1, [Offer]),
        ?assertEqual(ok, Resp),
        %% Time is in micro seconds (10000 = 10ms)
        ?assert(Time < 10000),

        ok = offer_check_stop()
    end}.

offer_check_fail_poc_denylist_test_() ->
    {timeout, 15, fun() ->
        {ok, _BaseDir} = offer_check_init(),
        Hotspot = libp2p_crypto:b58_to_bin("1112BVrz6rsgtvmAXS9dBPh9JoASYfmtu5u3sYQjvK19AmgjGkq"),
        Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
        Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),

        ?assertEqual({error, ?POC_DENYLIST_ERROR}, offer_check(Offer)),

        ok = offer_check_stop()
    end}.

offer_check_fail_denylist_test_() ->
    {timeout, 15, fun() ->
        {ok, BaseDir} = offer_check_init(),
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),
        ok = ru_denylist:insert(BaseDir, Hotspot),
        Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
        Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),

        ?assertEqual({error, ?ROUTER_DENYLIST_ERROR}, offer_check(Offer)),

        ok = offer_check_stop()
    end}.

offer_check_fail_reputation_test_() ->
    {timeout, 15, fun() ->
        {ok, _BaseDir} = offer_check_init(),
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),
        true = ets:insert(router_hotspot_reputation_ets, {Hotspot, 666, 0}),
        Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
        Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),

        ?assertEqual({error, ?REPUTATION_ERROR}, offer_check(Offer)),

        ok = offer_check_stop()
    end}.

offer_check_fail_throttle_test_() ->
    {timeout, 15, fun() ->
        {ok, _BaseDir} = offer_check_init(),
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),
        Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
        Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),

        ?assertEqual(ok, offer_check(Offer)),
        ?assertEqual({error, ?THROTTLE_ERROR}, offer_check(Offer)),
        timer:sleep(1000),
        ?assertEqual(ok, offer_check(Offer)),
        ?assertEqual({error, ?THROTTLE_ERROR}, offer_check(Offer)),

        ok = offer_check_stop()
    end}.

offer_check_init() ->
    application:set_env(router, hotspot_reputation_enabled, true),
    ok = router_hotspot_reputation:init(),

    _ = application:ensure_all_started(throttle),
    ok = throttle:setup(?HOTSPOT_THROTTLE, 1, per_second),

    application:ensure_all_started(lager),
    application:ensure_all_started(hackney),
    BaseDir = string:chomp(os:cmd("mktemp -d")),
    _ = ru_poc_denylist:start_link(#{
        denylist_keys => ["1SbEYKju337P6aYsRd9DT2k4qgK5ZK62kXbSvnJgqeaxK3hqQrYURZjL"],
        denylist_url => "https://api.github.com/repos/helium/denylist/releases/latest",
        denylist_base_dir => BaseDir,
        denylist_check_timer => {immediate, timer:hours(12)}
    }),
    ok = wait_until(fun() ->
        ru_poc_denylist:get_version() /= {ok, 0}
    end),

    ok = ru_denylist:init(BaseDir),

    {ok, BaseDir}.

offer_check_stop() ->
    application:set_env(router, hotspot_reputation_enabled, false),
    ets:delete(router_hotspot_reputation_ets),
    ets:delete(router_hotspot_reputation_offers_ets),
    application:stop(throttle),
    application:stop(lager),
    application:stop(hackney),
    gen_server:stop(ru_poc_denylist),
    ok.

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        {fail, _Reason} = Fail ->
            Fail;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

-endif.
