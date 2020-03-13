-module(console_callback).

-behaviour(elli_handler).

-export([
         handle/2,
         handle_event/3
        ]).

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
    Channel = case ChannelType of
                  http ->
                      #{
                        <<"type">> => <<"http">>,
                        <<"credentials">> => #{
                                               <<"headers">> => #{},
                                               <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                               <<"method">> => <<"POST">>
                                              },
                        <<"show_dupes">> => ShowDupes,
                        <<"id">> => <<"12345">>,
                        <<"name">> => <<"fake_http">>
                       };
                  mqtt ->
                      #{
                        <<"type">> => <<"mqtt">>,
                        <<"credentials">> => #{
                                               <<"endpoint">> => <<"mqtt://user:pass@test.com:1883">>,
                                               <<"topic">> => <<"test/">>
                                              },
                        <<"show_dupes">> => ShowDupes,
                        <<"id">> => <<"56789">>,
                        <<"name">> => <<"fake_mqtt">>
                       }
              end,
    Body = #{
             <<"id">> => <<"yolo_id">>,
             <<"name">> => <<"yolo_name">>,
             <<"app_key">> => lorawan_utils:binary_to_hex(maps:get(app_key, Args)),
             <<"channels">> => [Channel]
            },
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
    {200, [], <<"success">>};
handle(_Method, _Path, _Req, _Args) ->
    ct:pal("got unknown ~p req on ~p args=~p", [_Method, _Path, _Args]),
    {404, [], <<"Not Found">>}.

handle_event(_Event, _Data, _Args) ->
    ok.
