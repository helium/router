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

-type stream_id() :: non_neg_integer().
-type state() :: list(iot_config_pb:iot_config_session_key_filter_v1_pb()).

-spec init(pid(), stream_id(), state()) -> {ok, state()}.
init(_ConnectionPid, _StreamId, State) ->
    lager:info("init ~p: ~p", [_StreamId, State]),
    {ok, State}.

-spec handle_message(iot_config_pb:iot_config_session_key_filter_v1_pb(), state()) -> {ok, state()}.
handle_message(SKF, State) ->
    lager:debug("got ~p", [SKF]),
    {ok, [SKF | State]}.

-spec handle_headers(map(), state()) -> {ok, state()}.
handle_headers(_Metadata, CBData) ->
    {ok, CBData}.

-spec handle_trailers(binary(), term(), map(), state()) -> {ok, state()}.
handle_trailers(_Status, _Message, _Metadata, CBData) ->
    {ok, CBData}.

-spec handle_eos(state()) -> {ok, state()}.
handle_eos(State) ->
    lager:info("got eos, sending to router_ics_eui_worker"),
    ok = router_ics_skf_worker:reconcile_end(State),
    {ok, State}.
