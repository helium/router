-module(router_ics_skf_list_handler).

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
    options :: map(),
    data :: list(iot_config_pb:iot_config_session_key_filter_v1_pb())
}).

-type stream_id() :: non_neg_integer().
-type state() :: #state{}.

-spec init(pid(), stream_id(), Options :: map() | undefined) -> {ok, state()}.
init(_ConnectionPid, _StreamId, Options) ->
    lager:info("init ~p: ~p", [_StreamId, Options]),
    {ok, #state{options = Options, data = []}}.

-spec handle_message(iot_config_pb:iot_config_session_key_filter_v1_pb(), state()) -> {ok, state()}.
handle_message(SKF, #state{data = Data} = State) ->
    lager:debug("got ~p", [SKF]),
    {ok, State#state{data = [SKF | Data]}}.

-spec handle_headers(map(), state()) -> {ok, state()}.
handle_headers(_Metadata, CBData) ->
    lager:info("headers: ~p", [_Metadata]),
    {ok, CBData}.

-spec handle_trailers(binary(), term(), map(), state()) -> {ok, state()}.
handle_trailers(_Status, _Message, _Metadata, CBData) ->
    lager:info("trailers: [status: ~p] [message: ~p] [meta: ~p]", [_Status, _Message, _Metadata]),
    {ok, CBData}.

-spec handle_eos(state()) -> {ok, state()}.
handle_eos(#state{options = Options, data = Data} = State) ->
    lager:info("got eos, sending to router_ics_skf_worker"),
    ok = router_ics_skf_worker:reconcile_end(Options, Data),
    {ok, State}.
