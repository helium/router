-module(router_console_ws_handler).

-behaviour(websocket_client).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         encode_msg/3, encode_msg/4, encode_msg/5,
         decode_msg/1]).

%% ------------------------------------------------------------------
%% websocket_client Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         onconnect/2,
         ondisconnect/2,
         websocket_handle/3,
         websocket_info/3,
         websocket_terminate/3]).

-define(HEARTBEAT_TIMER, timer:seconds(30)).
-define(HEARTBEAT_REF, <<"BPM">>).
-define(TOPIC_PHX, <<"phoenix">>).
-define(EVENT_JOIN, <<"phx_join">>).

-record(state, {auto_join = [] :: [binary()],
                forward :: pid()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
-spec start_link(map()) -> {ok, pid()} | {error, any()}.
start_link(Args) ->
    Url = maps:get(url, Args),
    websocket_client:start_link(Url, ?MODULE, maps:to_list(Args)).

-spec encode_msg(binary(), binary(), binary()) -> binary().
encode_msg(Ref, Topic, Event) ->
    encode_msg(Ref, Topic, Event, #{}).

-spec encode_msg(binary(), binary(), binary(), map()) -> binary().
encode_msg(Ref, Topic, Event, Payload) ->
    encode_msg(Ref, Topic, Event, Payload, <<"0">>).

-spec encode_msg(binary(), binary(), binary(), map(), binary()) -> binary().
encode_msg(Ref, Topic, Event, Payload, JRef) ->
    jsx:encode([JRef, Ref, Topic, Event, Payload]).

-spec decode_msg(binary()) -> {ok, {any(), any(), binary(), binary(), map()}} | {error, any()}.
decode_msg(Msg) ->
    try jsx:decode(Msg, [return_maps]) of
        [JRef, Ref, Topic, Event, Payload|_] ->
            {ok, {JRef, Ref, Topic, Event, Payload}}
    catch
        _:_ -> {error, "decode_failed"}     
    end.

%% ------------------------------------------------------------------
%% websocket_client Function Definitions
%% ------------------------------------------------------------------
init(ArgsList) ->
    Args = maps:from_list(ArgsList),
    lager:info("~p init with ~p", [?MODULE, Args]),
    AutoJoin = maps:get(auto_join, Args, []),
    Pid = maps:get(forward, Args),
    {once, #state{auto_join=AutoJoin, forward=Pid}}.

onconnect(_WSReq, State) ->
    lager:debug("connected ~p", [_WSReq]),
    self() ! heartbeat,
    self() ! auto_join,
    {ok, State}.

ondisconnect(_Error, State) ->
    lager:warning("discconnected ~p ", [_Error]),
    {reconnect, timer:seconds(60), State}.

websocket_handle({text, Msg}, _Req, State) ->
    case ?MODULE:decode_msg(Msg) of
        {ok, Decoded} ->
            handle_message(Decoded, State);
        {error, _Reason} ->
            lager:error("failed to decode message ~p ~p", [Msg, _Reason]),
            {ok, State}
    end;
websocket_handle(_Msg, _Req, State) ->
    lager:warning("rcvd unknown websocket_handle msg: ~p, ~p", [_Msg, _Req]),
    {ok, State}.

websocket_info(heartbeat, _Req, State) ->
    _ = erlang:send_after(?HEARTBEAT_TIMER, self(), heartbeat),
    Payload = ?MODULE:encode_msg(?HEARTBEAT_REF, ?TOPIC_PHX, <<"heartbeat">>),
    lager:debug("sending heartbeat"),
    {reply, {text, Payload}, State};
websocket_info(auto_join, _Req, #state{auto_join=AutoJoin}=State) ->
    lists:foreach(
      fun(Topic) ->
              Ref = <<"REF_", Topic/binary>>,
              Payload = ?MODULE:encode_msg(Ref, Topic, ?EVENT_JOIN, #{}),
              websocket_client:cast(self(), {text, Payload}),
              lager:debug("joining ~p with refs ~p", [Topic, Ref])
      end,
      AutoJoin),
    {ok, State};
websocket_info(_Msg, _Req, State) ->
    lager:warning("rcvd unknown websocket_info msg: ~p, ~p", [_Msg, _Req]),
    {ok, State}.

websocket_terminate(Reason, _ConnState, _State) ->
    lager:warning("websocket closed wih reason ~p",[Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle_message({_JRef, ?HEARTBEAT_REF, <<"phoenix">>,<<"phx_reply">>, Payload}, State) ->
    case maps:get(<<"status">>, Payload, undefined) of
        <<"ok">> -> lager:debug("hearbeat ok");
        _Other -> lager:warning("hearbeat failed: ~p", [_Other])
    end,
    {ok, State};
handle_message({<<"REF_", Topic/binary>>, _Ref, Topic, <<"phx_reply">>, Payload}, #state{auto_join=AutoJoin}=State) ->
    case lists:member(Topic, AutoJoin) of
        true ->
            case maps:get(<<"status">>, Payload, undefined) of
                <<"ok">> -> lager:debug("joined ~p ok", [Topic]);
                _Other -> lager:warning("joined ~p failed: ~p", [Topic, _Other])
            end;
        false ->
            lager:warning("joined unknown topic: ~p", [Topic])
    end,
    {ok, State};
handle_message({_JRef, _Ref, Topic, Event, Payload}, #state{forward=Pid}=State) ->
    Pid ! {ws_message, Topic, Event, Payload},
    {ok, State};
handle_message(_Msg, State) ->
    lager:debug("unhandle message ~p", [_Msg]),
    {ok, State}.
