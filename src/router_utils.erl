-module(router_utils).

-include("lorawan_vars.hrl").
-include("router_device_worker.hrl").

-export([
    event_join_request/7,
    event_join_accept/5,
    event_uplink/8,
    event_uplink_dropped/4,
    event_downlink/10,
    event_downlink_dropped/5,
    event_downlink_queued/5,
    event_uplink_integration_req/6,
    event_uplink_integration_res/6,
    event_misc_integration_error/3,
    uuid_v4/0,
    get_router_oui/1,
    get_hotspot_location/2,
    to_bin/1,
    b0/4,
    format_hotspot/6,
    lager_md/1,
    trace/1,
    stop_trace/1,
    maybe_update_trace/1,
    get_oui/0,
    mtype_to_ack/1,
    frame_timeout/0,
    join_timeout/0
]).

-type uuid_v4() :: binary().

-export_type([uuid_v4/0]).

event_join_request(ID, Timestamp, Device, Chain, PubKeyBin, Packet, Region) ->
    DevEUI = router_device:dev_eui(Device),
    AppEUI = router_device:app_eui(Device),
    Map = #{
        id => ID,
        category => join_request,
        sub_category => undefined,
        description =>
            <<"Join request from AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary,
                " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
        reported_at => Timestamp,
        fcnt => 0,
        payload_size => 0,
        payload => <<>>,
        port => 0,
        devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
        hotspot => format_hotspot(Chain, PubKeyBin, Packet, Region)
    },
    ok = router_console_api:event(Device, Map).

event_join_accept(Device, Chain, PubKeyBin, Packet, Region) ->
    DevEUI = router_device:dev_eui(Device),
    AppEUI = router_device:app_eui(Device),
    Map = #{
        id => router_utils:uuid_v4(),
        category => join_accept,
        sub_category => undefined,
        description =>
            <<"Join accept from AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary,
                " DevEUI: ", (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
        reported_at => erlang:system_time(millisecond),
        fcnt => 0,
        payload_size => 0,
        payload => <<>>,
        port => 0,
        devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
        hotspot => format_hotspot(Chain, PubKeyBin, Packet, Region)
    },
    ok = router_console_api:event(Device, Map).

event_uplink(ID, Timestamp, Frame, Device, Chain, PubKeyBin, Packet, Region) ->
    #frame{mtype = MType, devaddr = DevAddr, fport = FPort, fcnt = FCnt, data = Payload} = Frame,
    {SubCategory, Desc} =
        case MType of
            ?CONFIRMED_UP -> {uplink_confirmed, <<"Confirmed data up received">>};
            ?UNCONFIRMED_UP -> {uplink_unconfirmed, <<"Unconfirmed data up received">>}
        end,
    Map = #{
        id => ID,
        category => uplink,
        sub_category => SubCategory,
        description => Desc,
        reported_at => Timestamp,
        fcnt => FCnt,
        payload_size => erlang:byte_size(Payload),
        payload => base64:encode(Payload),
        port => FPort,
        devaddr => lorawan_utils:binary_to_hex(DevAddr),
        hotspot => format_hotspot(Chain, PubKeyBin, Packet, Region)
    },
    ok = router_console_api:event(Device, Map).

event_uplink_dropped(Desc, Timestamp, FCnt, Device) ->
    Map = #{
        id => router_utils:uuid_v4(),
        category => uplink,
        sub_category => uplink_dropped,
        description => Desc,
        reported_at => Timestamp,
        fcnt => FCnt,
        payload_size => 0,
        payload => <<>>,
        port => 0,
        devaddr => router_device:devaddr(Device),
        hotspot => #{}
    },
    ok = router_console_api:event(Device, Map).

event_downlink(
    IsDownlinkAck,
    ConfirmedDown,
    Port,
    Payload,
    Device,
    ChannelMap,
    Chain,
    PubKeyBin,
    Packet,
    Region
) ->
    {SubCategory, Desc} =
        case {IsDownlinkAck, ConfirmedDown} of
            {1, _} -> {downlink_ack, <<"Ack sent">>};
            {_, true} -> {downlink_confirmed, <<"Confirmed data down sent">>};
            {_, false} -> {downlink_unconfirmed, <<"Unconfirmed data down sent">>}
        end,
    Map = #{
        id => router_utils:uuid_v4(),
        category => downlink,
        sub_category => SubCategory,
        description => Desc,
        reported_at => erlang:system_time(millisecond),
        fcnt => router_device:fcntdown(Device),
        payload_size => erlang:byte_size(Payload),
        payload => base64:encode(Payload),
        port => Port,
        devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
        hotspot => format_hotspot(Chain, PubKeyBin, Packet, Region),
        channel_id => maps:get(id, ChannelMap),
        channel_name => maps:get(name, ChannelMap),
        channel_status => <<"success">>
    },
    ok = router_console_api:event(Device, Map).

event_downlink_dropped(Desc, Port, Payload, Device, ChannelMap) ->
    Map = #{
        id => router_utils:uuid_v4(),
        category => downlink,
        sub_category => downlink_dropped,
        description => Desc,
        reported_at => erlang:system_time(millisecond),
        fcnt => router_device:fcntdown(Device),
        payload_size => erlang:byte_size(Payload),
        payload => Payload,
        port => Port,
        devaddr => router_device:devaddr(Device),
        hotspot => #{},
        channel_id => maps:get(id, ChannelMap),
        channel_name => maps:get(name, ChannelMap),
        channel_status => <<"error">>
    },
    ok = router_console_api:event(Device, Map).

event_downlink_queued(Desc, Port, Payload, Device, ChannelMap) ->
    Map = #{
        id => router_utils:uuid_v4(),
        category => downlink,
        sub_category => downlink_queued,
        description => Desc,
        reported_at => erlang:system_time(millisecond),
        fcnt => router_device:fcntdown(Device),
        payload_size => erlang:byte_size(Payload),
        payload => Payload,
        port => Port,
        devaddr => router_device:devaddr(Device),
        hotspot => #{},
        channel_id => maps:get(id, ChannelMap),
        channel_name => maps:get(name, ChannelMap),
        channel_status => <<"success">>
    },
    ok = router_console_api:event(Device, Map).

-spec event_uplink_integration_req(
    UUID :: uuid_v4(),
    Device :: router_device:device(),
    Status :: success | error,
    Description :: binary(),
    Request :: map(),
    ChannelInfo :: map()
) -> ok.
event_uplink_integration_req(UUID, Device, Status, Description, Request, ChannelInfo) ->
    Map = #{
        id => UUID,
        category => uplink,
        sub_category => uplink_integration_res,
        status => Status,
        description => Description,
        reported_at => erlang:system_time(millisecond),
        %%
        channel_id => maps:get(id, ChannelInfo),
        channel_name => maps:get(name, ChannelInfo),
        request => Request
    },
    ok = router_console_api:event(Device, Map).

-spec event_uplink_integration_res(
    UUID :: uuid_v4(),
    Device :: router_device:device(),
    Description :: binary(),
    Status :: success | error,
    Response :: map(),
    ChannelInfo :: map()
) -> ok.
event_uplink_integration_res(UUID, Device, Description, Status, Response, ChannelInfo) ->
    Map = #{
        id => UUID,
        category => uplink,
        sub_category => uplink_integration_res,
        status => Status,
        description => Description,
        reported_at => erlang:system_time(millisecond),
        %%
        channel_id => maps:get(id, ChannelInfo),
        channel_name => maps:get(name, ChannelInfo),
        channel_status => maps:get(status, ChannelInfo),
        response => Response
    },
    ok = router_console_api:event(Device, Map).

event_misc_integration_error(Device, Description, ChannelInfo) ->
    Map = #{
        id => uuid_v4(),
        category => misc,
        sub_category => misc_integration_error,
        status => error,
        description => Description,
        reported_at => erlang:system_time(millisecond),
        %%
        channel_id => maps:get(id, ChannelInfo),
        channel_name => maps:get(name, ChannelInfo),
        channel_status => maps:get(status, ChannelInfo)
    },
    ok = router_console_api:event(Device, Map).

format_hotspot(Chain, PubKeyBin, Packet, Region) ->
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    HotspotName = blockchain_utils:addr2name(PubKeyBin),
    Freq = blockchain_helium_packet_v1:frequency(Packet),
    {Lat, Long} = router_utils:get_hotspot_location(PubKeyBin, Chain),
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

%% quoted from https://github.com/afiskon/erlang-uuid-v4/blob/master/src/uuid.erl
%% MIT License
-spec uuid_v4() -> uuid_v4().
uuid_v4() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    Str = io_lib:format(
        "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]
    ),
    list_to_binary(Str).

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

-spec get_oui() -> undefined | non_neg_integer().
get_oui() ->
    case application:get_env(router, oui, undefined) of
        undefined ->
            undefined;
        %% app env comes in as a string
        OUI0 when is_list(OUI0) ->
            erlang:list_to_integer(OUI0);
        OUI0 ->
            OUI0
    end.

-spec mtype_to_ack(integer()) -> 0 | 1.
mtype_to_ack(?CONFIRMED_UP) -> 1;
mtype_to_ack(_) -> 0.

-spec frame_timeout() -> non_neg_integer().
frame_timeout() ->
    case application:get_env(router, frame_timeout, ?FRAME_TIMEOUT) of
        [] -> ?FRAME_TIMEOUT;
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        I -> I
    end.

-spec join_timeout() -> non_neg_integer().
join_timeout() ->
    case application:get_env(router, join_timeout, ?JOIN_TIMEOUT) of
        [] -> ?JOIN_TIMEOUT;
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        I -> I
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
    case router_utils:get_oui() of
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
