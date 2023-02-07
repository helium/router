-module(router_ics_route_get_euis_handler).

-behaviour(grpcbox_client_stream).

-include("./autogen/iot_config_pb.hrl").

-export([
    init/3,
    handle_message/2,
    handle_headers/2,
    handle_trailers/4,
    handle_eos/1
]).

-record(state, {
    pid :: pid() | undefined,
    data :: list(iot_config_pb:iot_config_eui_pair_v1_pb())
}).

-type stream_id() :: non_neg_integer().
-type state() :: #state{}.

-spec init(pid(), stream_id(), Pid :: pid() | undefined) -> {ok, state()}.
init(_ConnectionPid, _StreamId, Pid) ->
    lager:debug("init ~p: ~p", [_StreamId, Pid]),
    {ok, #state{pid = Pid, data = []}}.

-spec handle_message(iot_config_pb:iot_config_eui_pair_v1_pb(), state()) -> {ok, state()}.
handle_message(EUIPair, #state{data = Data} = State) ->
    lager:debug("got ~p", [EUIPair]),
    {ok, State#state{data = [EUIPair | Data]}}.

-spec handle_headers(map(), state()) -> {ok, state()}.
handle_headers(_Metadata, CBData) ->
    {ok, CBData}.

-spec handle_trailers(binary(), term(), map(), state()) -> {ok, state()}.
handle_trailers(_Status, _Message, _Metadata, CBData) ->
    {ok, CBData}.

-spec handle_eos(state()) -> {ok, state()}.
handle_eos(#state{pid = Pid, data = Data} = State) ->
    lager:info("got eos, sending to router_ics_eui_worker"),
    ok = router_ics_eui_worker:reconcile_end(Pid, Data),
    {ok, State}.
