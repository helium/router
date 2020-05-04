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
-define(ETS, router_console_debug_ets).
-define(TOKEN_CACHE_TIME, timer:minutes(10)).
-define(HEADER_JSON, {<<"Content-Type">>, <<"application/json">>}).

-record(state, {endpoint :: binary(),
                secret :: binary(),
                token :: binary(),
                ws :: pid(),
                ws_endpoint :: list()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec get_device(binary()) -> {ok, router_device:device()} | {error, any()}.
get_device(DeviceID) ->
    gen_server:call(?SERVER, {get_device, DeviceID}).

-spec get_devices(DevEui :: binary(), AppEui :: binary()) -> [{binary(), router_device:device()}].
get_devices(DevEui, AppEui) ->
    gen_server:call(?SERVER, {get_devices, DevEui, AppEui}).

-spec get_channels(Device :: router_device:device(), DeviceWorkerPid :: pid()) -> [router_channel:channel()].
get_channels(Device, DeviceWorkerPid) ->
    gen_server:call(?SERVER, {get_channels, Device, DeviceWorkerPid}).

-spec report_status(Device :: router_device:device(), Map :: #{}) -> ok.
report_status(Device, Map) ->
    gen_server:cast(?SERVER, {report_status, Device, Map}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    ets:new(?ETS, [public, named_table, set]),
    Endpoint = maps:get(endpoint, Args),
    WSEndpoint = maps:get(ws_endpoint, Args),
    Secret = maps:get(secret, Args),
    Token = get_token(Endpoint, Secret),
    Pid = start_ws(WSEndpoint, Token),
    _ = erlang:send_after(?TOKEN_CACHE_TIME, self(), refresh_token),
    {ok, #state{endpoint=Endpoint, secret=Secret, token=Token, ws=Pid, ws_endpoint=WSEndpoint}}.

handle_call({get_device, DeviceID}, _From, #state{endpoint=Endpoint,
                                                  token=Token}=State) ->
    Device = router_device:new(DeviceID),
    case get_device_(Endpoint, Token, Device) of
        {error, _Reason}=Error ->
            {reply, Error, State};
        {ok, JSONDevice} ->
            Name = kvc:path([<<"name">>], JSONDevice),
            DevEui = kvc:path([<<"dev_eui">>], JSONDevice),
            AppEui = kvc:path([<<"app_eui">>], JSONDevice),
            Metadata = #{labels => kvc:path([<<"labels">>], JSONDevice)},
            DeviceUpdates = [{name, Name},
                             {dev_eui, lorawan_utils:hex_to_binary(DevEui)},
                             {app_eui, lorawan_utils:hex_to_binary(AppEui)},
                             {metadata, Metadata}],
            {reply, {ok, router_device:update(DeviceUpdates, Device)}, State}
    end;
handle_call({get_devices, DevEui, AppEui}, _From, #state{endpoint=Endpoint,
                                                         token=Token}=State) ->
    Url = <<Endpoint/binary, "/api/router/devices/unknown?dev_eui=", (lorawan_utils:binary_to_hex(DevEui))/binary,
            "&app_eui=", (lorawan_utils:binary_to_hex(AppEui))/binary>>,
    lager:debug("get ~p", [Url]),
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, [with_body, {pool, ?MODULE}]) of
        {ok, 200, _Headers, Body} ->
            Devices = lists:map(
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
                        jsx:decode(Body, [return_maps])),
            {reply, Devices, State};
        _Other ->
            {reply, [], State}
    end;
handle_call({get_channels, Device, DeviceWorkerPid}, _From, #state{endpoint=Endpoint,
                                                                   token=Token}=State) ->
    case get_device_(Endpoint, Token, Device) of
        {error, _Reason} ->
            {reply, [], State};
        {ok, JSON} ->
            Channels0 = kvc:path([<<"channels">>], JSON),
            Channels1 = lists:filtermap(
                          fun(JSONChannel) ->
                                  convert_channel(Device, DeviceWorkerPid, JSONChannel)
                          end,
                          Channels0),
            {reply, Channels1, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({report_status, Device, Map}, #state{endpoint=Endpoint,
                                                 token=Token}=State) ->
    DeviceID = router_device:id(Device),
    Url = <<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
    Category = maps:get(category, Map),
    Channels = maps:get(channels, Map),
    Body0 = #{category => Category,
              description => maps:get(description, Map),
              reported_at => maps:get(reported_at, Map),
              device_id => DeviceID,
              frame_up => router_device:fcnt(Device),
              frame_down => router_device:fcntdown(Device),
              payload_size => maps:get(payload_size, Map),
              port => maps:get(port, Map),
              devaddr => maps:get(devaddr, Map),
              hotspots => maps:get(hotspots, Map),
              channels => [maps:remove(debug, C) ||C <- Channels]},
    DebugLeft = debug_lookup(DeviceID),
    Body1 =
        case DebugLeft > 0 andalso lists:member(Category, [<<"up">>, <<"down">>]) of
            false ->
                Body0;
            true ->
                case DebugLeft-1 =< 0 of
                    false -> debug_insert(DeviceID, DebugLeft-1);
                    true -> debug_delete(DeviceID)
                end,
                B0 = maps:put(payload, maps:get(payload, Map), Body0),
                maps:put(channels, Channels, B0)
        end,
    lager:debug("post ~p to ~p", [Body1, Url]),
    hackney:post(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}, ?HEADER_JSON],
                 jsx:encode(Body1), [with_body, {pool, ?MODULE}]),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({'EXIT', _Pid, normal}, #state{token=Token, ws_endpoint=WSEndpoint}=State) ->
    lager:info("websocket connetion went down normally restarting"),
    Pid = start_ws(WSEndpoint, Token),
    {noreply, State#state{ws=Pid}};
handle_info({'EXIT', _Pid, _Reason}, #state{token=Token, ws_endpoint=WSEndpoint}=State) ->
    lager:error("websocket connetion went down: ~p, restarting", [_Reason]),
    Pid = start_ws(WSEndpoint, Token),
    {noreply, State#state{ws=Pid}};
handle_info(refresh_token, #state{endpoint=Endpoint, secret=Secret, ws=Pid}=State) ->
    Token = get_token(Endpoint, Secret),
    Pid ! close,
    _ = erlang:send_after(?TOKEN_CACHE_TIME, self(), refresh_token),
    {noreply, State#state{token=Token}};
handle_info({ws_message, <<"device:all">>, <<"device:all:debug:devices">>, #{<<"devices">> := DeviceIDs}}, State) ->
    lager:info("turning debug on for devices ~p", [DeviceIDs]),
    lists:foreach(fun(DeviceID) ->
                          ok = debug_insert(DeviceID, 10)
                  end,
                  DeviceIDs),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_ws(binary(), binary()) -> pid().
start_ws(WSEndpoint, Token) ->
    Url = binary_to_list(<<WSEndpoint/binary, "?token=", Token/binary, "&vsn=2.0.0">>),
    {ok, Pid} = router_console_ws_handler:start_link(#{url => Url,
                                                       auto_join => [<<"device:all">>],
                                                       forward => self()}),
    Pid.

-spec convert_channel(router_device:device(), pid(), map()) -> false | {true, router_channel:channel()}.
convert_channel(Device, Pid, #{<<"type">> := <<"http">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_http_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{url =>  kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             headers => maps:to_list(kvc:path([<<"credentials">>, <<"headers">>], JSONChannel)),
             method => list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], JSONChannel)))},
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder),
    {true, Channel};
convert_channel(Device, Pid, #{<<"type">> := <<"mqtt">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_mqtt_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{endpoint => kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder),
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
    Decoder = convert_decoder(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder),
    {true, Channel};
convert_channel(Device, Pid, #{<<"type">> := <<"console">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_console_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, #{}, DeviceID, Pid, Decoder),
    {true, Channel};
convert_channel(_Device, _Pid, _Channel) ->
    false.

-spec convert_decoder(map()) -> undefined | router_decoder:decoder().
convert_decoder(JSONChannel) ->
    case kvc:path([<<"function">>], JSONChannel, undefined) of
        undefined ->
            undefined;
        JSONDecoder ->
            case kvc:path([<<"active">>], JSONDecoder, false) of
                false ->
                    undefined;
                true ->
                    case kvc:path([<<"format">>], JSONDecoder, undefined) of
                        <<"custom">> ->
                            router_decoder:new(kvc:path([<<"id">>], JSONDecoder),
                                               custom,
                                               #{function => kvc:path([<<"body">>], JSONDecoder)});
                        _ ->
                            undefined
                    end
            end
    end.

-spec get_token(binary(), binary()) -> binary().
get_token(Endpoint, Secret) ->
    case hackney:post(<<Endpoint/binary, "/api/router/sessions">>, [?HEADER_JSON],
                      jsx:encode(#{secret => Secret}) , [with_body, {pool, ?MODULE}]) of
        {ok, 201, _Headers, Body} ->
            #{<<"jwt">> := Token} = jsx:decode(Body, [return_maps]),
            Token
    end.

-spec get_device_(binary(), binary(), router_device:device()) -> {ok, map()} | {error, any()}.
get_device_(Endpoint, Token, Device) ->
    DeviceId = router_device:id(Device),
    Url = <<Endpoint/binary, "/api/router/devices/", DeviceId/binary>>,
    lager:debug("get ~p", [Url]),
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, [with_body, {pool, ?MODULE}]) of
        {ok, 200, _Headers, Body} ->
            lager:info("Body for ~p ~p", [Url, Body]),
            {ok, jsx:decode(Body, [return_maps])};
        _Other ->
            {error, {get_device_failed, _Other}}
    end.


-spec debug_lookup(binary()) -> integer().
debug_lookup(DeviceID) ->
    case ets:lookup(?ETS, DeviceID) of
        [] -> 0;
        [{DeviceID, Limit}] -> Limit
    end.

-spec debug_insert(binary(), integer()) -> ok.
debug_insert(DeviceID, Limit) ->
    true = ets:insert(?ETS, {DeviceID, Limit}),
    ok.

-spec debug_delete(binary()) -> ok.
debug_delete(DeviceID) ->
    true = ets:delete(?ETS, DeviceID),
    ok.
