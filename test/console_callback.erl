-module(console_callback).

-behaviour(elli_handler).

-export([handle/2, handle_event/3]).

handle(Req, _Args) ->
    handle(elli_request:method(Req), elli_request:path(Req), Req).

%% Get token
handle('GET', [<<"api">>, <<"router">>, <<"sessions">>], _Req) ->
    Body = #{<<"jwt">> => <<"console_callback_token">>},
    {201, [], jsx:encode(Body)};
%% Get Device
handle('GET', [<<"api">>, <<"router">>, <<"devices">>, DID], _Req) ->
    Body = #{
        <<"id">> => <<DID/binary, "_id">>,
        <<"key">> => <<DID/binary, "_key">>,
        <<"channels">> => []
    },
    {200, [], jsx:encode(Body)};
%% POST to channel
handle('POST', [<<"channel">>], _Req) ->
    {200, [], <<"Success: got data">>};
%% Report status
handle('POST', [<<"api">>, <<"router">>, <<"devices">>, _DID, <<"event">>], _Req) ->
    {200, [], <<>>};
handle(_Method, _Path, _Req) ->
    {404, [], <<"Not Found">>}.

handle_event(_Event, _Data, _Args) ->
    ok.