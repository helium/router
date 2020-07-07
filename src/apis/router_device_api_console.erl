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
         report_status/2,
         get_downlink_url/2,
         get_org/1]).

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
-define(POOL, router_device_api_console_pool).
-define(ETS, router_console_debug_ets).
-define(TOKEN_CACHE_TIME, timer:minutes(10)).
-define(HEADER_JSON, {<<"Content-Type">>, <<"application/json">>}).


-record(state, {endpoint :: binary(),
                secret :: binary(),
                token :: binary(),
                ws :: pid(),
                ws_endpoint :: binary(),
                db :: rocksdb:db_handle(),
                cf :: rocksdb:cf_handle(),
                dc_tracker :: pid()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec get_device(binary()) -> {ok, router_device:device()} | {error, any()}.
get_device(DeviceID) ->
    {Endpoint, Token} = token_lookup(),
    Device = router_device:new(DeviceID),
    case get_device_(Endpoint, Token, Device) of
        {error, _Reason}=Error ->
            Error;
        {ok, JSONDevice} ->
            Name = kvc:path([<<"name">>], JSONDevice),
            DevEui = kvc:path([<<"dev_eui">>], JSONDevice),
            AppEui = kvc:path([<<"app_eui">>], JSONDevice),
            Metadata = #{labels => kvc:path([<<"labels">>], JSONDevice),
                         organization_id => kvc:path([<<"organization_id">>], JSONDevice)},
            DeviceUpdates = [{name, Name},
                             {dev_eui, lorawan_utils:hex_to_binary(DevEui)},
                             {app_eui, lorawan_utils:hex_to_binary(AppEui)},
                             {metadata, Metadata}],
            {ok, router_device:update(DeviceUpdates, Device)}
    end.

-spec get_devices(DevEui :: binary(), AppEui :: binary()) -> [{binary(), router_device:device()}].
get_devices(DevEui, AppEui) ->
    e2qc:cache(router_device_api_console_get_devices, {DevEui, AppEui}, 10,
               fun() ->
                       {Endpoint, Token} = token_lookup(),
                       Url = <<Endpoint/binary, "/api/router/devices/unknown?dev_eui=", (lorawan_utils:binary_to_hex(DevEui))/binary,
                               "&app_eui=", (lorawan_utils:binary_to_hex(AppEui))/binary>>,
                       lager:debug("get ~p", [Url]),
                       Opts = [with_body, {pool, ?POOL}, {connect_timeout, timer:seconds(2)}, {recv_timeout, timer:seconds(2)}],
                       case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, Opts) of
                           {ok, 200, _Headers, Body} ->
                               Devices = lists:map(
                                           fun(JSONDevice) ->
                                                   ID = kvc:path([<<"id">>], JSONDevice),
                                                   Name = kvc:path([<<"name">>], JSONDevice),
                                                   AppKey = lorawan_utils:hex_to_binary(kvc:path([<<"app_key">>], JSONDevice)),
                                                   Metadata = #{labels => kvc:path([<<"labels">>], JSONDevice),
                                                                organization_id => kvc:path([<<"organization_id">>], JSONDevice)},
                                                   DeviceUpdates = [{name, Name},
                                                                    {dev_eui, DevEui},
                                                                    {app_eui, AppEui},
                                                                    {metadata, Metadata}],
                                                   {AppKey, router_device:update(DeviceUpdates, router_device:new(ID))}
                                           end,
                                           jsx:decode(Body, [return_maps])),
                               Devices;
                           _Other ->
                               []
                       end
               end).

-spec get_channels(Device :: router_device:device(), DeviceWorkerPid :: pid()) -> [router_channel:channel()].
get_channels(Device, DeviceWorkerPid) ->
    {Endpoint, Token} = token_lookup(),
    case get_device_(Endpoint, Token, Device) of
        {error, _Reason} ->
            [];
        {ok, JSON} ->
            Channels0 = kvc:path([<<"channels">>], JSON),
            Channels1 = lists:filtermap(
                          fun(JSONChannel) ->
                                  convert_channel(Device, DeviceWorkerPid, JSONChannel)
                          end,
                          Channels0),
            Channels1
    end.

-spec report_status(Device :: router_device:device(), Map :: #{}) -> ok.
report_status(Device, Map) ->
    erlang:spawn(
      fun() ->
              {Endpoint, Token} = token_lookup(),
              DeviceID = router_device:id(Device),
              Url = <<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
              Category = maps:get(category, Map),
              Channels = maps:get(channels, Map),
              FrameUp = maps:get(fcnt, Map, router_device:fcnt(Device)),
              DCMap = case maps:get(dc, Map, undefined) of
                          undefined ->
                              Metadata = router_device:metadata(Device),
                              OrgID = maps:get(organization_id, Metadata, <<>>),
                              {B, N} = router_console_dc_tracker:current_balance(OrgID),
                              #{balance => B, nonce => N};
                          BN ->
                              BN
                      end,
              Body0 = #{category => Category,
                        description => maps:get(description, Map),
                        reported_at => maps:get(reported_at, Map),
                        device_id => DeviceID,
                        frame_up => FrameUp,
                        frame_down => router_device:fcntdown(Device),
                        payload_size => maps:get(payload_size, Map),
                        port => maps:get(port, Map),
                        devaddr => maps:get(devaddr, Map),
                        hotspots => maps:get(hotspots, Map),
                        channels => [maps:remove(debug, C) ||C <- Channels],
                        dc => DCMap},
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
                           jsx:encode(Body1), [with_body, {pool, ?POOL}])
      end),
    ok.

-spec get_downlink_url(router_channel:channel(), binary()) -> binary().
get_downlink_url(Channel, DeviceID) ->
    case maps:get(downlink_token, router_channel:args(Channel), undefined) of
        undefined -> <<>>;
        DownlinkToken ->
            {Endpoint, _Token} = token_lookup(),
            ChannelID = router_channel:id(Channel),
            <<Endpoint/binary, "/api/v1/down/", ChannelID/binary, "/", DownlinkToken/binary, "/", DeviceID/binary>>
    end.

-spec get_org(binary()) -> {ok, map()} | {error, any()}.
get_org(OrgID) ->
    e2qc:cache(router_device_api_console_get_org, OrgID, 300,
               fun() ->
                       {Endpoint, Token} = token_lookup(),
                       Url = <<Endpoint/binary, "/api/router/organizations/", OrgID/binary>>,
                       lager:debug("get ~p", [Url]),
                       Opts = [with_body, {pool, ?POOL}, {connect_timeout, timer:seconds(2)}, {recv_timeout, timer:seconds(2)}],
                       case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, Opts) of
                           {ok, 200, _Headers, Body} ->
                               lager:debug("Body for ~p ~p", [Url, Body]),
                               {ok, jsx:decode(Body, [return_maps])};
                           {ok, 404, _ResponseHeaders, _ResponseBody} ->
                               lager:debug("org ~p not found", [OrgID]),
                               {error, not_found};
                           _Other ->
                               {error, {get_org_failed, _Other}}
                       end
               end).

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    ets:new(?ETS, [public, named_table, set]),
    ok = hackney_pool:start_pool(?POOL, [{timeout, timer:seconds(60)}, {max_connections, 100}]),
    Endpoint = maps:get(endpoint, Args),
    WSEndpoint = maps:get(ws_endpoint, Args),
    Secret = maps:get(secret, Args),
    Token = get_token(Endpoint, Secret),
    WSPid = start_ws(WSEndpoint, Token),
    ok = token_insert(Endpoint, Token),
    {ok, DB, [_, CF]} = router_db:get(),
    _ = erlang:send_after(?TOKEN_CACHE_TIME, self(), refresh_token),
    DCTrackerPid = start_dc_tracker(),
    {ok, #state{endpoint=Endpoint, secret=Secret, token=Token,
                ws=WSPid, ws_endpoint=WSEndpoint, db=DB, cf=CF, dc_tracker=DCTrackerPid}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({'EXIT', WSPid0, _Reason}, #state{token=Token, ws=WSPid0, ws_endpoint=WSEndpoint, db=DB, cf=CF}=State) ->
    lager:error("websocket connetion went down: ~p, restarting", [_Reason]),
    WSPid1 = start_ws(WSEndpoint, Token),
    ok = check_devices(DB, CF),
    {noreply, State#state{ws=WSPid1}};
handle_info({'EXIT', DCTrackerPid0, _Reason}, #state{dc_tracker=DCTrackerPid0}=State) ->
    lager:error("dc tracker went down ~p, restarting", [_Reason]),
    DCTrackerPid1 = start_dc_tracker(),
    {noreply, State#state{dc_tracker=DCTrackerPid1}};
handle_info(refresh_token, #state{endpoint=Endpoint, secret=Secret, ws=Pid}=State) ->
    Token = get_token(Endpoint, Secret),
    Pid ! close,
    _ = erlang:send_after(?TOKEN_CACHE_TIME, self(), refresh_token),
    ok = token_insert(Endpoint, Token),
    {noreply, State#state{token=Token}};
handle_info({ws_message, <<"device:all">>, <<"device:all:debug:devices">>, #{<<"devices">> := DeviceIDs}}, State) ->
    lager:info("turning debug on for devices ~p", [DeviceIDs]),
    lists:foreach(fun(DeviceID) ->
                          ok = debug_insert(DeviceID, 10)
                  end,
                  DeviceIDs),
    {noreply, State};
handle_info({ws_message, <<"device:all">>, <<"device:all:downlink:devices">>, #{<<"devices">> := DeviceIDs,
                                                                                <<"payload">> := BinaryPayload}}, State) ->
    lager:info("sending downlink ~p for devices ~p", [BinaryPayload, DeviceIDs]),
    lists:foreach(fun(DeviceID) ->
                          ok = router_device_channels_worker:handle_downlink(DeviceID, BinaryPayload)
                  end,
                  DeviceIDs),
    {noreply, State};
handle_info({ws_message, <<"device:all">>, <<"device:all:refetch:devices">>, #{<<"devices">> := DeviceIDs}}, #state{db=DB, cf=CF}=State) ->
    ok = update_devices(DB, CF, DeviceIDs),
    {noreply, State};
handle_info({ws_message, <<"organization:all">>, <<"organization:all:refill:dc_balance">>, #{<<"id">> := OrgID,
                                                                                             <<"dc_balance_nonce">> := Nonce,
                                                                                             <<"dc_balance">> := Balance}}, State) ->
    lager:info("got an org balance refill for ~p of ~p (~p)", [OrgID, Balance, Nonce]),
    ok = router_console_dc_tracker:refill(OrgID, Nonce, Balance),
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

-spec update_devices(rocksdb:db_handle(), rocksdb:cf_handle(), [binary()]) -> ok.
update_devices(DB, CF, DeviceIDs) ->
    lager:info("got update for devices: ~p from WS", [DeviceIDs]),
    lists:foreach(
      fun(DeviceID) ->
              case router_devices_sup:lookup_device_worker(DeviceID) of
                  {error, not_found} ->
                      lager:info("device worker not running for device ~p, updating DB record", [DeviceID]),
                      update_device_record(DB, CF, DeviceID);
                  {ok, Pid} ->
                      router_device_worker:device_update(Pid)
              end
      end,
      DeviceIDs).

-spec update_device_record(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> ok.
update_device_record(DB, CF, DeviceID) ->
    case ?MODULE:get_device(DeviceID) of
        {error, _Reason} ->
            lager:warning("failed to get device ~p ~p", [DeviceID, _Reason]);
        {ok, APIDevice} ->
            Device0 =
                case router_device:get_by_id(DB, CF, DeviceID) of
                    {ok, D} -> D;
                    {error, _} -> router_device:new(DeviceID)
                end,
            DeviceUpdates = [{name, router_device:name(APIDevice)},
                             {dev_eui, router_device:dev_eui(APIDevice)},
                             {app_eui, router_device:app_eui(APIDevice)},
                             {metadata, router_device:metadata(APIDevice)}],
            Device = router_device:update(DeviceUpdates, Device0),
            {ok, _} = router_device:save(DB, CF, Device),
            ok
    end.

-spec check_devices(rocksdb:db_handle(), rocksdb:cf_handle()) -> ok.
check_devices(DB, CF) ->
    lager:info("checking all devices in DB"),
    DeviceIDs = [router_device:id(Device) || Device <- router_device:get(DB, CF)],
    update_devices(DB, CF, DeviceIDs).

-spec start_ws(binary(), binary()) -> pid().
start_ws(WSEndpoint, Token) ->
    Url = binary_to_list(<<WSEndpoint/binary, "?token=", Token/binary, "&vsn=2.0.0">>),
    {ok, Pid} = router_console_ws_handler:start_link(#{url => Url,
                                                       auto_join => [<<"device:all">>, <<"organization:all">>],
                                                       forward => self()}),
    Pid.

-spec start_dc_tracker() -> pid().
start_dc_tracker() ->
    {ok, Pid} = router_console_dc_tracker:start_link(#{}),
    Pid.

-spec convert_channel(router_device:device(), pid(), map()) -> false | {true, router_channel:channel()}.
convert_channel(Device, Pid, #{<<"type">> := <<"http">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_http_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{url =>  kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             headers => maps:to_list(kvc:path([<<"credentials">>, <<"headers">>], JSONChannel)),
             method => list_to_existing_atom(binary_to_list(router_utils:to_bin(kvc:path([<<"credentials">>, <<"method">>], JSONChannel)))),
             downlink_token => router_utils:to_bin(kvc:path([<<"downlink_token">>], JSONChannel))},
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
    Args = #{aws_access_key => binary_to_list(router_utils:to_bin(kvc:path([<<"credentials">>, <<"aws_access_key">>], JSONChannel))),
             aws_secret_key => binary_to_list(router_utils:to_bin(kvc:path([<<"credentials">>, <<"aws_secret_key">>], JSONChannel))),
             aws_region => binary_to_list(router_utils:to_bin(kvc:path([<<"credentials">>, <<"aws_region">>], JSONChannel))),
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
                        <<"cayenne">> ->
                            router_decoder:new(kvc:path([<<"id">>], JSONDecoder), cayenne, #{});
                        <<"browan_object_locator">> ->
                            router_decoder:new(kvc:path([<<"id">>], JSONDecoder), browan_object_locator, #{});
                        _ ->
                            undefined
                    end
            end
    end.

-spec get_token(binary(), binary()) -> binary().
get_token(Endpoint, Secret) ->
    case hackney:post(<<Endpoint/binary, "/api/router/sessions">>, [?HEADER_JSON],
                      jsx:encode(#{secret => Secret}) , [with_body, {pool, ?POOL}]) of
        {ok, 201, _Headers, Body} ->
            #{<<"jwt">> := Token} = jsx:decode(Body, [return_maps]),
            Token
    end.

-spec get_device_(binary(), binary(), router_device:device()) -> {ok, map()} | {error, any()}.
get_device_(Endpoint, Token, Device) ->
    DeviceId = router_device:id(Device),
    Url = <<Endpoint/binary, "/api/router/devices/", DeviceId/binary>>,
    lager:debug("get ~p", [Url]),
    Opts = [with_body, {pool, ?POOL}, {connect_timeout, timer:seconds(2)}, {recv_timeout, timer:seconds(2)}],
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, Opts) of
        {ok, 200, _Headers, Body} ->
            lager:debug("Body for ~p ~p", [Url, Body]),
            {ok, jsx:decode(Body, [return_maps])};
        {ok, 404, _ResponseHeaders, _ResponseBody} ->
            lager:debug("device ~p not found", [DeviceId]),
            {error, not_found};
        _Other ->
            {error, {get_device_failed, _Other}}
    end.

-spec token_lookup() -> {binary(), binary()}.
token_lookup() ->
    case ets:lookup(?ETS, token) of
        [] -> {<<>>, <<>>};
        [{token, EndpointToken}] -> EndpointToken
    end.

-spec token_insert(binary(), binary()) -> ok.
token_insert(Endpoint, Token) ->
    true = ets:insert(?ETS, {token, {Endpoint, Token}}),
    ok.

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
