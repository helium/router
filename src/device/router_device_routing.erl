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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    init/0,
    handle_offer/2,
    handle_packet/3,
    deny_more/1,
    accept_more/1,
    accept_more/2,
    clear_multi_buy/1,
    allow_replay/3,
    clear_replay/1
]).

%% biggest unsigned number in 23 bits
-define(BITS_23, 8388607).
-define(MAX_16_BITS, erlang:trunc(math:pow(2, 16) - 1)).

-define(ETS, router_device_routing_ets).

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

%% Multi Buy
-define(MB_ETS, router_device_routing_mb_ets).
-define(MB_FUN(Hash), [
    {
        {Hash, '$1', '$2'},
        [{'<', '$2', '$1'}],
        [{{Hash, '$1', {'+', '$2', 1}}}]
    }
]).

-define(MB_MAX_PACKET, multi_buy_max_packet).
-define(MB_TOO_MANY_ATTEMPTS, multi_buy_too_many_attempts).
-define(MB_DENY_MORE, multi_buy_deny_more).
-define(MB_UNLIMITED, 9999).

%% Replay
-define(REPLAY_ETS, router_device_routing_replay_ets).
-define(RX2_WINDOW, timer:seconds(2)).

%% Devaddr validate
-define(DEVADDR_MALFORMED, devaddr_malformed).
-define(DEVADDR_NOT_IN_SUBNET, devaddr_not_in_subnet).
-define(OUI_UNKNOWN, oui_unknown).
-define(DEVADDR_NO_DEVICE, devaddr_no_device).

%% Join offer rejected reasons
-define(CONSOLE_UNKNOWN_DEVICE, console_unknown_device).
-define(DEVICE_INACTIVE, device_inactive).
-define(DEVICE_NO_DC, device_not_enought_dc).

-spec init() -> ok.
init() ->
    ets:new(?ETS, [public, named_table, set]),
    ets:new(?MB_ETS, [public, named_table, set]),
    ets:new(?BF_ETS, [public, named_table, set]),
    ets:new(?REPLAY_ETS, [public, named_table, set]),
    {ok, BloomJoinRef} = bloom:new_forgetful(
        ?BF_BITMAP_SIZE,
        ?BF_UNIQ_CLIENTS_MAX,
        ?BF_FILTERS_MAX,
        ?BF_ROTATE_AFTER
    ),
    true = ets:insert(?BF_ETS, {?BF_KEY, BloomJoinRef}),
    ok.

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
handle_offer(Offer, HandlerPid) ->
    Start = erlang:system_time(millisecond),
    Routing = blockchain_state_channel_offer_v1:routing(Offer),
    Resp =
        case Routing of
            #routing_information_pb{data = {eui, _EUI}} ->
                join_offer(Offer, HandlerPid);
            #routing_information_pb{data = {devaddr, _DevAddr}} ->
                packet_offer(Offer, HandlerPid)
        end,
    End = erlang:system_time(millisecond),
    erlang:spawn(fun() ->
        ok = router_metrics:packet_trip_observe_start(
            blockchain_state_channel_offer_v1:packet_hash(Offer),
            blockchain_state_channel_offer_v1:hotspot(Offer),
            Start
        ),
        ok = print_handle_offer_resp(Offer, HandlerPid, Resp),
        ok = handle_offer_metrics(Routing, Resp, End - Start)
    end),
    Resp.

-spec handle_packet(
    blockchain_state_channel_packet_v1:packet() | blockchain_state_channel_v1:packet_pb(),
    pos_integer(),
    libp2p_crypto:pubkey_bin() | pid()
) -> ok | {error, any()}.
handle_packet(SCPacket, PacketTime, Pid) when is_pid(Pid) ->
    Start = erlang:system_time(millisecond),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    _AName = blockchain_utils:addr2name(PubKeyBin),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    case packet(Packet, PacketTime, PubKeyBin, Region, Pid) of
        {error, Reason} = E ->
            ok = print_handle_packet_resp(SCPacket, Pid, reason_to_single_atom(Reason)),
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
    end;
%% This is for CTs only
handle_packet(Packet, PacketTime, PubKeyBin) ->
    Start = erlang:system_time(millisecond),
    case packet(Packet, PacketTime, PubKeyBin, 'US915', self()) of
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

-spec deny_more(binary()) -> ok.
deny_more(PHash) ->
    case ets:lookup(?MB_ETS, PHash) of
        [{PHash, 0, -1}] ->
            ok;
        _ ->
            true = ets:insert(?MB_ETS, {PHash, 0, -1}),
            ok
    end.

-spec accept_more(binary()) -> ok.
accept_more(PHash) ->
    ?MODULE:accept_more(PHash, ?PACKET_MAX).

-spec accept_more(binary(), non_neg_integer()) -> ok.
accept_more(PHash, Max) ->
    case ets:lookup(?MB_ETS, PHash) of
        [{PHash, Max, _}] ->
            ok;
        _ ->
            true = ets:insert(?MB_ETS, {PHash, Max, 1}),
            ok
    end.

-spec clear_multi_buy(blockchain_helium_packet_v1:packet()) -> ok.
clear_multi_buy(Packet) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    true = ets:delete(?MB_ETS, PHash),
    lager:debug("cleared multi buy for ~p", [PHash]),
    ok.

-spec allow_replay(blockchain_helium_packet_v1:packet(), binary(), non_neg_integer()) -> ok.
allow_replay(Packet, DeviceID, PacketTime) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    true = ets:insert(?REPLAY_ETS, {PHash, DeviceID, PacketTime}),
    lager:debug([{device_id, DeviceID}], "allowed replay for packet ~p @ ~p", [PHash, PacketTime]),
    ok.

-spec clear_replay(binary()) -> ok.
clear_replay(DeviceID) ->
    true = ets:match_delete(?REPLAY_ETS, {'_', DeviceID, '_'}),
    lager:debug([{device_id, DeviceID}], "cleared replay"),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec print_handle_offer_resp(
    Offer :: blockchain_state_channel_offer_v1:offer(),
    HandlerPid :: pid(),
    Resp :: any()
) -> ok.
print_handle_offer_resp(Offer, HandlerPid, Resp) ->
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
                [{app_eui, AppEUI1}, {dev_eui, DevEUI1}],
                "responded ~p to join offer deveui=~s appeui=~s (~p/~p) from: ~p (pid: ~p)",
                [Resp, DevEUI2, AppEUI2, DevEUI0, AppEUI0, HotspotName, HandlerPid]
            );
        #routing_information_pb{data = {devaddr, DevAddr0}} ->
            DevAddr1 = lorawan_utils:reverse(devaddr_to_bin(DevAddr0)),
            DevAddr2 = lorawan_utils:binary_to_hex(DevAddr1),
            lager:debug(
                [{devaddr, DevAddr1}],
                "responded ~p to packet offer devaddr=~s (~p) from: ~p (pid: ~p)",
                [Resp, DevAddr2, DevAddr0, HotspotName, HandlerPid]
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

-spec join_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
join_offer(Offer, _Pid) ->
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
) -> ok | {error, any()}.
maybe_buy_join_offer(Offer, _Pid, Device) ->
    PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
    case check_device_is_active(Device) of
        {error, _Reason} = Error ->
            Error;
        ok ->
            case check_device_balance(PayloadSize, Device) of
                {error, _Reason} = Error ->
                    Error;
                ok ->
                    BFRef = lookup_bf(?BF_KEY),
                    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
                    case bloom:set(BFRef, PHash) of
                        true ->
                            maybe_multi_buy(Offer, 10, Device);
                        false ->
                            true = ets:insert(?MB_ETS, {PHash, ?JOIN_MAX, 1}),
                            DeviceID = router_device:id(Device),
                            lager:debug(
                                [{device_id, DeviceID}],
                                "buying first join for ~p",
                                [PHash]
                            ),
                            ok
                    end
            end
    end.

-spec packet_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
packet_offer(Offer, Pid) ->
    case validate_packet_offer(Offer, Pid) of
        {error, _} = Error ->
            Error;
        {ok, Device} ->
            BFRef = lookup_bf(?BF_KEY),
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            case bloom:set(BFRef, PHash) of
                true ->
                    case lookup_replay(PHash) of
                        {ok, DeviceID, PackeTime} ->
                            case erlang:system_time(millisecond) - PackeTime > ?RX2_WINDOW of
                                true ->
                                    %% Buying replay packet
                                    lager:debug(
                                        [{device_id, DeviceID}],
                                        "most likely a replay packet buying"
                                    ),
                                    ok;
                                false ->
                                    lager:debug(
                                        [{device_id, DeviceID}],
                                        "most likely a late packet for ~p multi buying",
                                        [
                                            DeviceID
                                        ]
                                    ),
                                    {error, ?LATE_PACKET}
                            end;
                        {error, not_found} ->
                            maybe_multi_buy(Offer, 10, Device)
                    end;
                false ->
                    lager:debug(
                        [{device_id, router_device:id(Device)}],
                        "buying 1st packet for ~p",
                        [PHash]
                    ),
                    ok
            end
    end.

-spec validate_packet_offer(blockchain_state_channel_offer_v1:offer(), pid()) ->
    {ok, router_device:device()} | {error, any()}.
validate_packet_offer(Offer, _Pid) ->
    #routing_information_pb{data = {devaddr, DevAddr0}} = blockchain_state_channel_offer_v1:routing(
        Offer
    ),
    case validate_devaddr(DevAddr0) of
        {error, _} = Error ->
            Error;
        ok ->
            PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),
            DevAddr1 = lorawan_utils:reverse(devaddr_to_bin(DevAddr0)),
            case get_and_sort_devices(DevAddr1, PubKeyBin) of
                [] ->
                    {error, ?DEVADDR_NO_DEVICE};
                [Device | _] ->
                    case check_device_is_active(Device) of
                        {error, _Reason} = Error ->
                            Error;
                        ok ->
                            case maybe_start_worker(router_device:id(Device)) of
                                {error, _} ->
                                    ok;
                                {ok, WorkerPid} ->
                                    router_device_worker:handle_offer(WorkerPid, Offer)
                            end,
                            PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
                            case check_device_balance(PayloadSize, Device) of
                                {error, _Reason} = Error -> Error;
                                ok -> {ok, Device}
                            end
                    end
            end
    end.

-spec validate_devaddr(non_neg_integer()) -> ok | {error, any()}.
validate_devaddr(DevAddr) ->
    case <<DevAddr:32/integer-unsigned-little>> of
        <<AddrBase:25/integer-unsigned-little, _DevAddrPrefix:7/integer>> ->
            Chain = get_chain(),
            OUI = router_device_utils:get_router_oui(),
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

-spec maybe_multi_buy(
    blockchain_state_channel_offer_v1:offer(),
    non_neg_integer(),
    router_device:device()
) -> ok | {error, any()}.
%% Handle an issue with worker (so we dont stay in a loop)
maybe_multi_buy(_Offer, 0, _Device) ->
    {error, ?MB_TOO_MANY_ATTEMPTS};
maybe_multi_buy(Offer, Attempts, Device) ->
    DeviceID = router_device:id(Device),
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    case ets:lookup(?MB_ETS, PHash) of
        [] ->
            MultiBuyValue = maps:get(multi_buy, router_device:metadata(Device), 1),
            case MultiBuyValue > 1 of
                true ->
                    lager:debug(
                        [{device_id, DeviceID}],
                        "accepting more packets [multi_buy: ~p] for ~p",
                        [MultiBuyValue, PHash]
                    ),
                    ?MODULE:accept_more(PHash, MultiBuyValue);
                false ->
                    case router_device:queue(Device) of
                        [] ->
                            lager:debug(
                                [{device_id, DeviceID}],
                                "did not get an answer from device worker yet waiting, packet: ~p",
                                [PHash]
                            ),
                            timer:sleep(10),
                            maybe_multi_buy(Offer, Attempts - 1, Device);
                        _Queue ->
                            lager:debug(
                                [{device_id, DeviceID}],
                                "Accepting more packets [queue_length: ~p] for ~p",
                                [
                                    length(_Queue)
                                ]
                            ),
                            ?MODULE:accept_more(PHash)
                    end
            end;
        [{PHash, ?MB_UNLIMITED, _Curr}] ->
            lager:debug(
                [{device_id, DeviceID}],
                "accepting more packets [multi_buy: ~p] for ~p",
                [?MB_UNLIMITED, PHash]
            ),
            ok;
        [{PHash, 0, -1}] ->
            lager:debug(
                [{device_id, DeviceID}],
                "denying more packets for ~p",
                [PHash]
            ),
            {error, ?MB_DENY_MORE};
        [{PHash, Max, Curr}] when Max == Curr ->
            lager:debug(
                [{device_id, DeviceID}],
                "denying more packets max reached ~p for ~p",
                [Max, PHash]
            ),
            {error, ?MB_MAX_PACKET};
        [{PHash, _Max, _Curr}] ->
            lager:debug(
                [{device_id, DeviceID}],
                "accepting more packets max: ~p current: ~p for ~p",
                [_Max, _Curr, PHash]
            ),
            case ets:select_replace(?MB_ETS, ?MB_FUN(PHash)) of
                0 -> {error, ?MB_MAX_PACKET};
                1 -> ok
            end
    end.

-spec check_device_is_active(router_device:device()) -> ok | {error, any()}.
check_device_is_active(Device) ->
    case router_device:is_active(Device) of
        false ->
            ok = router_device_utils:report_status_inactive(Device),
            {error, ?DEVICE_INACTIVE};
        true ->
            ok
    end.

-spec check_device_balance(non_neg_integer(), router_device:device()) -> ok | {error, any()}.
check_device_balance(PayloadSize, Device) ->
    Chain = get_chain(),
    case router_console_dc_tracker:has_enough_dc(Device, PayloadSize, Chain) of
        {error, _Reason} ->
            ok = router_device_utils:report_status_no_dc(Device),
            {error, ?DEVICE_NO_DC};
        {ok, _OrgID, _Balance, _Nonce} ->
            ok
    end.

-spec eui_to_bin(undefined | non_neg_integer()) -> binary().
eui_to_bin(undefined) -> <<>>;
eui_to_bin(EUI) -> <<EUI:64/integer-unsigned-big>>.

-spec devaddr_to_bin(non_neg_integer()) -> binary().
devaddr_to_bin(Devaddr) -> <<Devaddr:32/integer-unsigned-big>>.

-spec lookup_bf(atom()) -> reference().
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
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Region :: atom(),
    Pid :: pid()
) -> ok | {error, any()}.
packet(
    #packet_pb{
        payload =
            <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, _DevNonce:2/binary,
                MIC:4/binary>> = Payload
    } = Packet,
    PacketTime,
    PubKeyBin,
    Region,
    Pid
) when MType == ?JOIN_REQ ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    AName = blockchain_utils:addr2name(PubKeyBin),
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
    case get_device(DevEUI, AppEUI, Msg, MIC) of
        {ok, APIDevice, AppKey} ->
            DeviceID = router_device:id(APIDevice),
            case maybe_start_worker(DeviceID) of
                {error, _Reason} = Error ->
                    Error;
                {ok, WorkerPid} ->
                    router_device_worker:handle_join(
                        WorkerPid,
                        Packet,
                        PacketTime,
                        PubKeyBin,
                        Region,
                        APIDevice,
                        AppKey,
                        Pid
                    )
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
    #packet_pb{
        payload =
            <<_MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1,
                _RFU:1, FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary,
                PayloadAndMIC/binary>> = Payload
    } = Packet,
    PacketTime,
    PubKeyBin,
    Region,
    Pid
) ->
    MIC = binary:part(PayloadAndMIC, {erlang:byte_size(PayloadAndMIC), -4}),
    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    case DevAddr of
        <<AddrBase:25/integer-unsigned-little, DevAddrPrefix:7/integer>> ->
            Chain = get_chain(),
            OUI = router_device_utils:get_router_oui(),
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
                                Pid,
                                PubKeyBin,
                                Region,
                                DevAddr,
                                MIC,
                                Payload
                            );
                        false ->
                            {error, {?DEVADDR_NOT_IN_SUBNET, DevAddr}}
                    end;
                _ ->
                    %% TODO: Should fail here
                    %% no subnets
                    send_to_device_worker(
                        Packet,
                        PacketTime,
                        Pid,
                        PubKeyBin,
                        Region,
                        DevAddr,
                        MIC,
                        Payload
                    )
            catch
                _:_ ->
                    %% TODO: Should fail here
                    %% no subnets
                    send_to_device_worker(
                        Packet,
                        PacketTime,
                        Pid,
                        PubKeyBin,
                        Region,
                        DevAddr,
                        MIC,
                        Payload
                    )
            end;
        _ ->
            %% wrong devaddr prefix
            {error, {?DEVADDR_MALFORMED, DevAddr}}
    end;
packet(#packet_pb{payload = Payload}, _PacketTime, AName, _Region, _Pid) ->
    {error, {bad_packet, lorawan_utils:binary_to_hex(Payload), AName}}.

-spec get_devices(binary(), binary()) -> {ok, [router_device:device()]} | {error, any()}.
get_devices(DevEUI, AppEUI) ->
    case router_console_api:get_devices_by_deveui_appeui(DevEUI, AppEUI) of
        [] -> {error, api_not_found};
        KeysAndDevices -> {ok, [Device || {_, Device} <- KeysAndDevices]}
    end.

-spec get_device(binary(), binary(), binary(), binary()) ->
    {ok, router_device:device(), binary()} | {error, any()}.
get_device(DevEUI, AppEUI, Msg, MIC) ->
    case router_console_api:get_devices_by_deveui_appeui(DevEUI, AppEUI) of
        [] ->
            {error, api_not_found};
        KeysAndDevices ->
            find_device(Msg, MIC, KeysAndDevices)
    end.

-spec find_device(binary(), binary(), [{binary(), router_device:device()}]) ->
    {ok, router_device:device(), binary()} | {error, not_found}.
find_device(_Msg, _MIC, []) ->
    {error, not_found};
find_device(Msg, MIC, [{AppKey, Device} | T]) ->
    case crypto:cmac(aes_cbc128, AppKey, Msg, 4) of
        MIC ->
            {ok, Device, AppKey};
        _ ->
            find_device(Msg, MIC, T)
    end.

send_to_device_worker(Packet, PacketTime, Pid, PubKeyBin, Region, DevAddr, MIC, Payload) ->
    case find_device(PubKeyBin, DevAddr, MIC, Payload) of
        {error, _Reason1} = Error ->
            Error;
        {Device, NwkSKey} ->
            DeviceID = router_device:id(Device),
            case maybe_start_worker(DeviceID) of
                {error, _Reason} = Error ->
                    Error;
                {ok, WorkerPid} ->
                    router_device_worker:handle_frame(
                        WorkerPid,
                        NwkSKey,
                        Packet,
                        PacketTime,
                        PubKeyBin,
                        Region,
                        Pid
                    )
            end
    end.

find_device(PubKeyBin, DevAddr, MIC, Payload) ->
    Devices = get_and_sort_devices(DevAddr, PubKeyBin),
    B0 = b0_from_payload(Payload, 16),
    case get_device_by_mic(B0, MIC, Payload, Devices) of
        {error, _} = Error ->
            Error;
        undefined ->
            {error, {unknown_device, DevAddr}};
        {Device, NwkSKey} ->
            {Device, NwkSKey}
    end.

get_and_sort_devices(DevAddr, PubKeyBin) ->
    {Time1, Devices0} = timer:tc(router_device_cache, get_by_devaddr, [DevAddr]),
    {Time2, Devices1} = timer:tc(router_device_devaddr, sort_devices, [Devices0, PubKeyBin]),
    router_metrics:function_observe('router_device_cache:get_by_devaddr', Time1),
    router_metrics:function_observe('router_device_devaddr:sort_devices', Time2),
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
        case crypto:cmac(aes_cbc128, NwkSKey, B0, 4) of
            MIC ->
                true;
            _ ->
                %% Try 32 bits b0 if fcnt close to 65k
                case router_device:fcnt(Device) > ?MAX_16_BITS - 100 of
                    true ->
                        B0_32 = b0_from_payload(Payload, 32),
                        case crypto:cmac(aes_cbc128, NwkSKey, B0_32, 4) of
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
    <<(router_utils:b0(
            MType band 1,
            <<DevAddr:4/binary>>,
            FCnt,
            erlang:byte_size(Msg)
        ))/binary,
        Msg/binary>>.

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
    Key = blockchain,
    case ets:lookup(?ETS, Key) of
        [] ->
            Chain = blockchain_worker:blockchain(),
            true = ets:insert(?ETS, {Key, Chain}),
            Chain;
        [{Key, Chain}] ->
            Chain
    end.

-spec handle_offer_metrics(any(), ok | {error, any()}, non_neg_integer()) -> ok.
handle_offer_metrics(#routing_information_pb{data = {eui, _}}, ok, Time) ->
    ok = router_metrics:routing_offer_observe(join, accepted, accepted, Time);
handle_offer_metrics(#routing_information_pb{data = {eui, _}}, {error, Reason}, Time) ->
    ok = router_metrics:routing_offer_observe(join, rejected, Reason, Time);
handle_offer_metrics(#routing_information_pb{data = {devaddr, _}}, ok, Time) ->
    ok = router_metrics:routing_offer_observe(packet, accepted, accepted, Time);
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

multi_buy_test() ->
    ets:new(?MB_ETS, [public, named_table, set]),
    Packet = blockchain_helium_packet_v1:new({devaddr, 16#deadbeef}, <<"payload">>),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),

    ?assertEqual([], ets:lookup(?MB_ETS, PHash)),
    ?assertEqual(ok, deny_more(PHash)),
    ?assertEqual([{PHash, 0, -1}], ets:lookup(?MB_ETS, PHash)),
    ?assertEqual(ok, clear_multi_buy(Packet)),
    ?assertEqual([], ets:lookup(?MB_ETS, PHash)),
    ?assertEqual(ok, accept_more(PHash)),
    ?assertEqual([{PHash, ?PACKET_MAX, 1}], ets:lookup(?MB_ETS, PHash)),
    ?assertEqual(ok, clear_multi_buy(Packet)),
    ?assertEqual([], ets:lookup(?MB_ETS, PHash)),
    ?assertEqual(ok, clear_multi_buy(Packet)),

    ets:delete(?MB_ETS),
    ok.

replay_test() ->
    ets:new(?REPLAY_ETS, [public, named_table, set]),
    Packet = blockchain_helium_packet_v1:new({devaddr, 16#deadbeef}, <<"payload">>),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    DeviceID = <<"device_id">>,
    PacketTime = 0,

    ?assertEqual(ok, allow_replay(Packet, DeviceID, PacketTime)),
    ?assertEqual({ok, DeviceID, PacketTime}, lookup_replay(PHash)),
    ?assertEqual(ok, clear_replay(DeviceID)),
    ?assertEqual({error, not_found}, lookup_replay(PHash)),

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
    ok = init(),
    application:ensure_all_started(lager),
    meck:new(router_console_api, [passthrough]),
    meck:expect(router_console_api, get_devices_by_deveui_appeui, fun(_, _) ->
        [{key, router_device:new(<<"id">>)}]
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

    JoinPacket = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
    JoinOffer = blockchain_state_channel_offer_v1:from_packet(JoinPacket, <<"hotspot">>, 'REGION'),

    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual({error, ?MB_MAX_PACKET}, handle_offer(JoinOffer, self())),
    ?assertEqual({error, ?MB_MAX_PACKET}, handle_offer(JoinOffer, self())),

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
    ets:delete(?ETS),
    ets:delete(?BF_ETS),
    ets:delete(?MB_ETS),
    ets:delete(?REPLAY_ETS),
    application:stop(lager),
    ok.

handle_packet_offer_test() ->
    Dir = test_utils:tmp_dir("handle_packet_offer_test"),
    {ok, Pid} = router_db:start_link([Dir]),

    Subnet = <<0, 0, 0, 127, 255, 0>>,
    <<Base:25/integer-unsigned-big, _Mask:23/integer-unsigned-big>> = Subnet,
    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    <<DevAddr:32/integer-unsigned-little>> =
        <<Base:25/integer-unsigned-little, DevAddrPrefix:7/integer>>,

    DeviceUpdates = [{devaddr, <<DevAddr:32/integer-unsigned-little>>}],
    Device0 = router_device:new(<<"device_id">>),
    Device1 = router_device:update(DeviceUpdates, Device0),
    {ok, DB, [_DefaultCF, CF]} = router_db:get(),
    {ok, Device1} = router_device:save(DB, CF, Device1),

    {ok, _} = router_devices_sup:start_link(),

    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> chain end),
    meck:new(blockchain, [passthrough]),
    meck:expect(blockchain, ledger, fun(_) -> ledger end),
    meck:new(blockchain_ledger_v1, [passthrough]),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_, _) -> {ok, entry} end),
    meck:new(blockchain_ledger_routing_v1, [passthrough]),
    meck:expect(blockchain_ledger_routing_v1, subnets, fun(_) -> [Subnet] end),
    meck:new(router_metrics, [passthrough]),
    meck:expect(router_metrics, routing_packet_observe, fun(_, _, _, _) -> ok end),
    meck:expect(router_metrics, routing_offer_observe, fun(_, _, _, _) -> ok end),
    meck:expect(router_metrics, function_observe, fun(_, _) -> ok end),
    meck:new(router_device_devaddr, [passthrough]),
    meck:expect(router_device_devaddr, sort_devices, fun(Devices, _) -> Devices end),
    meck:new(router_console_dc_tracker, [passthrough]),
    meck:expect(router_console_dc_tracker, has_enough_dc, fun(_, _, _) -> {ok, orgid, 0, 1} end),

    NewOffer = fun(Payload) ->
        Packet = blockchain_helium_packet_v1:new({devaddr, DevAddr}, Payload),
        PHash = blockchain_helium_packet_v1:packet_hash(Packet),
        Offer = blockchain_state_channel_offer_v1:from_packet(Packet, <<"hotspot">>, 'REGION'),
        {Offer, PHash}
    end,

    %% Deny more packets after first
    {Offer0, PHash0} = NewOffer(<<"payload0">>),
    ?assertEqual(ok, handle_offer(Offer0, self())),
    ok = ?MODULE:deny_more(PHash0),
    ?assertEqual({error, ?MB_DENY_MORE}, handle_offer(Offer0, self())),
    ?assertEqual({error, ?MB_DENY_MORE}, handle_offer(Offer0, self())),

    %% Accept MAX packets
    {Offer1, PHash1} = NewOffer(<<"payload1">>),
    ?assertEqual(ok, handle_offer(Offer1, self())),
    ok = ?MODULE:accept_more(PHash1),
    ?assertEqual(ok, handle_offer(Offer1, self())),
    ?assertEqual(ok, handle_offer(Offer1, self())),
    ?assertEqual({error, ?MB_MAX_PACKET}, handle_offer(Offer1, self())),
    ?assertEqual({error, ?MB_MAX_PACKET}, handle_offer(Offer1, self())),

    %% Accept more than MAX packets
    {Offer2, PHash2} = NewOffer(<<"payload2">>),
    ok = ?MODULE:accept_more(PHash2, ?PACKET_MAX * 2),
    ?assertEqual(ok, handle_offer(Offer2, self())),
    ?assertEqual(ok, handle_offer(Offer2, self())),
    ?assertEqual(ok, handle_offer(Offer2, self())),
    ?assertEqual(ok, handle_offer(Offer2, self())),
    ?assertEqual(ok, handle_offer(Offer2, self())),
    ?assertEqual(ok, handle_offer(Offer2, self())),
    ?assertEqual({error, ?MB_MAX_PACKET}, handle_offer(Offer2, self())),

    %% Accept Unlimited Packets
    {Offer3, PHash3} = NewOffer(<<"paylaod3">>),
    ok = ?MODULE:accept_more(PHash3, ?MB_UNLIMITED),
    ?assertEqual(ok, handle_offer(Offer3, self())),
    ?assertEqual(ok, handle_offer(Offer3, self())),
    ?assertEqual(ok, handle_offer(Offer3, self())),
    %% exceeding PACKET_MAX
    ?assertEqual(ok, handle_offer(Offer3, self())),
    ?assertEqual(ok, handle_offer(Offer3, self())),
    ?assertEqual(ok, handle_offer(Offer3, self())),
    ?assertEqual(ok, handle_offer(Offer3, self())),
    ?assertEqual(ok, handle_offer(Offer3, self())),

    gen_server:stop(Pid),
    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain),
    ?assert(meck:validate(blockchain_ledger_v1)),
    meck:unload(blockchain_ledger_v1),
    ?assert(meck:validate(blockchain_ledger_routing_v1)),
    meck:unload(blockchain_ledger_routing_v1),
    ?assert(meck:validate(router_metrics)),
    meck:unload(router_metrics),
    ?assert(meck:validate(router_device_devaddr)),
    meck:unload(router_device_devaddr),
    ?assert(meck:validate(router_console_dc_tracker)),
    meck:unload(router_console_dc_tracker),
    ets:delete(?ETS),
    ets:delete(?BF_ETS),
    ets:delete(?MB_ETS),
    ets:delete(?REPLAY_ETS),
    ets:delete(router_devices_ets),
    ets:delete(router_device_cache_ets),
    ok.

-endif.
