-module(console_callback).

-behaviour(elli_handler).

-export([handle/2, handle_event/3]).

handle(Req, _Args) ->
    handle(elli_request:method(Req), elli_request:path(Req), Req, _Args).

%% Get Device
handle('GET', [<<"api">>, <<"router">>, <<"devices">>, DID], _Req, _Args) ->
    HTTPChannel = #{
                    <<"type">> => <<"http">>,
                    <<"credentials">> => #{
                                           <<"headers">> => #{},
                                           <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                           <<"method">> => <<"POST">>
                                          },
                    <<"show_dupes">> => false
                   },
    Body = #{
             <<"id">> => <<DID/binary, "_id">>,
             <<"key">> => base64:encode(<<"appkey_00000000", DID/binary>>),
             <<"channels">> => [HTTPChannel]
            },
    {200, [], jsx:encode(Body)};
%% Get token
handle('POST', [<<"api">>, <<"router">>, <<"sessions">>], _Req, _Args) ->
    Body = #{<<"jwt">> => <<"console_callback_token">>},
    {201, [], jsx:encode(Body)};
%% Report status
handle('POST', [<<"api">>, <<"router">>, <<"devices">>,
                _DID, <<"event">>], Req, [Pid]=_Args) ->
    Pid ! {report_status, elli_request:body(Req)},
    {200, [], <<>>};
%% POST to channel
handle('POST', [<<"channel">>], Req, [Pid]=_Args) ->
    Pid ! {channel, elli_request:body(Req)},
    {200, [], <<"success">>};
handle(_Method, _Path, _Req, _Args) ->
    ct:pal("got unknown ~p req on ~p args=~p", [_Method, _Path, _Args]),
    {404, [], <<"Not Found">>}.

handle_event(_Event, _Data, _Args) ->
    ok.
