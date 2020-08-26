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
         deny_more/1, accept_more/2]).

-define(ETS, router_devices_routing_ets).
-define(BITS_23, 8388607). %% biggest unsigned number in 23 bits
-define(ETS_FUN(Hash), [{{Hash,'$1','$2'},
                         [{'<','$2','$1'}],
                         [{{Hash,'$1',{'+','$2',1}}}]}]).
-define(BUY_JOIN_MAX, 5).
-define(BUY_JOIN_TIMEOUT, timer:seconds(2)).

-spec init() -> ok.
init() ->
    ok.

-spec handle_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
handle_offer(Offer, HandlerPid) ->
    %% TODO: Replace this with getter
    Resp = case blockchain_state_channel_offer_v1:routing(Offer) of
               #routing_information_pb{data={eui, _}} ->
                   join_offer(Offer, HandlerPid);
               #routing_information_pb{data={devaddr, _}} ->
                   packet_offer(Offer, HandlerPid)
           end,
    PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),
    {ok, AName} = blockchain_utils:addr2name(PubKeyBin),
    lager:debug("offer (~p): ~p, from: ~p", [Resp, Offer, AName]),
    Resp.

-spec handle_packet(blockchain_state_channel_packet_v1:packet() | blockchain_state_channel_v1:packet_pb(),
                    pos_integer(),
                    libp2p_crypto:pubkey_bin() | pid()) -> ok | {error, any()}.
handle_packet(SCPacket, PacketTime, Pid) when is_pid(Pid) ->
    PubKeyBin = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    {ok, AName} = blockchain_utils:addr2name(PubKeyBin),
    lager:debug("Packet: ~p, from: ~p", [SCPacket, AName]),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    Region = blockchain_state_channel_packet_v1:region(SCPacket),
    case packet(Packet, PacketTime, PubKeyBin, Region, Pid) of
        {error, _Reason}=E ->
            lager:info("failed to handle sc packet ~p : ~p", [Packet, _Reason]),
            E;
        ok ->
            ok
    end;
handle_packet(Packet, PacketTime, PubKeyBin) ->
    %% TODO - come back to this, defaulting to US915 here.  Need to verify what packets are being handled here
    case packet(Packet, PacketTime, PubKeyBin, 'US915', self()) of
        {error, _Reason}=E ->
            lager:info("failed to handle packet ~p : ~p", [Packet, _Reason]),
            E;
        ok ->
            ok
    end.

deny_more(Packet) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    true = ets:insert(?ETS, {PHash, 0, -1}),
    ok.

accept_more(Packet, N) ->
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    true = ets:insert(?ETS, {PHash, N, 1}),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec join_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
join_offer(Offer, _Pid) ->
    %% TODO: Replace this with getter
    #routing_information_pb{data={eui, #eui_pb{deveui=DevEUI0, appeui=AppEUI0}}} = blockchain_state_channel_offer_v1:routing(Offer),
    DevEUI1 = eui_to_bin(DevEUI0),
    AppEUI1 = eui_to_bin(AppEUI0),
    case router_device_api:get_devices(DevEUI1, AppEUI1) of
        {error, _Reason} ->
            lager:debug("did not find any device matching ~p/~p", [{DevEUI1, DevEUI0}, {AppEUI1, AppEUI0}]),
            {error, unknown_device};
        {ok, Devices} ->
            lager:debug("found devices ~p matching ~p/~p", [[router_device:id(D) || D <- Devices], DevEUI1, AppEUI1]),
            maybe_buy_join_offer(Offer, Devices)
    end.

-spec packet_offer(blockchain_state_channel_offer_v1:offer(), pid()) -> ok | {error, any()}.
packet_offer(Offer, Pid) ->
    #routing_information_pb{data={devaddr, DevAddr}} = blockchain_state_channel_offer_v1:routing(Offer),
    case valid_devaddr(DevAddr) of
        {error, _}=Error ->
            Error;
        ok ->
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            case ets:insert_new(?ETS, {PHash, 0, 0}) of
                true ->
                    erlang:spawn(fun() ->
                                         %% TODO: This timer is kind of random
                                         ok = timer:sleep(timer:minutes(1)),
                                         true = ets:delete(?ETS, PHash)
                                 end),
                    ok;
                false ->
                    case ets:lookup(?ETS, PHash) of
                        [{PHash, _Max, -1}] ->
                            {error, already_got_packet};
                        [{PHash, 0, 0}] ->
                            %% TODO: Find something better than sleeping maybe?
                            timer:sleep(25),
                            packet_offer(Offer, Pid);
                        [{PHash, _Max, _Curr}] ->
                            case ets:select_replace(?ETS, ?ETS_FUN(PHash)) of
                                0 -> {error, already_got_enough_packet};
                                1 -> ok
                            end
                    end
            end
    end.

%%%-------------------------------------------------------------------
%% @doc
%% Route packet_pb and figures out if JOIN_REQ or frame packet
%% @end
%%%-------------------------------------------------------------------
-spec packet(blockchain_helium_packet_v1:packet(), pos_integer(), libp2p_crypto:pubkey_bin(), atom(), pid()) -> ok | {error, any()}.
packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary,
                             _DevNonce:2/binary, MIC:4/binary>> = Payload}=Packet, PacketTime, PubKeyBin, Region, Pid) when MType == ?JOIN_REQ ->
    {AppEUI, DevEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    {ok, AName} = blockchain_utils:addr2name(PubKeyBin),
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
            Chain = blockchain_worker:blockchain(),
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

-spec eui_to_bin(undefined | non_neg_integer()) -> binary().
eui_to_bin(undefined) -> <<>>;
eui_to_bin(EUI) -> <<EUI:64/integer-unsigned-big>>.

-spec valid_devaddr(non_neg_integer()) -> ok | {error, any()}.
valid_devaddr(DevAddr) ->
    case <<DevAddr:32/integer-unsigned-little>> of
        <<AddrBase:25/integer-unsigned-little, _DevAddrPrefix:7/integer>> ->
            Chain = blockchain_worker:blockchain(),
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
                            {error, not_in_subnet}
                    end;
                _ ->
                    {error, no_subnet}
            catch
                _:_ ->
                    {error, no_subnet}
            end;
        _ ->
            {error, unknown_device}
    end.

%% -spec router_devaddr(non_neg_integer()) -> ok | {error, any()}.
%% router_devaddr(DevAddr) ->
%%     DefaultDevAddr = router_device_devaddr:default_devaddr(),
%%     case <<DevAddr:32/integer-unsigned-little>> of
%%         DefaultDevAddr ->
%%             ok;
%%         <<AddrBase:25/integer-unsigned-little, _DevAddrPrefix:7/integer>> ->
%%             Chain = blockchain_worker:blockchain(),
%%             OUI = case application:get_env(router, oui, undefined) of
%%                       undefined -> undefined;
%%                       OUI0 when is_list(OUI0) ->
%%                           list_to_integer(OUI0);
%%                       OUI0 ->
%%                           OUI0
%%                   end,
%%             try blockchain_ledger_v1:find_routing(OUI, blockchain:ledger(Chain)) of
%%                 {ok, RoutingEntry} ->
%%                     Subnets = blockchain_ledger_routing_v1:subnets(RoutingEntry),
%%                     case lists:any(fun(Subnet) ->
%%                                            <<Base:25/integer-unsigned-big, Mask:23/integer-unsigned-big>> = Subnet,
%%                                            Size = (((Mask bxor ?BITS_23) bsl 2) + 2#11) + 1,
%%                                            AddrBase >= Base andalso AddrBase < Base + Size
%%                                    end, Subnets) of
%%                         true ->
%%                             ok;
%%                         false ->
%%                             {error, not_in_subnet}
%%                     end;
%%                 _ ->
%%                     {error, no_subnet}
%%             catch
%%                 _:_ ->
%%                     {error, no_subnet}
%%             end;
%%         _ ->
%%             {error, unknown_device}
%%     end.

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

-spec maybe_buy_join_offer(blockchain_state_channel_offer_v1:offer(), [router_device:device()]) -> ok | {error, any()}.
maybe_buy_join_offer(Offer, Devices) ->
    PayloadSize = blockchain_state_channel_offer_v1:payload_size(Offer),
    case check_devices_balance(PayloadSize, Devices) of
        {error, _Reason}=Error ->
            Error;
        ok ->
            PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
            case ets:insert_new(?ETS, {PHash, 0, 0}) of
                true ->
                    erlang:spawn(fun() ->
                                         ok = timer:sleep(?BUY_JOIN_TIMEOUT),
                                         true = ets:delete(?ETS, PHash)
                                 end),
                    true = ets:insert(?ETS, {PHash, ?BUY_JOIN_MAX, 1}),
                    ok;
                false ->
                    case ets:select_replace(?ETS, ?ETS_FUN(PHash)) of
                        0 -> {error, already_got_join};
                        1 -> ok
                    end
            end
    end.

%% TODO: This function is not very optimized...
-spec check_devices_balance(non_neg_integer(), [router_device:device()]) -> ok | {error, any()}.
check_devices_balance(PayloadSize, Devices) ->
    Chain = blockchain_worker:blockchain(),
    %% TODO: We should not be picking the first device
    [Device|_] = Devices,
    case router_console_dc_tracker:has_enough_dc(Device, PayloadSize, Chain) of
        {error, _Reason}=Error -> Error;
        {ok, _OrgID, _Balance, _Nonce} -> ok
    end.

-spec lookup(non_neg_integer(), binary()) -> {ok, libp2p_crypto:pubkey_bin()} | {error, not_found}.
lookup(DevAddr, PacketHash) ->
    Key = term_to_binary({DevAddr, PacketHash}),
    case e2qc_nif:get(?ETS, Key) of
        notfound -> {error, not_found};
        ValBin -> {ok, bin_to_val(ValBin)}
    end.

-spec bin_to_val(binary()) -> term().
bin_to_val(<<1, V/binary>>) ->
    V;
bin_to_val(<<2, V/binary>>) ->
    binary_to_term(V).

-spec insert(non_neg_integer(), binary(), libp2p_crypto:pubkey_bin()) -> ok.
insert(DevAddr, PacketHash, PubKeyBin) ->
    Key = {DevAddr, PacketHash},
    e2qc:cache(?ETS, Key, 1, fun() -> PubKeyBin end),
    ok.


%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

handle_join_offer_test() ->
    ok = init(),

    meck:new(router_device_api, [passthrough]),
    meck:expect(router_device_api, get_devices, fun(_, _) -> {ok, [device]} end),
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> chain end),
    meck:new(router_console_dc_tracker, [passthrough]),
    meck:expect(router_console_dc_tracker, has_enough_dc, fun(_, _, _) -> {ok, orgid, 0, 1} end),

    JoinPacket = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
    JoinOffer = blockchain_state_channel_offer_v1:from_packet(JoinPacket, <<"hotspot">>, 'REGION'),

    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual(ok, handle_offer(JoinOffer, self())),
    ?assertEqual({error, already_got_join}, handle_offer(JoinOffer, self())),

    ok = timer:sleep(?BUY_JOIN_TIMEOUT + 5),

    ?assertEqual(ok, handle_offer(JoinOffer, self())),

    ?assert(meck:validate(router_device_api)),
    meck:unload(router_device_api),
    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(router_console_dc_tracker)),
    meck:unload(router_console_dc_tracker),

    ets:delete(?ETS),
    ok.


handle_packet_offer_test() ->
    ok = init(),

    Subnet = <<0,0,0,127,255,0>>,
    <<Base:25/integer-unsigned-big, _Mask:23/integer-unsigned-big>> = Subnet,
    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    <<DevAddr:32/integer-unsigned-little>> = <<Base:25/integer-unsigned-little, DevAddrPrefix:7/integer>>,

    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> chain end),
    meck:new(blockchain, [passthrough]),
    meck:expect(blockchain, ledger, fun(_) -> ledger end),
    meck:new(blockchain_ledger_v1, [passthrough]),
    meck:expect(blockchain_ledger_v1, find_routing, fun(_, _) -> {ok, entry} end),
    meck:new(blockchain_ledger_routing_v1, [passthrough]),
    meck:expect(blockchain_ledger_routing_v1, subnets, fun(_) -> [Subnet] end),

    <<PacketDevAddr:32/integer-unsigned-little>> = DevAddr,
    Packet = blockchain_helium_packet_v1:new({devaddr, PacketDevAddr}, <<"payload">>),
    Offer = blockchain_state_channel_offer_v1:from_packet(Packet, <<"hotspot">>, 'REGION'),
    ?assertEqual(ok, handle_offer(Offer, self())),
    ?assertEqual({ok, <<"hotspot">>}, lookup(DevAddr, blockchain_state_channel_offer_v1:packet_hash(Offer))),
    %% the cache'a timing is a bit loose
    ok = timer:sleep(1800),
    ?assertEqual({error, not_found}, lookup(DevAddr, blockchain_state_channel_offer_v1:packet_hash(Offer))),

    ?assert(meck:validate(router_device_devaddr)),
    meck:unload(router_device_devaddr),

    e2qc:teardown(?ETS),
    ok.

-endif.
