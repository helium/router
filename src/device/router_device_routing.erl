%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Routing ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_routing).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include("lorawan_vars.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([init/0,
         handle_offer/2, handle_packet/3,
         deny_more/1, accept_more/1, clear_multi_buy/1,
         allow_replay/3, clear_replay/1]).

-define(BITS_23, 8388607). %% biggest unsigned number in 23 bits

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

%% Multi Buy
-define(MB_ETS, router_device_routing_mb_ets).
-define(MB_FUN(Hash), [{{Hash,'$1','$2'},
                        [{'<','$2','$1'}],
                        [{{Hash,'$1',{'+','$2',1}}}]}]).
-define(MB_MAX_PACKET, multi_buy_max_packet).
-define(MB_TOO_MANY_ATTEMPTS, multi_buy_too_many_attempts).
-define(MB_DENY_MORE, multi_buy_deny_more).

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
    {ok, BloomJoinRef} = bloom:new_forgetful(?BF_BITMAP_SIZE, ?BF_UNIQ_CLIENTS_MAX,
                                             ?BF_FILTERS_MAX, ?BF_ROTATE_AFTER),
    true = ets:insert(?BF_ETS, {?BF_KEY, BloomJoinRef}),
    ok.

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
handle_offer(Offer, HandlerPid) ->
    Start = erlang:system_time(millisecond),
    Routing = blockchain_state_channel_offer_v1:routing(Offer),
    Resp = case Routing of
               #routing_information_pb{data={eui, _EUI}} ->
                   join_offer(Offer, HandlerPid);
               #routing_information_pb{data={devaddr, _DevAddr}} ->
                   packet_offer(Offer, HandlerPid)
           end,
    End = erlang:system_time(millisecond),
    erlang:spawn(fun() ->
                         ok = router_metrics:packet_observe_start(blockchain_state_channel_offer_v1:packet_hash(Offer),
                                                                  blockchain_state_channel_offer_v1:hotspot(Offer),
                                                                  Start),
                         ok = print_offer_resp(Offer, HandlerPid, Resp),
                         ok = handle_offer_metrics(Routing, Resp, End-Start)
                 end),
    Resp.

-spec handle_packet(blockchain_state_channel_packet_v1:packet() | blockchain_state_channel_v1:packet_pb(),
                    pos_integer(),
                    libp2p_crypto:pubkey_bin() | pid()) -> ok | {error, any()}.
handle_packet(SCPacket, PacketTime, Pid) when is_pid(Pid) ->
    Start = erlang:system_time(millisecond),
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    AName = blockchain_utils:addr2name(PubKeyBin),
    lager:debug("Packet: ~p, from: ~p", [SCPacket, AName]),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    case packet(Packet, PacketTime, PubKeyBin, Region, Pid) of
        {error, Reason}=E ->
            lager:info("failed to handle sc packet ~p : ~p", [Packet, Reason]),
            ok = handle_packet_metrics(Packet, reason_to_single_atom(Reason), Start),
            E;
        ok ->
            ok = router_metrics:routing_packet_observe_start(blockchain_helium_packet_v1:packet_hash(Packet),
                                                             PubKeyBin,
                                                             Start),
            ok
    end;
handle_packet(Packet, PacketTime, PubKeyBin) ->
    %% TODO - come back to this, defaulting to US915 here.  Need to verify what packets are being handled here
    Start = erlang:system_time(millisecond),
    case packet(Packet, PacketTime, PubKeyBin, 'US915', self()) of
        {error, Reason}=E ->
            lager:info("failed to handle packet ~p : ~p", [Packet, Reason]),
            ok = handle_packet_metrics(Packet, reason_to_single_atom(Reason), Start),
            E;
        ok ->
            ok = router_metrics:routing_packet_observe_start(blockchain_helium_packet_v1:packet_hash(Packet),
                                                             PubKeyBin,
                                                             Start),
            ok
    end.

-spec deny_more(blockchain_helium_packet_v1:packet()) -> ok.
deny_more(Packet) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    case ets:lookup(?MB_ETS, PHash) of
        [{PHash, 0, -1}] ->
            ok;
        _ ->
            true = ets:insert(?MB_ETS, {PHash, 0, -1}),
            ok
    end.

-spec accept_more(blockchain_helium_packet_v1:packet()) -> ok.
accept_more(Packet) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    case ets:lookup(?MB_ETS, PHash) of
        [{PHash, ?PACKET_MAX, _}] ->
            ok;
        _ ->
            true = ets:insert(?MB_ETS, {PHash, ?PACKET_MAX, 1}),
            ok
    end.

-spec clear_multi_buy(blockchain_helium_packet_v1:packet()) -> ok.
clear_multi_buy(Packet) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    true = ets:delete(?MB_ETS, PHash),
    ok.

-spec allow_replay(blockchain_helium_packet_v1:packet(), binary(), non_neg_integer()) -> ok.
allow_replay(Packet, DeviceID, PacketTime) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    true = ets:insert(?REPLAY_ETS, {PHash, DeviceID, PacketTime}),
    ok.

-spec clear_replay(binary()) -> ok.
clear_replay(DeviceID) ->
    true = ets:match_delete(?REPLAY_ETS, {'_', DeviceID, '_'}),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

print_offer_resp(Offer, HandlerPid, Resp) ->
    Routing = blockchain_state_channel_offer_v1:routing(Offer),
    Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
    HotspotName = blockchain_utils:addr2name(Hotspot),
    case Routing of
        #routing_information_pb{data={eui, #eui_pb{deveui=DevEUI0, appeui=AppEUI0}}} ->
            DevEUI1 = lorawan_utils:binary_to_hex(eui_to_bin(DevEUI0)),
            AppEUI1 = lorawan_utils:binary_to_hex(eui_to_bin(AppEUI0)),
            lager:debug("responded ~p to join offer deveui=~s appeui=~s (~p/~p) from: ~p (pid: ~p)",
                        [Resp, DevEUI1, AppEUI1, DevEUI0, AppEUI0, HotspotName, HandlerPid]);
        #routing_information_pb{data={devaddr, DevAddr0}} ->
            DevAddr1 = lorawan_utils:binary_to_hex(lorawan_utils:reverse(devaddr_to_bin(DevAddr0))),
            lager:debug("responded ~p to packet offer devaddr=~s (~p) from: ~p (pid: ~p)",
                        [Resp, DevAddr1, DevAddr0, HotspotName, HandlerPid])
    end.

-spec join_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
join_offer(Offer, _Pid) ->
    %% TODO: Replace this with getter
    #routing_information_pb{data={eui, #eui_pb{deveui=DevEUI0, appeui=AppEUI0}}} = blockchain_state_channel_offer_v1:routing(Offer),
    DevEUI1 = eui_to_bin(DevEUI0),
    AppEUI1 = eui_to_bin(AppEUI0),
    case router_device_api:get_devices(DevEUI1, AppEUI1) of
        {error, _Reason} ->
            lager:debug("did not find any device matching ~p/~p", [{DevEUI1, DevEUI0}, {AppEUI1, AppEUI0}]),
            {error, ?CONSOLE_UNKNOWN_DEVICE};
        {ok, []} ->
            lager:debug("did not find any device matching ~p/~p", [{DevEUI1, DevEUI0}, {AppEUI1, AppEUI0}]),
            {error, ?CONSOLE_UNKNOWN_DEVICE};
        {ok, Devices} ->
            lager:debug("found devices ~p matching ~p/~p", [[router_device:id(D) || D <- Devices], DevEUI1, AppEUI1]),
            maybe_buy_join_offer(Offer, _Pid, Devices)
    end.

-spec maybe_buy_join_offer(blockchain_state_channel_offer_v1:offer(), pid(), [router_device:device()]) -> ok | {error, any()}.
maybe_buy_join_offer(Offer, _Pid, Devices) ->
    PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
    case check_device_is_active(Devices) of
        {error, _Reason}=Error ->
            Error;
        ok ->
            case check_device_balance(PayloadSize, Devices) of
                {error, _Reason}=Error ->
                    Error;
                ok ->
                    BFRef = lookup_bf(?BF_KEY),
                    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
                    case bloom:set(BFRef, PHash) of
                        true ->
                            maybe_multi_buy(Offer, 10);
                        false ->
                            true = ets:insert(?MB_ETS, {PHash, ?JOIN_MAX, 1}),
                            ok
                    end
            end
    end.

-spec packet_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
packet_offer(Offer, Pid) ->
    case validate_packet_offer(Offer, Pid) of
        {error, _}=Error ->
            Error;
        ok ->
            BFRef = lookup_bf(?BF_KEY),
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            case bloom:set(BFRef, PHash) of
                true ->
                    case lookup_replay(PHash) of
                        {ok, _DeviceID, PackeTime} ->
                            case erlang:system_time(millisecond) - PackeTime > ?RX2_WINDOW of
                                true ->
                                    %% Buying replay packet
                                    lager:debug("most likely a replay packet for ~p buying", [_DeviceID]),
                                    ok;
                                false ->
                                    %% This is probably a late packet we should still use the multi buy
                                    lager:debug("most likely a late packet for ~p multi buying", [_DeviceID]),
                                    maybe_multi_buy(Offer, 10)
                            end;
                        {error, not_found} ->
                            maybe_multi_buy(Offer, 10)
                    end;
                false ->
                    ok
            end
    end.

-spec validate_packet_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
validate_packet_offer(Offer, _Pid) ->
    #routing_information_pb{data={devaddr, DevAddr0}} = blockchain_state_channel_offer_v1:routing(Offer),
    case validate_devaddr(DevAddr0) of
        {error, _}=Error ->
            Error;
        ok ->
            {ok, DB, [_DefaultCF, CF]} = router_db:get(),
            PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),
            DevAddr1 = lorawan_utils:reverse(devaddr_to_bin(DevAddr0)),
            case router_device_devaddr:sort_devices(router_device:get(DB, CF, filter_device_fun(DevAddr1)), PubKeyBin) of
                [] ->
                    {error, ?DEVADDR_NO_DEVICE};
                Devices ->
                    case check_device_is_active(Devices) of
                        {error, _Reason}=Error ->
                            Error;
                        ok ->
                            PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
                            case check_device_balance(PayloadSize, Devices) of
                                {error, _Reason}=Error -> Error;
                                ok -> ok
                            end
                    end
            end
    end.


-spec validate_devaddr(non_neg_integer()) -> ok | {error, any()}.
validate_devaddr(DevAddr) ->
    case <<DevAddr:32/integer-unsigned-little>> of
        <<AddrBase:25/integer-unsigned-little, _DevAddrPrefix:7/integer>> ->
            Chain = get_chain(),
            OUI = case application:get_env(router, oui, undefined) of
                      undefined -> undefined;
                      OUI0 when is_list(OUI0) ->
                          list_to_integer(OUI0);
                      OUI0 ->
                          OUI0
                  end,
            try blockchain_ledger_v1:find_routing(OUI, blockchain:ledger(Chain)) of
                {ok, RoutingEntry} ->
                    Subnets = blockchain_ledger_routing_v1:subnets(RoutingEntry),
                    case lists:any(fun(Subnet) ->
                                           <<Base:25/integer-unsigned-big, Mask:23/integer-unsigned-big>> = Subnet,
                                           Size = (((Mask bxor ?BITS_23) bsl 2) + 2#11) + 1,
                                           AddrBase >= Base andalso AddrBase < Base + Size
                                   end, Subnets) of
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

-spec maybe_multi_buy(blockchain_state_channel_offer_v1:offer(), non_neg_integer()) -> ok | {error, any()}.
%% Handle an issue with worker (so we dont stay lin a loop)
maybe_multi_buy(_Offer, 0) ->
    {error, ?MB_TOO_MANY_ATTEMPTS};
maybe_multi_buy(Offer, Attempts) ->
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    case ets:lookup(?MB_ETS, PHash) of
        [] ->
            timer:sleep(25),
            maybe_multi_buy(Offer, Attempts-1);
        [{PHash, 0, -1}] ->
            {error, ?MB_DENY_MORE};
        [{PHash, Max, Curr}] when Max == Curr ->
            {error, ?MB_MAX_PACKET};
        [{PHash, _Max, _Curr}] ->
            case ets:select_replace(?MB_ETS, ?MB_FUN(PHash)) of
                0 -> {error, ?MB_MAX_PACKET};
                1 -> ok
            end
    end.

-spec check_device_is_active([router_device:device()]) -> ok | {error, any()}.
check_device_is_active(Devices) ->
    [Device|_] = Devices,
    case router_device:is_active(Device) of
        false ->
            ok = router_device_utils:report_status_inactive(Device),
            {error, ?DEVICE_INACTIVE};
        true ->
            ok
    end.

%% TODO: This function is not very optimized...
-spec check_device_balance(non_neg_integer(), [router_device:device()]) -> ok | {error, any()}.
check_device_balance(PayloadSize, Devices) ->
    Chain = get_chain(),
    [Device|_] = Devices,
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
-spec packet(blockchain_helium_packet_v1:packet(), pos_integer(), libp2p_crypto:pubkey_bin(), atom(), pid()) -> ok | {error, any()}.
packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                             _DevNonce:2/binary, MIC:4/binary>> = Payload}=Packet, PacketTime, PubKeyBin, Region, Pid) when MType == ?JOIN_REQ ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    AName = blockchain_utils:addr2name(PubKeyBin),
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload)-4}),
    case router_device_api:get_device(DevEUI, AppEUI, Msg, MIC) of
        {ok, APIDevice, AppKey} ->
            DeviceID = router_device:id(APIDevice),
            case maybe_start_worker(DeviceID) of
                {error, _Reason}=Error ->
                    Error;
                {ok, WorkerPid} ->
                    router_device_worker:handle_join(WorkerPid, Packet, PacketTime, PubKeyBin, Region, APIDevice, AppKey, Pid)
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
packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, _ADR:1, _ADRACKReq:1,
                             _ACK:1, _RFU:1, FOptsLen:4, FCnt:16/little-unsigned-integer,
                             _FOpts:FOptsLen/binary, PayloadAndMIC/binary>> =Payload}=Packet, PacketTime, PubKeyBin, Region, Pid) ->
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) -4}),
    MIC = binary:part(PayloadAndMIC, {erlang:byte_size(PayloadAndMIC), -4}),
    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    case DevAddr of
        <<AddrBase:25/integer-unsigned-little, DevAddrPrefix:7/integer>> ->
            Chain = get_chain(),
            OUI = case application:get_env(router, oui, undefined) of
                      undefined -> undefined;
                      OUI0 when is_list(OUI0) ->
                          list_to_integer(OUI0);
                      OUI0 ->
                          OUI0
                  end,
            try blockchain_ledger_v1:find_routing(OUI, blockchain:ledger(Chain)) of
                {ok, RoutingEntry} ->
                    Subnets = blockchain_ledger_routing_v1:subnets(RoutingEntry),
                    case lists:any(fun(Subnet) ->
                                           <<Base:25/integer-unsigned-big, Mask:23/integer-unsigned-big>> = Subnet,
                                           Size = (((Mask bxor ?BITS_23) bsl 2) + 2#11) + 1,
                                           AddrBase >= Base andalso AddrBase < Base + Size
                                   end, Subnets) of
                        true ->
                            %% ok device is in one of our subnets
                            find_device(Packet, PacketTime, Pid, PubKeyBin, Region, DevAddr, <<(router_utils:b0(MType band 1, <<DevAddr:4/binary>>, FCnt, erlang:byte_size(Msg)))/binary, Msg/binary>>, MIC);
                        false ->
                            {error, {unknown_device, DevAddr}}
                    end;
                _ ->
                    %% no subnets
                    find_device(Packet, PacketTime, Pid, PubKeyBin, Region, DevAddr, <<(router_utils:b0(MType band 1, <<DevAddr:4/binary>>, FCnt, erlang:byte_size(Msg)))/binary, Msg/binary>>, MIC)
            catch
                _:_ ->
                    %% no subnets
                    find_device(Packet, PacketTime, Pid, PubKeyBin, Region, DevAddr, <<(router_utils:b0(MType band 1, <<DevAddr:4/binary>>, FCnt, erlang:byte_size(Msg)))/binary, Msg/binary>>, MIC)
            end;
        _ ->
            %% wrong devaddr prefix
            {error, {unknown_device, DevAddr}}
    end;
packet(#packet_pb{payload=Payload}, _PacketTime, AName, _Region, _Pid) ->
    {error, {bad_packet, lorawan_utils:binary_to_hex(Payload), AName}}.

find_device(Packet, PacketTime, Pid, PubKeyBin, Region, DevAddr, B0, MIC) ->
    {ok, DB, [_DefaultCF, CF]} = router_db:get(),
    Devices = router_device_devaddr:sort_devices(router_device:get(DB, CF, filter_device_fun(DevAddr)), PubKeyBin),
    case get_device_by_mic(DB, CF, B0, MIC, Devices) of
        undefined ->
            {error, {unknown_device, DevAddr}};
        Device ->
            DeviceID = router_device:id(Device),
            case maybe_start_worker(DeviceID) of
                {error, _Reason}=Error ->
                    Error;
                {ok, WorkerPid} ->
                    router_device_worker:handle_frame(WorkerPid, Packet, PacketTime, PubKeyBin, Region, Pid)
            end
    end.

-spec filter_device_fun(binary()) -> function().
filter_device_fun(DevAddr) ->
    fun(Device) ->
            router_device:devaddr(Device) == DevAddr orelse
                router_device_devaddr:default_devaddr() == DevAddr
    end.

-spec get_device_by_mic(rocksdb:db_handle(), rocksdb:cf_handle(), binary(),
                        binary(), [router_device:device()]) -> router_device:device() | undefined.
get_device_by_mic(_DB, _CF, _Bin, _MIC, []) ->
    undefined;
get_device_by_mic(DB, CF, Bin, MIC, [Device|Devices]) ->
    case router_device:nwk_s_key(Device) of
        undefined ->
            DeviceID = router_device:id(Device),
            lager:warning("device ~p did not have a nwk_s_key, deleting", [DeviceID]),
            ok = router_device:delete(DB, CF, DeviceID),
            get_device_by_mic(DB, CF, Bin, MIC, Devices);
        NwkSKey ->
            try
                case crypto:cmac(aes_cbc128, NwkSKey, Bin, 4) of
                    MIC ->
                        Device;
                    _ ->
                        get_device_by_mic(DB, CF, Bin, MIC, Devices)
                end
            catch _:_ ->
                    lager:warning("skipping invalid device ~p", [Device]),
                    get_device_by_mic(DB, CF, Bin, MIC, Devices)
            end
    end.

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
handle_offer_metrics(#routing_information_pb{data={eui, _}}, ok, Time) ->
    ok = router_metrics:routing_offer_observe(join, accepted, accepted, Time);
handle_offer_metrics(#routing_information_pb{data={eui, _}}, {error, Reason}, Time) ->
    ok = router_metrics:routing_offer_observe(join, rejected, Reason, Time);
handle_offer_metrics(#routing_information_pb{data={devaddr, _}}, ok, Time) ->
    ok = router_metrics:routing_offer_observe(packet, accepted, accepted, Time);
handle_offer_metrics(#routing_information_pb{data={devaddr, _}}, {error, Reason}, Time) ->
    ok = router_metrics:routing_offer_observe(packet, rejected, Reason, Time).

-spec reason_to_single_atom(any()) -> any().
reason_to_single_atom(Reason) ->
    case Reason of
        {R, _} -> R;
        {R, _, _} -> R;
        R -> R
    end.

-spec handle_packet_metrics(blockchain_helium_packet_v1:packet(), any(), non_neg_integer()) -> ok.
handle_packet_metrics(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, _AppEUI0:8/binary, _DevEUI0:8/binary,
                                            _DevNonce:2/binary, _MIC:4/binary>>}, Reason, Start) when MType == ?JOIN_REQ  ->
    End = erlang:system_time(millisecond),
    ok = router_metrics:routing_packet_observe(join, rejected, Reason, End-Start);
handle_packet_metrics(_Packet, Reason, Start) ->
    End = erlang:system_time(millisecond),
    ok = router_metrics:routing_packet_observe(packet, rejected, Reason, End-Start).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

multi_buy_test() ->
    ets:new(?MB_ETS, [public, named_table, set]),
    Packet = blockchain_helium_packet_v1:new({devaddr, 16#deadbeef}, <<"payload">>),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),

    ?assertEqual([], ets:lookup(?MB_ETS, PHash)),
    ?assertEqual(ok, deny_more(Packet)),
    ?assertEqual([{PHash, 0, -1}], ets:lookup(?MB_ETS, PHash)),
    ?assertEqual(ok, clear_multi_buy(Packet)),
    ?assertEqual([], ets:lookup(?MB_ETS, PHash)),
    ?assertEqual(ok, accept_more(Packet)),
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
    {ok, BFRef} = bloom:new_forgetful(?BF_BITMAP_SIZE, ?BF_UNIQ_CLIENTS_MAX,
                                      ?BF_FILTERS_MAX, ?BF_ROTATE_AFTER),
    L = lists:foldl(
          fun(I, Acc) ->
                  K = crypto:strong_rand_bytes(32),
                  case bloom:set(BFRef, K) of
                      true -> [I|Acc];
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
    meck:new(router_device_api, [passthrough]),
    meck:expect(router_device_api, get_devices, fun(_, _) -> {ok, [router_device:new(<<"id">>)]} end),
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> chain end),
    meck:new(router_console_dc_tracker, [passthrough]),
    meck:expect(router_console_dc_tracker, has_enough_dc, fun(_, _, _) -> {ok, orgid, 0, 1} end),
    meck:new(router_metrics, [passthrough]),
    meck:expect(router_metrics, routing_offer_observe, fun(_, _, _, _) -> ok end),
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

    ?assert(meck:validate(router_device_api)),
    meck:unload(router_device_api),
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
    application:ensure_all_started(lager),
    {ok, _} = router_devices_sup:start_link(),

    Dir = test_utils:tmp_dir("handle_packet_offer_test"),
    {ok, Pid} = router_db:start_link([Dir]),

    Subnet = <<0,0,0,127,255,0>>,
    <<Base:25/integer-unsigned-big, _Mask:23/integer-unsigned-big>> = Subnet,
    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    <<DevAddr:32/integer-unsigned-little>> = <<Base:25/integer-unsigned-little, DevAddrPrefix:7/integer>>,

    DeviceUpdates = [{devaddr, <<DevAddr:32/integer-unsigned-little>>}],
    Device0 = router_device:new(<<"device_id">>),
    Device1 = router_device:update(DeviceUpdates, Device0),
    {ok, DB, [_DefaultCF, CF]} = router_db:get(),
    {ok, _} = router_device:save(DB, CF, Device1),

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
    meck:new(router_device_devaddr, [passthrough]),
    meck:expect(router_device_devaddr, sort_devices, fun(Devices, _) -> Devices end),
    meck:new(router_console_dc_tracker, [passthrough]),
    meck:expect(router_console_dc_tracker, has_enough_dc, fun(_, _, _) -> {ok, orgid, 0, 1} end),

    Packet0 = blockchain_helium_packet_v1:new({devaddr, DevAddr}, <<"payload0">>),
    Offer0 = blockchain_state_channel_offer_v1:from_packet(Packet0, <<"hotspot">>, 'REGION'),
    ?assertEqual(ok, handle_offer(Offer0, self())),
    ok = ?MODULE:deny_more(Packet0),
    ?assertEqual({error, ?MB_DENY_MORE}, handle_offer(Offer0, self())),
    ?assertEqual({error, ?MB_DENY_MORE}, handle_offer(Offer0, self())),

    Packet1 = blockchain_helium_packet_v1:new({devaddr, DevAddr}, <<"payload1">>),
    Offer1 = blockchain_state_channel_offer_v1:from_packet(Packet1, <<"hotspot">>, 'REGION'),
    ?assertEqual(ok, handle_offer(Offer1, self())),
    ok = ?MODULE:accept_more(Packet1),
    ?assertEqual(ok, handle_offer(Offer1, self())),
    ?assertEqual(ok, handle_offer(Offer1, self())),
    ?assertEqual({error, ?MB_MAX_PACKET}, handle_offer(Offer1, self())),
    ?assertEqual({error, ?MB_MAX_PACKET}, handle_offer(Offer1, self())),

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
    application:stop(lager),
    ok.

-endif.
