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
    handle_packet/4,
    handle_free_packet/3
]).

%% replay API
-export([
    allow_replay/3,
    clear_replay/1
]).

%% Cache API
-export([
    get_device_for_offer/3,
    cache_device_for_hash/2,
    force_evict_packet_hash/1
]).

-export([
    payload_b0/2,
    payload_mic/1,
    payload_fcnt_low/1
]).

%% biggest unsigned number in 23 bits
-define(BITS_23, 8388607).
-define(MODULO_16_BITS, 16#10000).

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
-define(HOTSPOT_THROTTLE_ERROR, hotspot_limit_exceeded).
-define(DEVICE_THROTTLE_ERROR, device_limit_exceeded).
-define(HOTSPOT_THROTTLE, router_device_routing_hotspot_throttle).
%% 25/second: After analysis it seems that in best condition a hotspot
%% cannot really support more than 25 uplinks per second
-define(DEFAULT_HOTSPOT_THROTTLE, 25).

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
    HotspotRateLimit = application:get_env(router, hotspot_rate_limit, ?DEFAULT_HOTSPOT_THROTTLE),
    ok = throttle:setup(?HOTSPOT_THROTTLE, HotspotRateLimit, per_second),
    ok.

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
handle_offer(Offer, HandlerPid) ->
    case application:get_env(router, testing, false) of
        false ->
            {error, deprecated};
        true ->
            Routing = blockchain_state_channel_offer_v1:routing(Offer),
            Resp =
                case offer_check(Offer) of
                    {error, _} = Error0 ->
                        Error0;
                    ok ->
                        case Routing of
                            #routing_information_pb{data = {eui, _EUI}} ->
                                join_offer(Offer, HandlerPid);
                            #routing_information_pb{data = {devaddr, _DevAddr}} ->
                                packet_offer(Offer)
                        end
                end,
            erlang:spawn(fun() ->
                ok = print_handle_offer_resp(Offer, HandlerPid, Resp)
            end),
            case Resp of
                {ok, Device} ->
                    ok = router_device_stats:track_offer(Offer, Device),
                    ok;
                {error, _} = Error1 ->
                    Error1
            end
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
    case packet(undefined, Packet, PacketTime, HoldTime, PubKeyBin, Region, Pid) of
        {error, Reason} = E ->
            ok = print_handle_packet_resp(
                SCPacket, Pid, reason_to_single_atom(Reason)
            ),
            ok = handle_packet_metrics(Packet, reason_to_single_atom(Reason), Start),

            E;
        ok ->
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
    case packet(undefined, Packet, PacketTime, HoldTime, PubKeyBin, Region, self()) of
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

-spec handle_free_packet(
    SCPacket ::
        blockchain_state_channel_packet_v1:packet() | blockchain_state_channel_v1:packet_pb(),
    PacketTime :: pos_integer(),
    Pid :: pid()
) -> ok | {error, any()}.
handle_free_packet(SCPacket, PacketTime, Pid) when is_pid(Pid) ->
    Start = erlang:system_time(millisecond),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    HotspotName = blockchain_utils:addr2name(PubKeyBin),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    HoldTime = blockchain_state_channel_packet_v1:hold_time(SCPacket),

    Payload = blockchain_helium_packet_v1:payload(Packet),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),

    UsePacket =
        case get_device_for_payload(Payload, PubKeyBin) of
            {ok, Device, PacketFCnt} ->
                ok = lager:md([{device_id, router_device:id(Device)}]),
                case validate_payload_for_device(Device, Payload, PHash, PubKeyBin, PacketFCnt) of
                    ok ->
                        {ok, Device};
                    {error, ?LATE_PACKET} = E2 ->
                        ok = router_utils:event_uplink_dropped_late_packet(
                            PacketTime,
                            HoldTime,
                            PacketFCnt,
                            Device,
                            PubKeyBin,
                            Packet
                        ),
                        E2;
                    {error, _} = E3 ->
                        E3
                end;
            {error, _} = E4 ->
                E4
        end,
    case UsePacket of
        {ok, Device1} ->
            %% This is redondant but at least we dont have to redo all that code...
            case packet(Device1, Packet, PacketTime, HoldTime, PubKeyBin, Region, Pid) of
                {error, Reason} = Err ->
                    Pid ! {error, reason_to_single_atom(Reason)},
                    lager:debug("packet from ~p discarded ~p", [HotspotName, Reason]),
                    ok = handle_packet_metrics(Packet, reason_to_single_atom(Reason), Start),
                    Err;
                ok ->
                    lager:debug("packet from ~p accepted", [HotspotName]),
                    ok = router_metrics:routing_packet_observe_start(
                        blockchain_helium_packet_v1:packet_hash(Packet),
                        PubKeyBin,
                        Start
                    ),
                    ok
            end;
        {error, Reason} = Err ->
            lager:debug("packet from ~p discarded ~p", [HotspotName, Reason]),
            Pid ! {error, reason_to_single_atom(Reason)},
            ok = handle_packet_metrics(Packet, reason_to_single_atom(Reason), Start),
            Err
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
%% handle_packet helpers (special)
%% ------------------------------------------------------------------

-spec get_device_for_payload(
    Payload :: binary(),
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> {ok, router_device:device(), non_neg_integer()} | {error, any()}.
get_device_for_payload(Payload, PubKeyBin) ->
    case Payload of
        <<?JOIN_REQ:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, _DevNonce:2/binary,
            MIC:4/binary>> ->
            Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
            {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
            case get_device(DevEUI, AppEUI, Msg, MIC) of
                {ok, Device, _} -> {ok, Device, 0};
                E1 -> E1
            end;
        <<_MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, _/binary>> ->
            MIC = payload_mic(Payload),
            case find_device(PubKeyBin, DevAddr, MIC, Payload) of
                {ok, {Device, _NwkSKey, FCnt}} -> {ok, Device, FCnt};
                E2 -> E2
            end
    end.

-spec validate_payload_for_device(
    router_device:device(), binary(), binary(), libp2p_crypto:pubkey_bin(), non_neg_integer()
) -> ok | {error, any()}.
validate_payload_for_device(Device, Payload, PHash, PubKeyBin, Fcnt) ->
    PayloadSize = byte_size(Payload),
    case Payload of
        <<?JOIN_REQ:3, _MHDRRFU:3, _Major:2, _AppEUI:8/binary, _DevEUI:8/binary, _DevNonce:2/binary,
            _MIC:4/binary>> ->
            case maybe_buy_join_offer(Device, PayloadSize, PubKeyBin, PHash) of
                {ok, _} -> ok;
                E -> E
            end;
        <<_MType:3, _MHDRRFU:3, _Major:2, _DevAddr:4/binary, _/binary>> ->
            DeviceFcnt = router_device:fcnt(Device),
            case DeviceFcnt /= undefined andalso DeviceFcnt > Fcnt of
                true ->
                    {error, ?LATE_PACKET};
                false ->
                    case check_device_all(Device, PayloadSize, PubKeyBin) of
                        {error, _} = E ->
                            E;
                        {ok, _} ->
                            case check_device_preferred_hotspots(Device, PubKeyBin) of
                                none_preferred ->
                                    ok;
                                preferred ->
                                    ok;
                                not_preferred_hotspot ->
                                    {error, not_preferred_hotspot}
                            end
                    end
            end
    end.

-spec payload_mic(binary()) -> binary().
payload_mic(Payload) ->
    PayloadSize = byte_size(Payload),
    Part = {PayloadSize, -4},
    MIC = binary:part(Payload, Part),
    MIC.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec offer_check(Offer :: blockchain_state_channel_offer_v1:offer()) -> ok | {error, any()}.
offer_check(Offer) ->
    Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
    ThrottleCheck = fun(H) ->
        case throttle:check(?HOTSPOT_THROTTLE, H) of
            {limit_exceeded, _, _} -> true;
            _ -> false
        end
    end,
    Checks = [
        {fun ru_poc_denylist:check/1, ?POC_DENYLIST_ERROR},
        {fun ru_denylist:check/1, ?ROUTER_DENYLIST_ERROR},
        {ThrottleCheck, ?HOTSPOT_THROTTLE_ERROR}
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
            PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
            Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            maybe_buy_join_offer(Device, PayloadSize, Hotspot, PHash)
    end.

-spec maybe_buy_join_offer(
    Device :: router_device:device(),
    PayloadSize :: non_neg_integer(),
    Hotspot :: libp2p_crypto:pubkey_bin(),
    PHash :: binary()
) -> {ok, router_device:device()} | {error, any()}.
maybe_buy_join_offer(Device, PayloadSize, Hotspot, PHash) ->
    case check_device_is_active(Device, Hotspot) of
        {error, _Reason} = Error ->
            Error;
        ok ->
            case check_device_balance(PayloadSize, Device, Hotspot) of
                {error, _Reason} = Error ->
                    Error;
                ok ->
                    case check_device_preferred_hotspots(Device, Hotspot) of
                        none_preferred ->
                            maybe_multi_buy_offer(Device, PHash);
                        preferred ->
                            % Device has preferred hotspots, so multibuy is not
                            {ok, Device};
                        not_preferred_hotspot ->
                            {error, not_preferred_hotspot}
                    end
            end
    end.

-spec maybe_multi_buy_offer(router_device:device(), binary()) ->
    {ok, router_device:device()} | {error, any()}.
maybe_multi_buy_offer(Device, PHash) ->
    DeviceID = router_device:id(Device),
    case router_device_multibuy:maybe_buy(DeviceID, PHash) of
        ok -> {ok, Device};
        {error, _} = Error -> Error
    end.

-spec check_device_preferred_hotspots(
    Device :: router_device:device(),
    Hotspot :: libp2p_crypto:pubkey_bin()
) -> none_preferred | preferred | not_preferred_hotspot.
check_device_preferred_hotspots(Device, Hotspot) ->
    case router_device:preferred_hotspots(Device) of
        [] ->
            none_preferred;
        PreferredHotspots when is_list(PreferredHotspots) ->
            case lists:member(Hotspot, PreferredHotspots) of
                true ->
                    preferred;
                _ ->
                    not_preferred_hotspot
            end
    end.

-spec packet_offer(blockchain_state_channel_offer_v1:offer()) ->
    {ok, router_device:device()} | {error, any()}.
packet_offer(Offer) ->
    Resp = packet_offer_(Offer),
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

-spec packet_offer_(blockchain_state_channel_offer_v1:offer()) ->
    {ok, router_device:device()} | {error, any()}.
packet_offer_(Offer) ->
    case validate_packet_offer(Offer) of
        {error, _} = Error ->
            Error;
        {ok, Device} ->
            DeviceID = router_device:id(Device),
            LagerOpts = [{device_id, DeviceID}],
            BFRef = lookup_bf(?BF_KEY),
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),

            CheckPreferredFun = fun() ->
                case check_device_preferred_hotspots(Device, Hotspot) of
                    none_preferred -> maybe_multi_buy_offer(Device, PHash);
                    preferred -> {ok, Device};
                    not_preferred_hotspot -> {error, not_preferred_hotspot}
                end
            end,

            case bloom:set(BFRef, PHash) of
                true ->
                    case lookup_replay(PHash) of
                        {ok, DeviceID, PacketTime} ->
                            case erlang:system_time(millisecond) - PacketTime > ?RX2_WINDOW of
                                true ->
                                    %% Buying replay packet
                                    lager:debug(LagerOpts, "most likely a replay packet buying"),
                                    CheckPreferredFun();
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
                            CheckPreferredFun()
                    end;
                false ->
                    lager:debug(LagerOpts, "buying 1st packet for ~p", [PHash]),
                    CheckPreferredFun()
            end
    end.

-spec validate_packet_offer(blockchain_state_channel_offer_v1:offer()) ->
    {ok, router_device:device()} | {error, any()}.
validate_packet_offer(Offer) ->
    #routing_information_pb{data = {devaddr, DevAddr0}} = blockchain_state_channel_offer_v1:routing(
        Offer
    ),
    case validate_devaddr(DevAddr0) of
        {error, _} = Error ->
            Error;
        ok ->
            Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
            DevAddr1 = lorawan_utils:reverse(devaddr_to_bin(DevAddr0)),
            case get_device_for_offer(Offer, DevAddr1, Hotspot) of
                {error, _} = Err ->
                    Err;
                {ok, Device} ->
                    PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
                    check_device_all(Device, PayloadSize, Hotspot)
            end
    end.

%% NOTE: Preferred hotspots is not checked here. It is part of the device, but
%% has a precedence that takes place _after_ non device properties like packet
%% timing, and replays.
-spec check_device_all(router_device:device(), non_neg_integer(), libp2p_crypto:pubkey_bin()) ->
    {ok, router_device:device()} | {error, any()}.
check_device_all(Device, PayloadSize, Hotspot) ->
    case check_device_is_active(Device, Hotspot) of
        {error, _Reason} = Error ->
            Error;
        ok ->
            case check_device_balance(PayloadSize, Device, Hotspot) of
                {error, _Reason} = Error -> Error;
                ok -> {ok, Device}
            end
    end.

-spec validate_devaddr(binary() | non_neg_integer()) ->
    ok | {error, any()}.
validate_devaddr(DevNum) when erlang:is_integer(DevNum) ->
    validate_devaddr(<<DevNum:32/integer-unsigned-little>>);
validate_devaddr(DevAddr) ->
    case DevAddr of
        <<AddrBase:25/integer-unsigned-little, _DevAddrPrefix:7/integer>> ->
            case get_subnets_bases() of
                [] ->
                    {error, ?OUI_UNKNOWN};
                Ranges ->
                    case lists:member(AddrBase, Ranges) of
                        true -> ok;
                        false -> {error, ?DEVADDR_NOT_IN_SUBNET}
                    end
            end;
        _ ->
            {error, ?DEVADDR_MALFORMED}
    end.

-spec get_subnets_bases() -> list(non_neg_integer()).
get_subnets_bases() ->
    case persistent_term:get(devaddr_subnets_cache, undefined) of
        undefined ->
            {ok, Ranges} = router_device_devaddr:get_devaddr_bases(),
            Ranges;
        Cache ->
            cream:cache(
                Cache,
                devaddr_subnets_cache,
                fun() ->
                    {ok, Ranges} = router_device_devaddr:get_devaddr_bases(),
                    Ranges
                end
            )
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
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> ok | {error, ?DEVICE_NO_DC}.
check_device_balance(PayloadSize, Device, PubKeyBin) ->
    try router_console_dc_tracker:has_enough_dc(Device, PayloadSize) of
        {error, {not_enough_dc, _, _}} ->
            ok = router_utils:event_uplink_dropped_not_enough_dc(
                erlang:system_time(millisecond),
                router_device:fcnt(Device),
                Device,
                PubKeyBin
            ),
            {error, ?DEVICE_NO_DC};
        {error, _} = Err ->
            Err;
        {ok, _OrgID, _Balance, _Nonce} ->
            ok
    catch
        What:Why:Stack ->
            lager:warning("failed to check_device_balance ~p", [{What, Why}]),
            lager:warning("stack ~p", [Stack]),
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
    Device :: undefined | router_device:device(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: pos_integer(),
    HoldTime :: pos_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Pid :: pid()
) -> ok | {error, any()}.
packet(
    _Device,
    #packet_pb{
        payload =
            <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, _DevNonce:2/binary,
                MIC:4/binary>> = Payload
    } = Packet,
    PacketTime,
    HoldTime,
    PubKeyBin,
    Region,
    Pid
) when MType == ?JOIN_REQ ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    AName = blockchain_utils:addr2name(PubKeyBin),
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
    case get_device(DevEUI, AppEUI, Msg, MIC) of
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
            lager:debug(
                [{app_eui, AppEUI}, {dev_eui, DevEUI}],
                "Device ~s with AppEUI ~s tried to join through ~s " ++
                    "but had a bad Message Intregity Code~n",
                [lorawan_utils:binary_to_hex(DevEUI), lorawan_utils:binary_to_hex(AppEUI), AName]
            ),
            {error, bad_mic}
    end;
packet(
    Device,
    #packet_pb{
        payload =
            <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1,
                FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary,
                PayloadAndMIC/binary>> = Payload
    } = Packet,
    PacketTime,
    HoldTime,
    PubKeyBin,
    Region,
    Pid
) when MType == ?CONFIRMED_UP orelse MType == ?UNCONFIRMED_UP ->
    case validate_devaddr(DevAddr) of
        {error, ?DEVADDR_MALFORMED} = Err ->
            Err;
        _ ->
            MIC = binary:part(PayloadAndMIC, {erlang:byte_size(PayloadAndMIC), -4}),
            %% ok device is in one of our subnets
            send_to_device_worker(
                Device,
                Packet,
                PacketTime,
                HoldTime,
                Pid,
                PubKeyBin,
                Region,
                DevAddr,
                MIC,
                Payload
            )
    end;
packet(_Device, #packet_pb{payload = Payload}, _PacketTime, _HoldTime, AName, _Region, _Pid) ->
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
    MIC :: binary()
) -> {ok, router_device:device(), binary()} | {error, any()}.
get_device(DevEUI, AppEUI, Msg, MIC) ->
    case router_console_api:get_devices_by_deveui_appeui(DevEUI, AppEUI) of
        [] ->
            {error, api_not_found};
        KeysAndDevices ->
            find_device(Msg, MIC, KeysAndDevices)
    end.

-spec find_device(
    Msg :: binary(),
    MIC :: binary(),
    [{binary(), router_device:device()}]
) -> {ok, Device :: router_device:device(), AppKey :: binary()} | {error, not_found}.
find_device(_Msg, _MIC, []) ->
    {error, not_found};
find_device(Msg, MIC, [{AppKey, Device} | T]) ->
    case crypto:macN(cmac, aes_128_cbc, AppKey, Msg, 4) of
        MIC ->
            {ok, Device, AppKey};
        _ ->
            find_device(Msg, MIC, T)
    end.

-spec send_to_device_worker(
    Device :: undefined | router_device:device(),
    Packet :: blockchain_helium_packet_v1:packet(),
    PacketTime :: non_neg_integer(),
    HoldTime :: non_neg_integer(),
    Pid :: pid(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    DevAddr :: binary(),
    MIC :: binary(),
    Payload :: binary()
) -> ok | {error, any()}.
send_to_device_worker(
    Device0,
    Packet,
    PacketTime,
    HoldTime,
    Pid,
    PubKeyBin,
    Region,
    DevAddr,
    MIC,
    Payload
) ->
    DeviceInfo =
        case Device0 of
            undefined ->
                case find_device(PubKeyBin, DevAddr, MIC, Payload) of
                    {error, unknown_device} ->
                        lager:warning(
                            "unable to find device for packet [devaddr: ~p / ~p] [gateway: ~p]",
                            [
                                DevAddr,
                                lorawan_utils:binary_to_hex(DevAddr),
                                blockchain_utils:addr2name(PubKeyBin)
                            ]
                        ),
                        {error, unknown_device};
                    {ok, {_Device, _NwkSKey, _FCnt} = DeviceInfo0} ->
                        DeviceInfo0
                end;
            _Device ->
                case get_device_by_mic(MIC, Payload, [Device0]) of
                    undefined -> {error, mismatched_device};
                    DeviceInfo0 -> DeviceInfo0
                end
        end,
    case DeviceInfo of
        {error, _} = Err ->
            Err;
        {Device1, NwkSKey, FCnt} ->
            ok = router_device_stats:track_packet(Packet, PubKeyBin, Device1),
            case router_device:preferred_hotspots(Device1) of
                [] ->
                    send_to_device_worker_(
                        FCnt,
                        Packet,
                        PacketTime,
                        HoldTime,
                        Pid,
                        PubKeyBin,
                        Region,
                        Device1,
                        NwkSKey
                    );
                PreferredHotspots when
                    is_list(PreferredHotspots)
                ->
                    case lists:member(PubKeyBin, PreferredHotspots) of
                        true ->
                            send_to_device_worker_(
                                FCnt,
                                Packet,
                                PacketTime,
                                HoldTime,
                                Pid,
                                PubKeyBin,
                                Region,
                                Device1,
                                NwkSKey
                            );
                        _ ->
                            {error, not_preferred_hotspot}
                    end
            end
    end.

send_to_device_worker_(FCnt, Packet, PacketTime, HoldTime, Pid, PubKeyBin, Region, Device, NwkSKey) ->
    DeviceID = router_device:id(Device),
    case maybe_start_worker(DeviceID) of
        {error, _Reason} = Error ->
            Error;
        {ok, WorkerPid} ->
            % TODO: I dont think we should be doing this? let the device worker decide
            case
                router_device_worker:accept_uplink(
                    WorkerPid,
                    FCnt,
                    Packet,
                    PacketTime,
                    HoldTime,
                    PubKeyBin
                )
            of
                false ->
                    lager:info("device worker refused to pick up the packet");
                true ->
                    ok = router_device_worker:handle_frame(
                        WorkerPid,
                        NwkSKey,
                        FCnt,
                        Packet,
                        PacketTime,
                        HoldTime,
                        PubKeyBin,
                        Region,
                        Pid
                    ),
                    ok
            end
    end.

-spec find_device(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    DevAddr :: binary(),
    MIC :: binary(),
    Payload :: binary()
) -> {ok, {router_device:device(), binary(), non_neg_integer()}} | {error, unknown_device}.
find_device(PubKeyBin, DevAddr, MIC, Payload) ->
    Devices = get_and_sort_devices(DevAddr, PubKeyBin),
    case get_device_by_mic(MIC, Payload, Devices) of
        undefined ->
            {error, unknown_device};
        {Device, NwkSKey, FCnt} ->
            {ok, {Device, NwkSKey, FCnt}}
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
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> {ok, router_device:device()} | {error, any()}.
get_device_for_offer(Offer, DevAddr, PubKeyBin) ->
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    %% interrogate the cache without inserting value
    case e2qc_nif:get(?PHASH_TO_DEVICE_CACHE, PHash) of
        notfound ->
            case get_and_sort_devices(DevAddr, PubKeyBin) of
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
    PubKeyBin :: libp2p_crypto:pubkey_bin()
) -> [router_device:device()].
get_and_sort_devices(DevAddr, PubKeyBin) ->
    Devices0 = router_device_cache:get_by_devaddr(DevAddr),
    router_device_devaddr:sort_devices(Devices0, PubKeyBin).

-spec get_device_by_mic(binary(), binary(), [router_device:device()]) ->
    {router_device:device(), binary(), non_neg_integer()} | undefined.
get_device_by_mic(_MIC, _Payload, []) ->
    undefined;
get_device_by_mic(ExpectedMIC, Payload, [Device | Devices]) ->
    DeviceID = router_device:id(Device),
    case router_device:nwk_s_keys(Device) of
        [] ->
            lager:warning([{device_id, DeviceID}], "device did not have a nwk_s_key, deleting"),
            {ok, DB, [_DefaultCF, CF]} = router_db:get(),
            ok = router_device:delete(DB, CF, DeviceID),
            ok = router_device_cache:delete(DeviceID),
            get_device_by_mic(ExpectedMIC, Payload, Devices);
        Keys ->
            case find_right_key(ExpectedMIC, Payload, Keys) of
                false ->
                    lager:debug("Device does not match any FCnt. Searching next device."),
                    get_device_by_mic(ExpectedMIC, Payload, Devices);
                {true, NwkSKey, VerifiedFCnt} ->
                    lager:debug("Device ~p matches FCnt ~b.", [DeviceID, VerifiedFCnt]),
                    {Device, NwkSKey, VerifiedFCnt}
            end
    end.

-spec find_right_key(
    MIC :: binary(),
    Payload :: binary(),
    Keys :: list(binary())
) -> false | {true, VerifiedNwkSKey :: binary(), VerifiedFCnt :: non_neg_integer()}.
find_right_key(_MIC, _Payload, []) ->
    false;
find_right_key(MIC, Payload, [NwkSKey | Keys]) ->
    case key_matches_any_fcnt(NwkSKey, MIC, Payload) of
        false -> find_right_key(MIC, Payload, Keys);
        {true, FCnt} -> {true, NwkSKey, FCnt}
    end.

-spec key_matches_any_fcnt(binary(), binary(), binary()) ->
    false | {true, VerifiedFCnt :: non_neg_integer()}.
key_matches_any_fcnt(NwkSKey, ExpectedMIC, Payload) ->
    FCntLow = payload_fcnt_low(Payload),
    find_first(
        fun(HighBits) ->
            FCnt = binary:decode_unsigned(
                <<FCntLow:16/integer-unsigned-little, HighBits:16/integer-unsigned-little>>,
                little
            ),
            B0 = payload_b0(Payload, FCnt),
            {key_matches_mic(NwkSKey, B0, ExpectedMIC), FCnt}
        end,
        lists:seq(2#000, 2#111)
    ).

-spec find_first(
    Fn :: fun((T) -> {boolean(), T}),
    Els :: list(T)
) -> {true, T} | false.
find_first(_Fn, []) ->
    false;
find_first(Fn, [Head | Tail]) ->
    case Fn(Head) of
        {true, _} = Val -> Val;
        _ -> find_first(Fn, Tail)
    end.

-spec key_matches_mic(binary(), binary(), binary()) -> boolean().
key_matches_mic(Key, B0, ExpectedMIC) ->
    ComputedMIC = crypto:macN(cmac, aes_128_cbc, Key, B0, 4),
    ComputedMIC =:= ExpectedMIC.

-spec payload_fcnt_low(binary()) -> non_neg_integer().
payload_fcnt_low(Payload) ->
    <<_Mhdr:1/binary, _DevAddr:4/binary, _FCtrl:1/binary, FCntLow:16/integer-unsigned-little,
        _/binary>> = Payload,
    FCntLow.

-spec payload_b0(binary(), non_neg_integer()) -> binary().
payload_b0(Payload, ExpectedFCnt) ->
    <<MType:3, _:5, DevAddr:4/binary, _:4, FOptsLen:4, _:16, _FOpts:FOptsLen/binary, _/binary>> =
        Payload,
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
    <<
        (router_utils:b0(
            MType band 1,
            <<DevAddr:4/binary>>,
            ExpectedFCnt,
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
    application:set_env(router, testing, true),
    application:set_env(router, hotspot_rate_limit, 100),
    application:set_env(router, device_rate_limit, 100),
    application:ensure_all_started(throttle),
    ok = init(),
    ok = router_device_multibuy:init(),
    ok = router_device_stats:init(),

    DeviceID = router_utils:uuid_v4(),
    application:ensure_all_started(lager),
    meck:new(router_console_api, [passthrough]),
    meck:expect(router_console_api, get_devices_by_deveui_appeui, fun(_, _) ->
        [{key, router_device:new(DeviceID)}]
    end),
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> chain end),
    meck:new(router_console_dc_tracker, [passthrough]),
    meck:expect(router_console_dc_tracker, has_enough_dc, fun(_, _) -> {ok, orgid, 0, 1} end),
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
    ?assert(meck:validate(router_devices_sup)),
    meck:unload(router_devices_sup),
    ets:delete(?BF_ETS),
    ets:delete(?REPLAY_ETS),
    true = ets:delete(router_device_multibuy_ets),
    true = ets:delete(router_device_multibuy_max_ets),
    true = ets:delete(router_device_stats_ets),
    true = ets:delete(router_device_stats_offers_ets),
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

        meck:new(ru_poc_denylist, [passthrough]),
        meck:expect(ru_poc_denylist, check, fun(_) -> true end),

        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),

        Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
        Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),

        ?assertEqual({error, ?POC_DENYLIST_ERROR}, offer_check(Offer)),

        meck:unload(ru_poc_denylist),
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

offer_check_fail_throttle_test_() ->
    {timeout, 15, fun() ->
        {ok, _BaseDir} = offer_check_init(),
        #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
        Hotspot = libp2p_crypto:pubkey_to_bin(PubKey),
        Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
        Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),

        ?assertEqual(ok, offer_check(Offer)),
        ?assertEqual({error, ?HOTSPOT_THROTTLE_ERROR}, offer_check(Offer)),
        timer:sleep(1000),
        ?assertEqual(ok, offer_check(Offer)),
        ?assertEqual({error, ?HOTSPOT_THROTTLE_ERROR}, offer_check(Offer)),

        ok = offer_check_stop()
    end}.

offer_check_init() ->
    ok = router_device_stats:init(),

    _ = application:ensure_all_started(throttle),
    ok = throttle:setup(?HOTSPOT_THROTTLE, 1, per_second),

    application:ensure_all_started(lager),
    application:ensure_all_started(hackney),
    BaseDir = string:chomp(os:cmd("mktemp -d")),

    ok = ru_denylist:init(BaseDir),

    {ok, BaseDir}.

offer_check_stop() ->
    true = ets:delete(router_device_stats_ets),
    true = ets:delete(router_device_stats_offers_ets),
    application:stop(throttle),
    ok.

-endif.
