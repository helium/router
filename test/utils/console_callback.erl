-module(console_callback).

-behaviour(elli_handler).

-include("console_test.hrl").

-export([handle/2,
         handle_event/3]).

handle(Req, _Args) ->
    handle(elli_request:method(Req), elli_request:path(Req), Req, _Args).

%% Get Device
handle('GET', [<<"api">>, <<"router">>, <<"devices">>, DID], _Req, Args) ->
    Tab = maps:get(ets, Args),
    ShowDupes = case ets:lookup(Tab, show_dupes) of
                    [] -> false;
                    [{show_dupes, B}] -> B
                end,
    ChannelType = case ets:lookup(Tab, channel_type) of
                      [] -> http;
                      [{channel_type, Type}] -> Type
                  end,
    NoChannel = case ets:lookup(Tab, no_channel) of
                    [] -> false;
                    [{no_channel, No}] -> No
                end,
    Channel = case ChannelType of
                  http -> ?CONSOLE_HTTP_CHANNEL(ShowDupes);
                  mqtt -> ?CONSOLE_MQTT_CHANNEL(ShowDupes)
              end,
    Channels = case NoChannel of
                   true -> [];
                   false ->
                       case ets:lookup(Tab, channels) of
                           [] -> [Channel];
                           [{channels, C}] -> C
                       end
               end,
    Body = #{<<"id">> => ?CONSOLE_DEVICE_ID,
             <<"name">> => ?CONSOLE_DEVICE_NAME,
             <<"app_key">> => lorawan_utils:binary_to_hex(maps:get(app_key, Args)),
             <<"app_eui">> => lorawan_utils:binary_to_hex(maps:get(app_eui, Args)),
             <<"dev_eui">> => lorawan_utils:binary_to_hex(maps:get(dev_eui, Args)),
             <<"channels">> => Channels,
             <<"labels">> => ?CONSOLE_LABELS},
    case DID == <<"unknown">> of
        true ->
            {200, [], jsx:encode([Body])};
        false ->
            {200, [], jsx:encode(Body)}
    end;
%% Get token
handle('POST', [<<"api">>, <<"router">>, <<"sessions">>], _Req, _Args) ->
    Body = #{<<"jwt">> => <<"console_callback_token">>},
    {201, [], jsx:encode(Body)};
%% Report status
handle('POST', [<<"api">>, <<"router">>, <<"devices">>,
                _DID, <<"event">>], Req, Args) ->
    Pid = maps:get(forward, Args),
    Pid ! {report_status, elli_request:body(Req)},
    {200, [], <<>>};
%% POST to channel
handle('POST', [<<"channel">>], Req, Args) ->
    Pid = maps:get(forward, Args),
    Pid ! {channel_data, elli_request:body(Req)},
    Body = elli_request:body(Req),
    try jsx:decode(Body, [return_maps]) of
        JSON ->
            Reply = base64:encode(<<"reply">>),
            case maps:find(<<"payload">>, JSON) of
                {ok, Reply} ->
                    {200, [], jsx:encode(#{payload_raw => base64:encode(<<"ack">>), port => 1, confirmed => true})};
                _ ->
                    {200, [], <<"success">>}
            end
    catch _:_ ->
            {200, [], <<"success">>}
    end;
handle(_Method, _Path, _Req, _Args) ->
    ct:pal("got unknown ~p req on ~p args=~p", [_Method, _Path, _Args]),
    {404, [], <<"Not Found">>}.

handle_event(_Event, _Data, _Args) ->
    ok.
