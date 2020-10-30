-module(http2_handler_router_message_v1).

-behavior(lib_http2_handler).

-include_lib("lib_http2_handler/include/http2_handler.hrl").

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-ifdef(TEST).
-define(TIMEOUT, 4000).
-else.
-define(TIMEOUT, 7000).
-endif.

-record(handler_state, {
    timer_ref :: undefined | reference()
}).

%% ------------------------------------------------------------------
%% lib_http2_stream exports
%% ------------------------------------------------------------------
-export([
    validations/0,
    handle_on_receive_request_data/3,
    handle_on_request_end_stream/2,
    handle_info/2
]).

%% ------------------------------------------------------------------
%% lib_http2_stream callbacks
%% ------------------------------------------------------------------
validations() ->
    [
        {<<":method">>, fun(V) -> V =:= <<"POST">> end, <<"405">>, <<"method not supported">>}
    ].

handle_on_receive_request_data(
    _Method,
    Data,
    State = #state{request_data = Buffer}
) ->
    {ok, State#state{request_data = <<Buffer/binary, Data/binary>>}}.

handle_on_request_end_stream(
    _Method,
    State = #state{
        request_data = Data,
        stream_id = StreamId,
        client_ref = ClientRef,
        route = _Route
    }
) ->
    case deserialize_request(Data) of
        {ok, #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}} = Request} ->
            ?LOGGER(
                debug,
                ClientRef,
                StreamId,
                _Route,
                "deserialized request: ~p, forwarding packet to router",
                [
                    Request
                ]
            ),
            router_device_routing:handle_packet(Packet, erlang:system_time(millisecond), self()),
            Ref = erlang:send_after(?TIMEOUT, self(), router_response_timeout),
            HandlerState = #handler_state{timer_ref = Ref},
            {ok, State#state{request_data = <<>>, handler_state = HandlerState}};
        {error, _Reason} ->
            ?LOGGER(
                warning,
                ClientRef,
                StreamId,
                Route,
                "failed to decode request, reason: ~p",
                [
                    _Reason
                ]
            ),
            {ok, State, [
                {send_headers, [{<<":status">>, <<"400">>}]},
                {send_body, <<"bad request">>, true}
            ]}
    end.

%% ------------------------------------------------------------------
%% info msg callbacks
%% ------------------------------------------------------------------
%% TODO: Do we expect more than a single response msg to go back to the client under any scenarios ?
%%       at this point i am assuming not and thus sending the end stream marker with ev response msg
handle_info(
    {send_response, Resp} = _Msg,
    State = #state{
        stream_id = StreamId,
        client_ref = ClientRef,
        handler_state = #handler_state{timer_ref = TimerRef} = HandlerState
    }
) ->
    ok = cancel_timer(TimerRef),
    ?LOGGER(debug, ClientRef, StreamId, "received send_response with msg ~p", [
        Resp
    ]),
    NewHandlerState = HandlerState#handler_state{timer_ref = undefined},
    Bin = blockchain_state_channel_message_v1:encode(Resp),
    {ok, State#state{handler_state = NewHandlerState}, [
        {send_headers, [{<<":status">>, <<"200">>}]},
        {send_body, Bin, true}
    ]};
handle_info(
    router_response_timeout,
    State = #state{
        client_ref = ClientRef,
        stream_id = StreamId,
        handler_state = HandlerState
    }
) ->
    ?LOGGER(
        debug,
        ClientRef,
        StreamId,
        "timed out whilst awaiting send_response, giving up",
        []
    ),
    NewHandlerState = HandlerState#handler_state{timer_ref = undefined},
    {ok, State#state{handler_state = NewHandlerState}, [
        {send_headers, [{<<":status">>, <<"408">>}]},
        {send_body, <<"request timed out without an upstream response">>, true}
    ]};
handle_info(
    _Msg,
    State = #state{
        stream_id = StreamId,
        client_ref = ClientRef
    }
) ->
    ?LOGGER(debug, ClientRef, StreamId, "unhandled info msg: ~p", [
        _Msg
    ]),
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec cancel_timer(undefined | reference()) -> ok.
cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

-spec deserialize_request(binary()) -> {ok, any()} | {error, any()}.
deserialize_request(Data) ->
    try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
        #blockchain_state_channel_message_v1_pb{msg = {packet, _Packet}} = Msg ->
            {ok, Msg};
        _ ->
            {error, unhandled_message}
    catch
        _E:_R ->
            {error, {decode_failed, _E, _R}}
    end.
