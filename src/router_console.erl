-module(router_console).

-export([
         get_app_key_by_eui/4,
         report_status/7,
         send_data_fun/1
        ]).

get_app_key_by_eui(DevEUI, AppEUI, Msg, MIC) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    lager:info("Msg ~p Mic ~p", [Msg, MIC]),
    lager:info("Requesting ~s", [<<Endpoint/binary, "/api/router/devices/yolo?dev_eui=", (lorawan_utils:binary_to_hex(DevEUI))/binary, "&app_eui=", (lorawan_utils:binary_to_hex(AppEUI))/binary>>]),
    case hackney:get(<<Endpoint/binary, "/api/router/devices/yolo?dev_eui=", (lorawan_utils:binary_to_hex(DevEUI))/binary, "&app_eui=", (lorawan_utils:binary_to_hex(AppEUI))/binary>>,
                     [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            lager:info("Body ~s", [Body]),
            find_dev(jsx:decode(Body, [return_maps]), Msg, MIC);
        _Other ->
            lager:info("Other ~p", [_Other]),
            false
    end.

find_dev([], _, _) ->
    undefined;
find_dev([JSON|Tail], Msg, MIC) ->
    Key = lorawan_utils:hex_to_binary(kvc:path([<<"app_key">>], JSON)),
    case crypto:cmac(aes_cbc128, Key, Msg, 4) == MIC of
        true ->
            Id = kvc:path([<<"id">>], JSON),
            Name = kvc:path([<<"name">>], JSON),
            {Key, Id, Name};
        false ->
            find_dev(Tail, Msg, MIC)
    end.


-spec report_status(binary(), atom(), string(), binary(), atom(), non_neg_integer(), non_neg_integer()) -> ok.
report_status(DeviceID, Status, AName, Msg, Category, Fcnt, FcntDown) ->
    Result = #{status => Status, description => Msg, category => Category, frame_up => Fcnt, frame_down => FcntDown,
               reported_at => erlang:system_time(second), hotspot_name => list_to_binary(AName)},
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    lager:info("Reporting status for ~p ~p", [DeviceID, Result]),
    hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
                 [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}],
                 jsx:encode(Result), [with_body]),
    ok.

-spec send_data_fun(router_device:device()) -> function().
send_data_fun(Device) ->
    e2qc:cache(console_cache, router_device:id(Device), 60, fun() -> make_send_data_fun(Device) end).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

make_send_data_fun(Device) ->
    Endpoint = get_endpoint(),
    JWT = get_token(Endpoint),
    make_send_data_fun(Device, Endpoint, JWT).

make_send_data_fun(Device, Endpoint, JWT) ->
    DeviceId = router_device:id(Device),
    FCntDown = router_device:fcntdown(Device),
    case get_device_channels(Device) of
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

-spec get_device_channels(router_device:device()) -> {ok, map()} | {error, any()}.
get_device_channels(Device) ->
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


-spec get_endpoint() -> binary().
get_endpoint() ->
    application:get_env(router, console_endpoint, undefined).

-spec get_secret() -> binary().
get_secret() ->
    application:get_env(router, console_secret, undefined).
