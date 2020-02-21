%%%-------------------------------------------------------------------
%% @doc
%% == Router MQTT Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_mqtt_worker).

-behaviour(gen_server).
-include("device_worker.hrl").

-dialyzer({nowarn_function, init/1}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
         start_link/3,
         send/2
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-define(SERVER, ?MODULE).

-record(state, {
                mac :: pos_integer(),
                connection :: pid(),
                pubtopic :: binary()
               }).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(MAC, ChannelName, Args) ->
    gen_server:start_link(?SERVER, [MAC, ChannelName, Args], []).

send(Pid, Payload) ->
    gen_server:call(Pid, {send, Payload}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([MAC, ChannelName, #{endpoint := Endpoint, topic := Topic}]) ->
    case connect(Endpoint, MAC, ChannelName) of
        {ok, Conn} ->
            ets:insert(router_mqtt_workers, {{MAC, ChannelName}, self()}),
            PubTopic = erlang:list_to_binary(io_lib:format("~shelium/~16.16.0b/rx", [Topic, MAC])),
            SubTopic = erlang:list_to_binary(io_lib:format("~shelium/~16.16.0b/tx/#", [Topic, MAC])),
            %% TODO use a better QoS to add some back pressure
            emqtt:subscribe(Conn, {SubTopic, 0}),
            {ok, #state{mac=MAC, connection=Conn, pubtopic=PubTopic}};
        error ->
            {stop, mqtt_connection_failed}
    end.

handle_call({send, Payload}, _From, #state{connection=Conn, pubtopic=Topic}=State) ->
    Res = emqtt:publish(Conn, Topic, Payload, 0),
    lager:info("publish result ~p", [Res]),
    {reply, Res, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({publish, Msg=#{payload := Pay}}, State) ->
    try jsx:decode(Pay, [return_maps]) of
        JSON ->
            case maps:find(<<"payload_raw">>, JSON) of
                {ok, Payload} ->
                    case router_devices_server:get(<<(State#state.mac):64/integer-unsigned-big>>) of
                        {ok, Device} ->
                            lager:info("queueing ~p for downlink to ~p", [Payload, State#state.mac]),
                            %% TODO figure out port and confirmation mode
                            router_devices_server:update(<<(State#state.mac):64/integer-unsigned-big>>, [{queue, Device#device.queue ++ [{false, 1, base64:decode(Payload)}]}]);
                        {error, Reason} ->
                            lager:info("could not find device ~p : ~p", [State#state.mac, Reason])
                    end;
                error ->
                    lager:info("JSON downlink did not contain raw_payload field: ~p", [JSON])
            end
    catch
        _:_ ->
            lager:info("could not parse json downlink message ~p", [Msg])
    end,
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{connection=Conn}) ->
    emqtt:disconnect(Conn).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec connect(binary(), any(), any()) -> {ok, pid()} | error.
connect(ConnectionString, Mac, Name) when is_binary(ConnectionString) ->
    Opts = [{scheme_defaults, [{mqtt, 1883}, {mqtts, 8883} | http_uri:scheme_defaults()]}, {fragment, false}],
    case http_uri:parse(ConnectionString, Opts) of
        {ok, {Scheme, UserInfo, Host, Port, _Path, _Query}} when Scheme == mqtt orelse
                                                                 Scheme == mqtts ->
            [Username, Password] = binary:split(UserInfo, <<":">>),
            EmqttOpts = [
                         {host, erlang:binary_to_list(Host)},
                         {port, Port},
                         {client_id, erlang:list_to_binary(io_lib:format("~.16b", [Mac]))},
                         {username, Username},
                         {password, Password},
                         {logger, {lager, debug}},
                         {clean_sess, false},
                         {keepalive, 30}
                        ],
            {ok, C} = emqtt:start_link(EmqttOpts),
            {ok, Props} = emqtt:connect(C),
            lager:info("connect returned ~p", [Props]),
            {ok, C};
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s ~p", [ConnectionString, Name]),
            error
    end.
