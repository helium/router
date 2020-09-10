-module(router_metrics).

-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

-define(BASE, "router_").
-define(OFFER, ?BASE ++ "routing_offer").
-define(PACKET, ?BASE ++ "routing_offer").

-define(METRICS, [{counter, ?OFFER, [type, status], "Offer count"},
                  {counter, ?PACKET, [type, status], "Packet count"}]).

-export([init/0,
         offer_inc/2,
         packet_inc/2]).

-export([handle/2,
         handle_event/3]).

init() ->
    lists:foreach(
      fun({counter, Name, Labels, Help}) ->
              ok = prometheus_counter:new([{name, Name},
                                           {help, Help},
                                           {labels, Labels}])
      end,
      ?METRICS).

-spec offer_inc(join | packet, accepted | rejected) -> ok.
offer_inc(Type, Status) when (Type == join orelse Type == packet)
                             andalso (Status == accepted orelse Status == rejected) ->
    ok = prometheus_counter:inc(?OFFER, [Type, Status]).

-spec packet_inc(join | packet, accepted | rejected) -> ok.
packet_inc(Type, Status) when (Type == join orelse Type == packet)
                              andalso (Status == accepted orelse Status == rejected) ->
    ok = prometheus_counter:inc(?PACKET, [Type, Status]).

%% ------------------------------------------------------------------
%% Elli Handler
%% ------------------------------------------------------------------

handle(Req, _Args) ->
    handle(Req#req.method, elli_request:path(Req), Req).

%% Expose /metrics for Prometheus to pull.
handle('GET', [<<"metrics">>], _Req) ->
    {ok, [], prometheus_text_format:format()};
handle(_Verb, _Path, _Req) -> ignore.

handle_event(_Event, _Data, _Args) ->
    ok.
