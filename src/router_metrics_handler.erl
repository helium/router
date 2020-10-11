-module(router_metrics_handler).

-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([handle/2,
         handle_event/3]).

handle(Req, _Args) ->
    handle(Req#req.method, elli_request:path(Req), Req).

%% Expose /metrics for Prometheus to pull
handle('GET', [<<"metrics">>], _Req) ->
    {ok, [], prometheus_text_format:format()};
%% Expose /devaddr to export a list of devices with there location and devaddr
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
handle(_Verb, _Path, _Req) -> ignore.

handle_event(_Event, _Data, _Args) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec csv_format(list(map())) -> list().
csv_format(Devices) ->
    Header = "name,desc,latitude,longitude,color",
    CSV = lists:reverse(lists:foldl(
                          fun(Map, Acc) ->
                                  Name =  erlang:binary_to_list(maps:get(devaddr, Map)) ++ ",",
                                  Desc = "Device name: " ++ erlang:binary_to_list(maps:get(name, Map)) ++ " / Device ID: " ++ erlang:binary_to_list(maps:get(id, Map)) ++
                                      " / Hostspot ID: " ++ erlang:binary_to_list(maps:get(hotspot_id, Map)) ++ " / Hostspot Name: " ++ erlang:binary_to_list(maps:get(hotspot_name, Map)) ++ ",",
                                  Lat = io_lib:format("~.20f", [maps:get(lat, Map)]) ++ ",",
                                  Long = io_lib:format("~.20f", [maps:get(long, Map)]) ++ ",",
                                  Color = "green",
                                  [Name ++ Desc ++ Lat ++ Long ++ Color | Acc]
                          end,
                          [],
                          Devices
                         )),
    LineSep = io_lib:nl(),
    [Header, LineSep, string:join(CSV, LineSep), LineSep].

-spec export_devaddr() -> {ok, list(map())} | {error, binary()}.
export_devaddr() ->
    case blockchain_worker:blockchain() of
        undefined ->
            {error, <<"undefined_blockchain">>};
        Chain ->
            {ok, DB, [_, CF]} = router_db:get(),
            Devices = lists:map(
                        fun(Device) ->
                                {HotspotID, HotspotName, Lat, Long} = get_location_info(Chain, Device),
                                #{id => router_device:id(Device),
                                  name => router_device:name(Device),
                                  devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
                                  hotspot_id => erlang:list_to_binary(HotspotID),
                                  hotspot_name => erlang:list_to_binary(HotspotName),
                                  lat => Lat,
                                  long => Long}
                        end,
                        router_device:get(DB, CF)),
            {ok, Devices}
    end.

-spec get_location_info(blockchain:blockchain(), router_device:device()) -> {list(), list(), float(), float()}.
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

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

export_devaddr_csv_test() ->
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> chain end),
    meck:new(router_utils, [passthrough]),
    meck:expect(router_utils, get_hotspot_location, fun(_, _) -> {1.2, 1.3} end),

    Dir = test_utils:tmp_dir("export_devaddr_csv_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    {ok, DB, [_, CF]} = router_db:get(),
    #{public := Pubkey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(Pubkey),
    DeviceUpdates = [{name, <<"Test Device Name">>},
                     {location, PubKeyBin},
                     {devaddr, <<3,4,0,72>>}],
    Device = router_device:update(DeviceUpdates, router_device:new(<<"test_device_id">>)),
    {ok, _} = router_device:save(DB, CF, Device),

    {ok, Devices} = export_devaddr(),
    Expected = ["name,desc,latitude,longitude,color","\n",
                  "03040048,Device name: Test Device Name / Device ID: test_device_id / Hostspot ID: " ++ libp2p_crypto:bin_to_b58(PubKeyBin) ++ " / Hostspot Name: "++ blockchain_utils:addr2name(PubKeyBin) ++ ",1.19999999999999995559,1.30000000000000004441,green",
                  "\n"],
    Got = csv_format(Devices),
    ?assertEqual(Expected, Got),

    ?assert(meck:validate(router_utils)),
    meck:unload(router_utils),
    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    gen_server:stop(Pid),
    ok.

export_devaddr_test() ->
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> chain end),
    meck:new(router_utils, [passthrough]),
    meck:expect(router_utils, get_hotspot_location, fun(_, _) -> {1.2, 1.3} end),

    Dir = test_utils:tmp_dir("export_devaddr_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    {ok, DB, [_, CF]} = router_db:get(),
    #{public := Pubkey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(Pubkey),
    DeviceUpdates = [{name, <<"Test Device Name">>},
                     {location, PubKeyBin},
                     {devaddr, <<3,4,0,72>>}],
    Device = router_device:update(DeviceUpdates, router_device:new(<<"test_device_id">>)),
    {ok, _} = router_device:save(DB, CF, Device),

    {ok, [Map]} = export_devaddr(),
    ?assertEqual(<<"test_device_id">>, maps:get(id, Map)),
    ?assertEqual(<<"Test Device Name">>, maps:get(name, Map)),
    ?assertEqual(<<"03040048">>, maps:get(devaddr, Map)),
    ?assertEqual(erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)), maps:get(hotspot_id, Map)),
    ?assertEqual(erlang:list_to_binary(blockchain_utils:addr2name(PubKeyBin)), maps:get(hotspot_name, Map)),
    ?assertEqual(1.2, maps:get(lat, Map)),
    ?assertEqual(1.3, maps:get(long, Map)),

    ?assert(meck:validate(router_utils)),
    meck:unload(router_utils),
    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    gen_server:stop(Pid),
    ok.

-endif.
