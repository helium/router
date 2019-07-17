-module(echo_http_test).

-behaviour(elli_handler).

-include_lib("common_test/include/ct.hrl").
-include_lib("elli/include/elli.hrl").

-export([
         handle/2,
         handle_event/3
        ]).

handle(Req, Pid) ->
    Pid ! {Req#req.method, Req#req.headers, elli_request:path(Req), Req#req.body},
    {ok, [], <<"ok">>}.

handle_event(_Event, _Data, _Args) ->
    ok.
