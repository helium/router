-module(router_ics_route_get_devaddrs_handler).

-behaviour(grpcbox_client_stream).

%% -include("./autogen/iot_config_pb.hrl").

-export([
    init/3,
    handle_message/2,
    handle_headers/2,
    handle_trailers/4,
    handle_eos/1
]).

-record(state, {
    data :: list(iot_config_pb:iot_config_devaddr_range_v1_pb()),
    error :: undefined | {error, any()}
}).

-type stream_id() :: non_neg_integer().
-type state() :: #state{}.

-spec init(pid(), stream_id(), any()) -> {ok, state()}.
init(_ConnectionPid, _StreamId, _Any) ->
    lager:info("init ~p: ~p", [_StreamId, _Any]),
    {ok, #state{data = [], error = undefined}}.

-spec handle_message(iot_config_pb:iot_config_devaddr_range_v1_pb(), state()) -> {ok, state()}.
handle_message(DevaddrRange, #state{data = Data} = State) ->
    lager:info("got ~p", [DevaddrRange]),
    {ok, State#state{data = [DevaddrRange | Data]}}.

-spec handle_headers(map(), state()) -> {ok, state()}.
handle_headers(_Metadata, CBData) ->
    {ok, CBData}.

handle_trailers(Status, Message, Metadata, #state{} = State) ->
    lager:info("trailers: [status: ~p] [message: ~p] [meta: ~p]", [Status, Message, Metadata]),
    case Status of
        <<"0">> ->
            {ok, State};
        _ ->
            lager:error("trailers ~p", [{error, {Status, Message, Metadata}}]),
            {ok, State#state{error = {error, Message}}}
    end.

-spec handle_eos(state()) -> {ok, state()}.
handle_eos(#state{data = Data, error = undefined} = State) ->
    lager:info("got eos, sending to router_device_devaddr"),
    ok = router_device_devaddr:reconcile_end({ok, Data}),
    {ok, State};
handle_eos(#state{error = Error} = State) ->
    lager:warning("got eos with error ~p", [Error]),
    ok = router_device_devaddr:reconcile_end(Error),
    {ok, State}.
