-module(router_metrics_reporter).

-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

-export([
    handle/2,
    handle_event/3
]).

handle(Req, _Args) ->
    handle(Req#req.method, elli_request:path(Req), Req).

%% Expose /metrics for Prometheus to pull
handle('GET', [<<"metrics">>], _Req) ->
    {ok, [], prometheus_text_format:format()};
%% Expose /devaddr to export a list of devices with there location and devaddr (use: https://kepler.gl/demo)
handle('GET', [<<"devaddr">>, <<"json">>], _Req) ->
    case export_devaddr() of
        {ok, Devices} ->
            {ok, [], jsx:encode(Devices)};
        {error, Reason} ->
            {500, [], Reason}
    end;
handle('GET', [<<"devaddr">>, <<"csv">>], _Req) ->
    case export_devaddr() of
        {ok, Devices} ->
            {ok, [], csv_format(Devices)};
        {error, Reason} ->
            {500, [], Reason}
    end;
handle(_Verb, _Path, _Req) ->
    ignore.

handle_event(_Event, _Data, _Args) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec csv_format(list(map())) -> list().
csv_format(Devices) ->
    Header = "name,desc,latitude,longitude,color",
    CSV = lists:reverse(
        lists:foldl(
            fun(Map, Acc) ->
                case maps:is_key(devaddr, Map) of
                    true ->
                        Name = to_list(maps:get(devaddr, Map)) ++ ",",
                        Desc =
                            "Device name: " ++
                                to_list(maps:get(name, Map)) ++
                                " / Device ID: " ++
                                to_list(maps:get(id, Map)) ++
                                " / Hostspot ID: " ++
                                to_list(maps:get(hotspot_id, Map)) ++
                                " / Hostspot Name: " ++ to_list(maps:get(hotspot_name, Map)) ++ ",",
                        Lat = io_lib:format("~.20f", [maps:get(lat, Map)]) ++ ",",
                        Long = io_lib:format("~.20f", [maps:get(long, Map)]) ++ ",",
                        Color = maps:get(color, Map, "green"),
                        [Name ++ Desc ++ Lat ++ Long ++ Color | Acc];
                    false ->
                        Name = to_list(maps:get(hotspot_name, Map)) ++ ",",
                        Desc = "Hostspot ID: " ++ to_list(maps:get(hotspot_id, Map)) ++ ",",
                        Lat = io_lib:format("~.20f", [maps:get(lat, Map)]) ++ ",",
                        Long = io_lib:format("~.20f", [maps:get(long, Map)]) ++ ",",
                        Color = maps:get(color, Map, "blue"),
                        [Name ++ Desc ++ Lat ++ Long ++ Color | Acc]
                end
            end,
            [],
            Devices
        )
    ),
    LineSep = io_lib:nl(),
    [Header, LineSep, string:join(CSV, LineSep), LineSep].

-spec export_devaddr() -> {ok, list(map())} | {error, binary()}.
export_devaddr() ->
    case blockchain_worker:blockchain() of
        undefined ->
            {error, <<"undefined_blockchain">>};
        Chain ->
            Devices = lists:map(
                fun(Device) ->
                    {HotspotID, HotspotName, Lat, Long} = get_location_info(Chain, Device),
                    #{
                        device_id => router_device:id(Device),
                        device_name => router_device:name(Device),
                        device_devaddr => lorawan_utils:binary_to_hex(
                            router_device:devaddr(Device)
                        ),
                        hotspot_id => erlang:list_to_binary(HotspotID),
                        hotspot_name => erlang:list_to_binary(HotspotName),
                        hotspot_lat => Lat,
                        hotspot_long => Long
                    }
                end,
                router_device_cache:get()
            ),
            {ok, Devices}
    end.

-spec get_location_info(blockchain:blockchain(), router_device:device()) ->
    {list(), list(), float(), float()}.
get_location_info(Chain, Device) ->
    case router_device:location(Device) of
        undefined ->
            {"unasserted", "unasserted", 0.0, 0.0};
        PubKeyBin ->
            B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
            HotspotName = blockchain_utils:addr2name(PubKeyBin),
            case router_utils:get_hotspot_location(PubKeyBin, Chain) of
                {unknown, unknown} ->
                    {B58, HotspotName, 0.0, 0.0};
                {Lat, Long} ->
                    {B58, HotspotName, Lat, Long}
            end
    end.

-spec to_list(atom() | binary()) -> list().
to_list(A) when is_atom(A) ->
    erlang:atom_to_list(A);
to_list(B) when is_binary(B) ->
    erlang:binary_to_list(B).
