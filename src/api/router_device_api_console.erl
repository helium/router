-module(router_device_api_console).

-behavior(router_device_api_behavior).

-export([
         init/1,
         get_devices/2,
         handle_data/2,
         report_status/2
        ]).

-define(TOKEN_CACHE_TIME, 600).
-define(HANDLE_DATA_CACHE_TIME, 60).

-spec init(Args :: any()) -> ok.
init(_Args) ->
    ok.

-spec get_devices(DevEui :: binary(), AppEui :: binary()) -> [{binary(), router_device:device()}].
get_devices(DevEui, AppEui) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    case hackney:get(<<Endpoint/binary, "/api/router/devices/unknown?dev_eui=", AppEui/binary, "?oui=", DevEui/binary>>,
                     [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            lists:map(
              fun(JSONDevice) ->
                      ID = kvc:path([<<"id">>], JSONDevice),
                      Name = kvc:path([<<"name">>], JSONDevice),
                      AppKey = lorawan_utils:hex_to_binary(kvc:path([<<"app_key">>], JSONDevice)),
                      {AppKey, router_device:new(ID, Name, DevEui, AppEui)}
              end,
              jsx:decode(Body, [return_maps])
             );
        _Other ->
            []
    end.

-spec report_status(Device :: router_device:device(), Map :: #{}) -> ok.
report_status(Device, Map) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    DeviceID = router_device:id(Device),
    Body = #{status => maps:get(status, Map, failure),
             description => maps:get(msg, Map, <<"">>),
             reported_at => erlang:system_time(second),
             category => maps:get(category, Map, <<"">>),
             frame_up => router_device:fcnt(Device),
             frame_down => router_device:fcntdown(Device),
             hotspot_name => list_to_binary(maps:get(hotspot, Map, ""))},
    hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
                 [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}],
                 jsx:encode(Body), [with_body]),
    ok.

-spec handle_data(Device :: router_device:device(), Map :: #{}) -> ok.
handle_data(Device, Map) ->
    DeviceID = router_device:id(Device),
    Fun = e2qc:cache(?MODULE, DeviceID, ?HANDLE_DATA_CACHE_TIME, fun() -> make_handle_data_fun(Device) end),
    _ = Fun(Map),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec get_token(binary()) -> binary().
get_token(Endpoint) ->
    Secret = get_secret(),
    CacheFun = fun() ->
                       case hackney:post(<<Endpoint/binary, "/api/router/sessions">>, [{<<"Content-Type">>, <<"application/json">>}],
                                         jsx:encode(#{secret => Secret}) , [with_body]) of
                           {ok, 201, _Headers, Body} ->
                               #{<<"jwt">> := JWT} = jsx:decode(Body, [return_maps]),
                               JWT
                       end
               end,
    e2qc:cache(console_cache, jwt, 600, CacheFun).

make_handle_data_fun(Device) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    make_handle_data_fun(Endpoint, JWT, Device).

make_handle_data_fun(Endpoint, JWT, Device) ->
    DeviceId = router_device:id(Device),
    FCntDown = router_device:fcntdown(Device),
    case get_device(Device) of
        {error, _Reason} ->
            lager:warning("unable to get get_device for ~s : ~p", [router_device:name(Device), _Reason]),
            fun(#{rssi := RSSI, snr := SNR, miner_name := MinerName, timestamp := _Timestamp, payload := Payload, sequence := FCNT}) ->
                    Result = #{payload => base64:encode(Payload), payload_size => byte_size(Payload), reported_at => erlang:system_time(seconds),
                               rssi => RSSI, snr => SNR, hotspot_name => MinerName, channel_name => nil, category => <<"up">>, frame_up => FCNT,
                               frame_down => FCntDown, status => failure, description => <<"Cannot get channel configuration">>},
                    lager:info("No channel for ~p ~p", [DeviceId, Result]),
                    hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceId/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body])
            end;
        {ok, JSON} ->
            DeviceID = kvc:path([<<"id">>], JSON),
            ChannelFuns =
                case kvc:path([<<"channels">>], JSON) of
                    [] ->
                        [{fun(#{rssi := RSSI, snr := SNR, miner_name := MinerName, timestamp := _Timestamp, payload := Payload, sequence := FCNT}) ->
                                  Result = #{payload => base64:encode(Payload), payload_size => byte_size(Payload),
                                             reported_at => erlang:system_time(seconds),
                                             rssi => RSSI, snr => SNR, hotspot_name => MinerName, channel_name => nil, category => <<"up">>,
                                             frame_up => FCNT, frame_down => FCntDown,
                                             status => failure, description => <<"No channels configured">>},
                                  lager:info("No channel for ~p ~p", [DeviceID, Result]),
                                  hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body])
                          end, #{}}];
                    Channels ->
                        lists:map(fun(Channel) -> {channel_to_fun(Device, Endpoint, JWT, Channel), Channel} end, Channels)
                end,
            fun(#{sequence := FCNT}=MapData) ->
                    lists:foreach(
                      fun({F, #{<<"show_dupes">> := false, <<"id">> := ID}}) ->
                              case throttle:check(packet_dedup, {DeviceId, ID, FCNT}) of
                                  {ok, _, _} -> spawn(fun() -> F(MapData) end);
                                  _ -> ok
                              end;
                         ({F, _Channel}) ->
                              spawn(fun() -> F(MapData) end)
                      end,
                      ChannelFuns
                     )
            end
    end.

channel_to_fun(Device, Endpoint, JWT, #{<<"type">> := <<"http">>}=Channel) ->
    Headers = kvc:path([<<"credentials">>, <<"headers">>], Channel),
    lager:info("Headers ~p", [Headers]),
    URL = kvc:path([<<"credentials">>, <<"endpoint">>], Channel),
    lager:info("URL ~p", [URL]),
    Method = list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], Channel))),
    lager:info("Method ~p", [Method]),
    ChannelName = kvc:path([<<"name">>], Channel),
    DeviceId = router_device:id(Device),
    FCntDown = router_device:fcntdown(Device),
    fun(#{rssi := RSSI, snr := SNR, miner_name := MinerName, timestamp := _Timestamp, payload := Payload, sequence := FCNT}=DataMap) ->
            Result0 = #{channel_name => ChannelName, payload => base64:encode(Payload), payload_size => erlang:byte_size(Payload), 
                        reported_at => erlang:system_time(seconds), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                        category => <<"up">>, frame_up => FCNT, frame_down => FCntDown},
            Result = try hackney:request(Method, URL, maps:to_list(Headers), encode_data(Device, DataMap), [with_body]) of
                         {ok, StatusCode, _ResponseHeaders, ResponseBody} when StatusCode >= 200, StatusCode =< 300 ->
                             maps:merge(Result0, #{status => success, description => ResponseBody});
                         {ok, StatusCode, _ResponseHeaders, ResponseBody} ->
                             maps:merge(Result0, #{status => failure, 
                                                   description => <<"ResponseCode: ", (list_to_binary(integer_to_list(StatusCode)))/binary,
                                                                    " Body ", ResponseBody/binary>>});
                         {error, Reason} ->
                             maps:merge(Result0, #{status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))})
                     catch
                         What:Why:Stacktrace ->
                             lager:info("Failed to post to channel ~p ~p ~p", [What, Why, Stacktrace]),
                             maps:merge(Result0, #{status => failure, description => <<"invalid channel configuration">>})

                     end,
            lager:info("Result ~p", [Result]),
            hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceId/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body])
    end;
channel_to_fun(Device, Endpoint, JWT, #{<<"type">> := <<"mqtt">>}=Channel) ->
    URL = kvc:path([<<"credentials">>, <<"endpoint">>], Channel),
    Topic = kvc:path([<<"credentials">>, <<"topic">>], Channel),
    ChannelName= kvc:path([<<"name">>], Channel),
    DeviceId = router_device:id(Device),
    FCntDown = router_device:fcntdown(Device),
    fun(#{rssi := RSSI, snr := SNR, miner_name := MinerName, timestamp := _Timestamp, payload := Payload, sequence := FCNT}=DataMap) ->
            Result0 = #{channel_name => ChannelName, payload => base64:encode(Payload), payload_size => erlang:byte_size(Payload), 
                        reported_at => erlang:system_time(seconds), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                        category => <<"up">>, frame_up => FCNT, frame_down => FCntDown},
            Result = case router_mqtt_sup:get_connection(DeviceId, ChannelName, #{endpoint => URL, topic => Topic}) of
                         {ok, Pid} ->
                             case router_mqtt_worker:send(Pid, encode_data(Device, DataMap)) of
                                 {ok, PacketID} ->
                                     maps:merge(Result0, #{status => success, description => list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))});
                                 ok ->
                                     maps:merge(Result0, #{status => success, description => <<"ok">>});
                                 {error, Reason} ->
                                     maps:merge(Result0, #{status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))})
                             end;
                         _ ->
                             maps:merge(Result0, #{status => failure, description => <<"invalid channel configuration">>})
                     end,
            lager:info("Result ~p", [Result]),
            hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceId/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body])
    end.

-spec encode_data(router_device:device(), map()) -> binary().
encode_data(Device, #{id := DeviceID, payload := Payload, rssi := RSSI, snr := SNR, miner_name := MinerName, sequence := Seq, spreading := Spreading}) ->
    jsx:encode(#{timestamp => erlang:system_time(seconds),
                 sequence => Seq,
                 spreading => Spreading,
                 payload => base64:encode(Payload),
                 gateway => MinerName,
                 rssi => RSSI,
                 dev_eui => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
                 app_eui => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
                 name => router_device:name(Device),
                 snr => SNR,
                 id => DeviceID}).

-spec get_device(router_device:device()) -> {ok, map()} | {error, any()}.
get_device(Device) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    DeviceId = router_device:id(Device),
    case hackney:get(<<Endpoint/binary, "/api/router/devices/", DeviceId/binary>>,
                     [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body]) of
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
