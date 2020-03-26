-module(router_device_api_console).

-behavior(router_device_api_behavior).

-export([init/1,
         get_device/1, get_devices/2,
         get_channels/2,
         report_device_status/2,
         report_channel_status/2]).

-define(TOKEN_CACHE_TIME, 600).
-define(HANDLE_DATA_CACHE_TIME, 60).

-spec init(Args :: any()) -> ok.
init(_Args) ->
    PoolName = ?MODULE,
    Options = [{timeout, timer:seconds(15)}, {max_connections, 100}],
    ok = hackney_pool:start_pool(PoolName, Options),
    ok.

-spec get_device(binary()) -> {ok, router_device:device()} | {error, any()}.
get_device(DeviceID) ->
    Device = router_device:new(DeviceID),
    case get_device_(Device) of
        {error, _Reason}=Error ->
            Error;
        {ok, JSONDevice} ->
            Name = kvc:path([<<"name">>], JSONDevice),
            DevEui = kvc:path([<<"dev_eui">>], JSONDevice),
            AppEui = kvc:path([<<"app_eui">>], JSONDevice),
            Metadata = #{labels => kvc:path([<<"labels">>], JSONDevice)},
            DeviceUpdates = [{name, Name},
                             {dev_eui, lorawan_utils:hex_to_binary(DevEui)},
                             {app_eui, lorawan_utils:hex_to_binary(AppEui)},
                             {metadata, Metadata}],
            {ok, router_device:update(DeviceUpdates, Device)}
    end.

-spec get_devices(DevEui :: binary(), AppEui :: binary()) -> [{binary(), router_device:device()}].
get_devices(DevEui, AppEui) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    URL = <<Endpoint/binary, "/api/router/devices/unknown?dev_eui=", (lorawan_utils:binary_to_hex(DevEui))/binary,
            "&app_eui=", (lorawan_utils:binary_to_hex(AppEui))/binary>>,
    case hackney:get(URL, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body, {pool, ?MODULE}]) of
        {ok, 200, _Headers, Body} ->
            lists:map(
              fun(JSONDevice) ->
                      ID = kvc:path([<<"id">>], JSONDevice),
                      Name = kvc:path([<<"name">>], JSONDevice),
                      AppKey = lorawan_utils:hex_to_binary(kvc:path([<<"app_key">>], JSONDevice)),
                      Metadata = #{labels => kvc:path([<<"labels">>], JSONDevice)},
                      DeviceUpdates = [{name, Name},
                                       {dev_eui, DevEui},
                                       {app_eui, AppEui},
                                       {metadata, Metadata}],
                      {AppKey, router_device:update(DeviceUpdates, router_device:new(ID))}
              end,
              jsx:decode(Body, [return_maps])
             );
        _Other ->
            []
    end.

-spec get_channels(Device :: router_device:device(), DeviceWorkerPid :: pid()) -> [router_channel:channel()].
get_channels(Device, DeviceWorkerPid) ->
    case get_device_(Device) of
        {error, _Reason} ->
            [];
        {ok, JSON} ->
            Channels = kvc:path([<<"channels">>], JSON),
            lists:filtermap(
              fun(JSONChannel) ->
                      convert_channel(Device, DeviceWorkerPid, JSONChannel)
              end,
              Channels)
    end.

-spec report_device_status(Device :: router_device:device(), Map :: #{}) -> ok.
report_device_status(Device, Map) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    DeviceID = router_device:id(Device),
    Body = #{status => maps:get(status, Map, failure),
             description => maps:get(description, Map, <<"">>),
             reported_at => maps:get(reported_at, Map, erlang:system_time(second)),
             category => maps:get(category, Map, <<"">>),
             frame_up => router_device:fcnt(Device),
             frame_down => router_device:fcntdown(Device),
             hotspot_name => list_to_binary(maps:get(hotspot_name, Map, ""))},
    hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
                 [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}],
                 jsx:encode(Body), [with_body, {pool, ?MODULE}]),
    ok.

-spec report_channel_status(Device :: router_device:device(), Map :: #{}) -> ok.
report_channel_status(Device, Map) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    DeviceID = router_device:id(Device),
    Core = #{status => maps:get(status, Map),
             description => maps:get(description, Map),
             channel_id => maps:get(channel_id, Map),
             channel_name => maps:get(channel_name, Map),
             reported_at => maps:get(reported_at, Map, erlang:system_time(seconds)),
             category => maps:get(category, Map),
             frame_up => router_device:fcnt(Device),
             frame_down => router_device:fcntdown(Device)},
    Body = maps:merge(Core, maps:with([hotspots, payload, payload_size], Map)),
    hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
                 [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}],
                 jsx:encode(Body), [with_body, {pool, ?MODULE}]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec convert_channel(router_device:device(), pid(), map()) -> false | {true, router_channel:channel()}.
convert_channel(Device, DeviceWorkerPid, #{<<"type">> := <<"http">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_http_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{url =>  kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             headers => maps:to_list(kvc:path([<<"credentials">>, <<"headers">>], JSONChannel)),
             method => list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], JSONChannel)))},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, DeviceWorkerPid),
    {true, Channel};
convert_channel(Device, DeviceWorkerPid, #{<<"type">> := <<"mqtt">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_mqtt_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{endpoint => kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, DeviceWorkerPid),
    {true, Channel};
convert_channel(Device, DeviceWorkerPid, #{<<"type">> := <<"aws">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_aws_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{aws_access_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_access_key">>], JSONChannel)),
             aws_secret_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_secret_key">>], JSONChannel)),
             aws_region => binary_to_list(kvc:path([<<"credentials">>, <<"aws_region">>], JSONChannel)),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, DeviceWorkerPid),
    {true, Channel};
convert_channel(_Device, _DeviceWorkerPid, _Channel) ->
    false.

-spec get_token(binary()) -> binary().
get_token(Endpoint) ->
    Secret = get_secret(),
    CacheFun = fun() ->
                       case hackney:post(<<Endpoint/binary, "/api/router/sessions">>, [{<<"Content-Type">>, <<"application/json">>}],
                                         jsx:encode(#{secret => Secret}) , [with_body, {pool, ?MODULE}]) of
                           {ok, 201, _Headers, Body} ->
                               #{<<"jwt">> := JWT} = jsx:decode(Body, [return_maps]),
                               JWT
                       end
               end,
    e2qc:cache(console_cache, jwt, 600, CacheFun).

-spec get_device_(router_device:device()) -> {ok, map()} | {error, any()}.
get_device_(Device) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    DeviceId = router_device:id(Device),
    case hackney:get(<<Endpoint/binary, "/api/router/devices/", DeviceId/binary>>,
                     [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body, {pool, ?MODULE}]) of
        {ok, 200, _Headers, Body} ->
            lager:info("Body for ~p ~p", [<<Endpoint/binary, "/api/router/devices/", DeviceId/binary>>, Body]),
            {ok, jsx:decode(Body, [return_maps])};
        _Other ->
            {error, {get_device_failed, _Other}}
    end.

-spec get_endpoint() -> binary().
get_endpoint() ->
    application:get_env(router, console_endpoint, undefined).

-spec get_secret() -> binary().
get_secret() ->
    application:get_env(router, console_secret, undefined).
