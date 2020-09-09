-module(router_metrics).

-behaviour(elli_handler).

-include_lib("elli/include/elli.hrl").

-define(BASE, "router_").
-define(OFFER_JOIN_ACCEPTED, ?BASE ++ "routing_offer_join_accepted").
-define(OFFER_JOIN_REJECTED, ?BASE ++ "routing_offer_join_rejected").
-define(OFFER_PACKET_ACCEPTED, ?BASE ++ "routing_offer_packet_accepted").
-define(OFFER_PACKET_REJECTED, ?BASE ++ "routing_offer_packet_rejected").
-define(JOIN_ACCEPTED, ?BASE ++ "routing_join_accepted").
-define(JOIN_REJECTED, ?BASE ++ "routing_join_rejected").
-define(PACKET_ACCEPTED, ?BASE ++ "routing_packet_accepted").
-define(PACKET_REJECTED, ?BASE ++ "routing_packet_rejected").

-define(METRICS, [{?OFFER_JOIN_ACCEPTED, counter, "Accepted join offer count"},
                  {?OFFER_JOIN_REJECTED, counter, "Rejected join offer count"},
                  {?OFFER_PACKET_ACCEPTED, counter, "Accepted packet offer count"},
                  {?OFFER_PACKET_REJECTED, counter, "Rejected packet offer count"},
                  {?JOIN_ACCEPTED, counter, "Accepted join count"},
                  {?JOIN_REJECTED, counter, "Rejected join count"},
                  {?PACKET_ACCEPTED, counter, "Accepted packet count"},
                  {?PACKET_REJECTED, counter, "Rejected packet count"}]).

-export([init/0,
         offer_join_accpeted_inc/0, offer_join_rejected_inc/0,
         offer_packet_accpeted_inc/0, offer_packet_rejected_inc/0,
         join_accpeted_inc/0, join_rejected_inc/0,
         packet_accpeted_inc/0, packet_rejected_inc/0]).

-export([handle/2,
         handle_event/3]).

init() ->
    lists:foreach(
      fun({Name, counter, Help}) ->
              ok = prometheus_counter:new([{name, Name}, {help, Help}])
      end,
      ?METRICS).

offer_join_accpeted_inc() ->
    prometheus_counter:inc(?OFFER_JOIN_ACCEPTED).

offer_join_rejected_inc() ->
    prometheus_counter:inc(?OFFER_JOIN_ACCEPTED).

offer_packet_accpeted_inc() ->
    prometheus_counter:inc(?OFFER_PACKET_ACCEPTED).

offer_packet_rejected_inc() ->
    prometheus_counter:inc(?OFFER_PACKET_REJECTED).

join_accpeted_inc() ->
    prometheus_counter:inc(?JOIN_ACCEPTED).

join_rejected_inc() ->
    prometheus_counter:inc(?JOIN_ACCEPTED).

packet_accpeted_inc() ->
    prometheus_counter:inc(?PACKET_ACCEPTED).

packet_rejected_inc() ->
    prometheus_counter:inc(?PACKET_REJECTED).

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
