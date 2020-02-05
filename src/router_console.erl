-module(router_console).

-export([
         get_app_key/2,
         report_status/5,
         send_data_fun/2
        ]).

-spec get_app_key(integer(), integer()) -> binary() | undefined.
get_app_key(DID, OUI) ->
    case get_device(DID, OUI) of
        {ok, JSON} ->
            base64:decode(kvc:path([<<"key">>], JSON));
        {error, _Reason} ->
            lager:warning("unable to get get_device for ~p ~p : ~p", [OUI, DID, _Reason]),
            undefined
    end.

-spec report_status(integer(), integer(), atom(), string(), binary()) -> ok | {error, any()}.
report_status(OUI, DID, Status, AName, Msg) ->
    case get_device(DID, OUI) of
        {ok, JSON} ->
            DeviceID = kvc:path([<<"id">>], JSON),
            Result = #{status => Status, description => Msg,
                       delivered_at => erlang:system_time(second), hotspot_name => list_to_binary(AName)},
            Endpoint = get_endpoint(OUI),
            Env = get_env(OUI),
            JWT = get_token(Endpoint, Env),
            hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
                         [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}],
                         jsx:encode(Result), [with_body]),
            ok;
        {error, _Reason} ->
            lager:warning("unable to get get_device for ~p ~p : ~p", [OUI, DID, _Reason])
    end.

-spec send_data_fun(integer(), integer()) -> function().
send_data_fun(DID, OUI) ->
    e2qc:cache(console_cache, {OUI, DID}, 300, fun() -> make_send_data_fun(DID, OUI) end).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

make_send_data_fun(DID, OUI) ->
    Endpoint = get_endpoint(OUI),
    Env = get_env(OUI),
    JWT = get_token(Endpoint, Env),
    make_send_data_fun(OUI, DID, Endpoint, JWT).

make_send_data_fun(OUI, DID, Endpoint, JWT) ->
    case get_device(DID, OUI) of
        {error, _Reason} ->
            lager:warning("unable to get get_device for ~p ~p : ~p", [OUI, DID, _Reason]),
            fun(_, _) -> ok end;
        {ok, JSON} ->
            DeviceID = kvc:path([<<"id">>], JSON),
            ChannelFuns =
                case kvc:path([<<"channels">>], JSON) of
                    [] ->
                        [fun(#{payload := Payload, rssi := RSSI, snr := SNR, miner_name := MinerName,  timestamp := Timestamp}) ->
                                 Result = #{id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                            delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                            status => <<"No Channel">>},
                                 hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body])
                         end];
                    Channels ->
                        lists:map(fun(Channel) -> channel_to_fun(OUI, DID, Endpoint, JWT, DeviceID, Channel) end, Channels)
                end,
            fun(MapData) ->
                    [spawn(fun() -> F(MapData) end) || F <- ChannelFuns]
            end
    end.

channel_to_fun(OUI, DID, Endpoint, JWT, DeviceID, #{<<"type">> := <<"http">>}=Channel) ->
    Headers = kvc:path([<<"credentials">>, <<"headers">>], Channel),
    lager:info("Headers ~p", [Headers]),
    URL = kvc:path([<<"credentials">>, <<"endpoint">>], Channel),
    lager:info("URL ~p", [URL]),
    Method = list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], Channel))),
    lager:info("Method ~p", [Method]),
    ChannelID = kvc:path([<<"name">>], Channel),
    fun(#{payload := Payload, rssi := RSSI, snr := SNR, miner_name := MinerName,  timestamp := Timestamp}=DataMap) ->
            Result = try hackney:request(Method, URL, maps:to_list(Headers), encode_data(OUI, DeviceID, DataMap), [with_body]) of
                         {ok, StatusCode, _ResponseHeaders, ResponseBody} when StatusCode >=200, StatusCode =< 300 ->
                             #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => erlang:byte_size(Payload), reported_at => Timestamp div 1000000,
                               delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                               status => success, description => ResponseBody};
                         {ok, StatusCode, _ResponseHeaders, ResponseBody} ->
                             #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => erlang:byte_size(Payload), reported_at => Timestamp div 1000000,
                               delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                               status => failure, description => <<"ResponseCode: ", (list_to_binary(integer_to_list(StatusCode)))/binary, " Body ", ResponseBody/binary>>};
                         {error, Reason} ->
                             #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => erlang:byte_size(Payload), reported_at => Timestamp div 1000000,
                               delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                               status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))}
                     catch
                         What:Why:Stacktrace ->
                             lager:info("Failed to post to channel ~p ~p ~p", [What, Why, Stacktrace]),
                             #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => erlang:byte_size(Payload), reported_at => Timestamp div 1000000,
                               delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                               status => failure, description => <<"invalid channel configuration">>}

                     end,
            lager:info("Result ~p", [Result]),
            hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body])
    end;
channel_to_fun(OUI, DID, Endpoint, JWT, DeviceID, #{<<"type">> := <<"mqtt">>}=Channel) ->
    URL = kvc:path([<<"credentials">>, <<"endpoint">>], Channel),
    Topic = kvc:path([<<"credentials">>, <<"topic">>], Channel),
    ChannelID = kvc:path([<<"name">>], Channel),
    fun(#{payload := Payload, rssi := RSSI, snr := SNR, miner_name := MinerName,  timestamp := Timestamp}=DataMap) ->
            Result = case router_mqtt_sup:get_connection((OUI bsl 32) + DID, ChannelID, #{endpoint => URL, topic => Topic}) of
                         {ok, Pid} ->
                             case router_mqtt_worker:send(Pid, encode_data(OUI, DeviceID, DataMap)) of
                                 {ok, PacketID} ->
                                     #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => erlang:byte_size(Payload), reported_at => Timestamp div 1000000,
                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                       status => success, description => list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))};
                                 ok ->
                                     #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => erlang:byte_size(Payload), reported_at => Timestamp div 1000000,
                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                       status => success, description => <<"ok">> };
                                 {error, Reason} ->
                                     #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => erlang:byte_size(Payload), reported_at => Timestamp div 1000000,
                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                       status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))}
                             end;
                         _ ->
                             #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => erlang:byte_size(Payload), reported_at => Timestamp div 1000000,
                               delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                               status => failure, description => <<"invalid channel configuration">>}
                     end,
            lager:info("Result ~p", [Result]),
            hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body])
    end.

-spec encode_data(integer(), binary(), map()) -> binary().
encode_data(OUI, DeviceID, #{payload := Payload, rssi := RSSI, snr := SNR, miner_name := MinerName, sequence := Seq, spreading := Spreading}) ->
    jsx:encode(#{timestamp => erlang:system_time(seconds),
                 oui => OUI,
                 device_id => DeviceID,
                 sequence => Seq,
                 spreading => Spreading,
                 payload => base64:encode(Payload),
                 gateway => MinerName,
                 rssi => RSSI,
                 snr => SNR}).

-spec get_device(integer(), integer()) -> {ok, map()} | {error, any()}.
get_device(DID, OUI) ->
    Endpoint = get_endpoint(OUI),
    Env = get_env(OUI),
    JWT = get_token(Endpoint, Env),
    BinDID = erlang:list_to_binary(erlang:integer_to_list(DID)),
    BinOUI = erlang:list_to_binary(erlang:integer_to_list(OUI)),
    case hackney:get(<<Endpoint/binary, "/api/router/devices/", BinDID/binary, "?oui=", BinOUI/binary>>,
                     [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            {ok, jsx:decode(Body, [return_maps])};
        _Other ->
            {error, {get_device_failed, _Other}}
    end.

-spec get_token(binary(), atom()) -> binary().
get_token(Endpoint, Env) ->
    Secret = get_secret(Env),
    CacheFun = fun() ->
                       case hackney:post(<<Endpoint/binary, "/api/router/sessions">>, [{<<"Content-Type">>, <<"application/json">>}],
                                         jsx:encode(#{secret => Secret}) , [with_body]) of
                           {ok, 201, _Headers, Body} ->
                               #{<<"jwt">> := JWT} = jsx:decode(Body, [return_maps]),
                               JWT
                       end
               end,
    e2qc:cache(console_cache, jwt, 600, CacheFun).

-spec get_env(OUI :: integer()) -> atom().
get_env(2) ->
    staging;
get_env(_) ->
    production.

-spec get_endpoint(OUI :: integer()) -> binary().
get_endpoint(2) ->
    application:get_env(router, staging_console_endpoint, undefined);
get_endpoint(_) ->
    application:get_env(router, console_endpoint, undefined).

-spec get_secret(Env :: atom()) -> binary().
get_secret(production) ->
    application:get_env(router, console_secret, undefined);
get_secret(staging) ->
    application:get_env(router, staging_console_secret, undefined).
