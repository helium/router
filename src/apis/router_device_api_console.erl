%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Channels Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_api_console).

-behavior(gen_server).
-behavior(router_device_api_behavior).


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         get_device/1, get_devices/2,
         get_channels/2,
         report_status/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(TOKEN_CACHE_TIME, 600).
-define(HANDLE_DATA_CACHE_TIME, 60).
-define(HEADER_JSON, {<<"Content-Type">>, <<"application/json">>}).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

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
    Url = <<Endpoint/binary, "/api/router/devices/unknown?dev_eui=", (lorawan_utils:binary_to_hex(DevEui))/binary,
            "&app_eui=", (lorawan_utils:binary_to_hex(AppEui))/binary>>,
    lager:debug("get ~p", [Url]),
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body, {pool, ?MODULE}]) of
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

-spec report_status(Device :: router_device:device(), Map :: #{}) -> ok.
report_status(Device, Map) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    DeviceID = router_device:id(Device),
    Url = <<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
    Body = #{category => maps:get(category, Map),
             description => maps:get(description, Map),
             reported_at => maps:get(reported_at, Map),
             device_id => DeviceID,
             frame_up => router_device:fcnt(Device),
             frame_down => router_device:fcntdown(Device),
             payload => maps:get(payload, Map),
             payload_size => maps:get(payload_size, Map),
             port => maps:get(port, Map),
             devaddr => maps:get(devaddr, Map),
             hotspots => maps:get(hotspots, Map),
             channels => maps:get(channels, Map)},
    lager:debug("post ~p to ~p", [Body, Url]),
    hackney:post(Url, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, ?HEADER_JSON],
                 jsx:encode(Body), [with_body, {pool, ?MODULE}]),
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec convert_channel(router_device:device(), pid(), map()) -> false | {true, router_channel:channel()}.
convert_channel(Device, Pid, #{<<"type">> := <<"http">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_http_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{url =>  kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             headers => maps:to_list(kvc:path([<<"credentials">>, <<"headers">>], JSONChannel)),
             method => list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], JSONChannel)))},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid),
    {true, Channel};
convert_channel(Device, Pid, #{<<"type">> := <<"mqtt">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_mqtt_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{endpoint => kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid),
    {true, Channel};
convert_channel(Device, Pid, #{<<"type">> := <<"aws">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_aws_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{aws_access_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_access_key">>], JSONChannel)),
             aws_secret_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_secret_key">>], JSONChannel)),
             aws_region => binary_to_list(kvc:path([<<"credentials">>, <<"aws_region">>], JSONChannel)),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid),
    {true, Channel};
convert_channel(_Device, _Pid, _Channel) ->
    false.

-spec get_token(binary()) -> binary().
get_token(Endpoint) ->
    Secret = get_secret(),
    CacheFun = fun() ->
                       case hackney:post(<<Endpoint/binary, "/api/router/sessions">>, [?HEADER_JSON],
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
    Url = <<Endpoint/binary, "/api/router/devices/", DeviceId/binary>>,
    lager:debug("get ~p", [Url]),
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body, {pool, ?MODULE}]) of
        {ok, 200, _Headers, Body} ->
            lager:info("Body for ~p ~p", [Url, Body]),
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
