-module(router_ics_route_get_euis_handler).

-behaviour(grpcbox_client_stream).

-export([
    init/3,
    handle_message/2,
    handle_headers/2,
    handle_trailers/4,
    handle_eos/1
]).

-record(state, {
    options :: map(),
    euis :: list(iot_config_pb:iot_config_eui_pair_v1_pb())
}).

-type stream_id() :: non_neg_integer().
-type state() :: #state{}.

-spec init(pid(), stream_id(), Options :: map()) -> {ok, state()}.
init(_ConnectionPid, _StreamId, Options) ->
    lager:debug("init ~p: ~p", [_StreamId, Options]),
    {ok, #state{options = Options, euis = []}}.

-spec handle_message(iot_config_pb:iot_config_eui_pair_v1_pb(), state()) -> {ok, state()}.
handle_message(EUIPair, #state{euis = EUIPairs} = State) ->
    lager:debug("got ~p", [EUIPair]),
    {ok, State#state{euis = [EUIPair | EUIPairs]}}.

-spec handle_headers(map(), state()) -> {ok, state()}.
handle_headers(_Metadata, CBData) ->
    lager:info("headers: ~p", [_Metadata]),
    {ok, CBData}.

-spec handle_trailers(binary(), term(), map(), state()) -> {ok, state()}.
handle_trailers(Status, Message, Metadata, #state{options = Options} = State) ->
    lager:info("trailers: [status: ~p] [message: ~p] [meta: ~p]", [Status, Message, Metadata]),
    case Status of
        <<"0">> ->
            {ok, State};
        _ ->
            Error = {error, {Status, Message, Metadata}},
            {ok, State#state{options = Options#{error => Error}}}
    end.

-spec handle_eos(state()) -> {ok, state()}.
handle_eos(#state{options = Options, euis = EUIPairs} = State) ->
    lager:info("got eos, sending to router_ics_eui_worker"),
    ok = router_ics_eui_worker:reconcile_end(Options, EUIPairs),
    {ok, State}.
