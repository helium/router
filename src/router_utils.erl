-module(router_utils).

-export([
    event_uplink/10,
    format_hotspot/4,

    get_router_oui/1,
    get_hotspot_location/2,
    to_bin/1,
    b0/4,
    format_hotspot/6,
    lager_md/1,
    trace/1,
    stop_trace/1,
    maybe_update_trace/1
]).

event_uplink(ID, SubCategory, Desc, Timestamp, FCnt, Payload, Port, Devaddr, Hotspot, Device) ->
    Map = #{
        id => ID,
        category => uplink,
        sub_category => SubCategory,
        description => Desc,
        reported_at => Timestamp,
        fcnt => FCnt,
        payload_size => binary:byte_size(Payload),
        payload => Payload,
        port => Port,
        devaddr => Devaddr,
        hotspot => Hotspot
    },
    ok = router_console_api:event(Device, Map),
    ok.

format_hotspot(Chain, PubKeyBin, Packet, Region) ->
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    HotspotName = blockchain_utils:addr2name(PubKeyBin),
    Freq = blockchain_helium_packet_v1:frequency(Packet),
    {Lat, Long} = ?MODULE:get_hotspot_location(PubKeyBin, Chain),
    #{
        id => erlang:list_to_binary(B58),
        name => erlang:list_to_binary(HotspotName),
        rssi => blockchain_helium_packet_v1:signal_strength(Packet),
        snr => blockchain_helium_packet_v1:snr(Packet),
        spreading => erlang:list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
        frequency => Freq,
        channel => lorawan_mac_region:f2uch(Region, Freq),
        lat => Lat,
        long => Long
    }.

-spec get_router_oui(Chain :: blockchain:blockchain()) -> non_neg_integer() | undefined.
get_router_oui(Chain) ->
    Ledger = blockchain:ledger(Chain),
    PubkeyBin = blockchain_swarm:pubkey_bin(),
    case blockchain_ledger_v1:get_oui_counter(Ledger) of
        {error, _} ->
            undefined;
        {ok, 0} ->
            undefined;
        {ok, _OUICounter} ->
            %% there are some ouis on chain
            find_oui(PubkeyBin, Ledger)
    end.

-spec get_hotspot_location(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Blockchain :: blockchain:blockchain()
) -> {float(), float()} | {unknown, unknown}.
get_hotspot_location(PubKeyBin, Blockchain) ->
    Ledger = blockchain:ledger(Blockchain),
    case blockchain_ledger_v1:find_gateway_info(PubKeyBin, Ledger) of
        {error, _} ->
            {unknown, unknown};
        {ok, Hotspot} ->
            case blockchain_ledger_gateway_v2:location(Hotspot) of
                undefined ->
                    {unknown, unknown};
                Loc ->
                    h3:to_geo(Loc)
            end
    end.

to_bin(Bin) when is_binary(Bin) ->
    Bin;
to_bin(List) when is_list(List) ->
    erlang:list_to_binary(List);
to_bin(_) ->
    <<>>.

-spec b0(integer(), binary(), integer(), integer()) -> binary().
b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0, 0, 0, 0, Dir, DevAddr:4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

-spec format_hotspot(
    blockchain:blockchain(),
    libp2p_crypto:pubkey_bin(),
    blockchain_helium_packet_v1:packet(),
    atom(),
    non_neg_integer(),
    any()
) -> map().
format_hotspot(Chain, PubKeyBin, Packet, Region, Time, Status) ->
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    HotspotName = blockchain_utils:addr2name(PubKeyBin),
    Freq = blockchain_helium_packet_v1:frequency(Packet),
    {Lat, Long} = ?MODULE:get_hotspot_location(PubKeyBin, Chain),
    #{
        id => erlang:list_to_binary(B58),
        name => erlang:list_to_binary(HotspotName),
        reported_at => Time,
        status => Status,
        rssi => blockchain_helium_packet_v1:signal_strength(Packet),
        snr => blockchain_helium_packet_v1:snr(Packet),
        spreading => erlang:list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
        frequency => Freq,
        channel => lorawan_mac_region:f2uch(Region, Freq),
        lat => Lat,
        long => Long
    }.

-spec lager_md(router_device:device()) -> ok.
lager_md(Device) ->
    lager:md([
        {device_id, router_device:id(Device)},
        {app_eui, router_device:app_eui(Device)},
        {dev_eui, router_device:dev_eui(Device)},
        {devaddr, router_device:devaddr(Device)}
    ]).

-spec trace(DeviceID :: binary()) -> ok.
trace(DeviceID) ->
    BinFileName = trace_file(DeviceID),
    {ok, Device} = router_device_cache:get(DeviceID),
    FileName = erlang:binary_to_list(BinFileName) ++ ".log",
    {ok, _} = lager:trace_file(FileName, [{device_id, DeviceID}], debug),
    {ok, _} = lager:trace_file(
        FileName,
        [{module, router_console_api}, {device_id, DeviceID}],
        debug
    ),
    {ok, _} = lager:trace_file(
        FileName,
        [
            {module, router_device_routing},
            {app_eui, router_device:app_eui(Device)},
            {dev_eui, router_device:dev_eui(Device)}
        ],
        debug
    ),
    {ok, _} = lager:trace_file(
        FileName,
        [
            {module, router_device_routing},
            {devaddr, router_device:devaddr(Device)}
        ],
        debug
    ),
    {ok, _} = lager:trace_file(
        FileName,
        [
            {module, router_device_routing},
            {device_id, router_device:id(Device)}
        ],
        debug
    ),
    ok.

-spec stop_trace(DeviceID :: binary()) -> ok.
stop_trace(DeviceID) ->
    DeviceTraces = get_device_traces(DeviceID),
    lists:foreach(
        fun({F, M, L}) ->
            ok = lager:stop_trace(F, M, L)
        end,
        DeviceTraces
    ),
    ok.

-spec maybe_update_trace(DeviceID :: binary()) -> ok.
maybe_update_trace(DeviceID) ->
    case get_device_traces(DeviceID) of
        [] ->
            ok;
        _ ->
            ok = ?MODULE:stop_trace(DeviceID),
            ok = ?MODULE:trace(DeviceID)
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_oui(
    PubkeyBin :: libp2p_crypto:pubkey_bin(),
    Ledger :: blockchain_ledger_v1:ledger()
) -> non_neg_integer() | undefined.

find_oui(PubkeyBin, Ledger) ->
    MyOUIs = blockchain_ledger_v1:find_router_ouis(PubkeyBin, Ledger),
    case router_device_utils:get_router_oui() of
        undefined ->
            %% still check on chain
            case MyOUIs of
                [] -> undefined;
                [OUI] -> OUI;
                [H | _T] -> H
            end;
        OUI ->
            check_oui_on_chain(OUI, MyOUIs)
    end.

-spec check_oui_on_chain(non_neg_integer(), [non_neg_integer()]) -> non_neg_integer() | undefined.
check_oui_on_chain(OUI, OUIsOnChain) ->
    case lists:member(OUI, OUIsOnChain) of
        false ->
            undefined;
        true ->
            OUI
    end.

-spec get_device_traces(DeviceID :: binary()) ->
    list({{lager_file_backend, string()}, list(), atom()}).
get_device_traces(DeviceID) ->
    BinFileName = trace_file(DeviceID),
    Sinks = lists:sort(lager:list_all_sinks()),
    Traces = lists:foldl(
        fun(S, Acc) ->
            {_Level, Traces} = lager_config:get({S, loglevel}),
            Acc ++ lists:map(fun(T) -> {S, T} end, Traces)
        end,
        [],
        Sinks
    ),
    lists:filtermap(
        fun(Trace) ->
            {_Sink, {{_All, Meta}, Level, Backend}} = Trace,
            case Backend of
                {lager_file_backend, File} ->
                    case binary:match(binary:list_to_bin(File), BinFileName) =/= nomatch of
                        false ->
                            false;
                        true ->
                            LevelName =
                                case Level of
                                    {mask, Mask} ->
                                        case lager_util:mask_to_levels(Mask) of
                                            [] -> none;
                                            Levels -> hd(Levels)
                                        end;
                                    Num ->
                                        lager_util:num_to_level(Num)
                                end,
                            {true, {Backend, Meta, LevelName}}
                    end;
                _ ->
                    false
            end
        end,
        Traces
    ).

-spec trace_file(binary()) -> binary().
trace_file(<<BinFileName:5/binary, _/binary>>) ->
    BinFileName.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

trace_test() ->
    application:ensure_all_started(lager),
    application:set_env(lager, log_root, "log"),
    ets:new(router_device_cache_ets, [public, named_table, set]),

    DeviceID = <<"12345678910">>,
    Device = router_device:update(
        [
            {app_eui, <<"app_eui">>},
            {dev_eui, <<"dev_eui">>},
            {devaddr, <<"devaddr">>}
        ],
        router_device:new(DeviceID)
    ),
    {ok, Device} = router_device_cache:save(Device),
    {ok, _} = lager:trace_file("trace_test.log", [{device_id, DeviceID}], debug),

    ok = trace(DeviceID),
    ?assert([] =/= get_device_traces(DeviceID)),

    ok = stop_trace(DeviceID),
    ?assert([] == get_device_traces(DeviceID)),

    ets:delete(router_device_cache_ets),
    application:stop(lager),
    ok.

-endif.
