%%%-------------------------------------------------------------------
%% @doc
%% == Router MQTT Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_mqtt_channel).

-behaviour(gen_event).

%% ------------------------------------------------------------------
%% gen_event Function Exports
%% ------------------------------------------------------------------
-export([
         init/1,
         handle_event/2,
         handle_call/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-define(SERVER, ?MODULE).
-define(PING_TIMEOUT, 25000).

-record(state, {channel :: router_channel:channel(),
                connection :: pid(),
                pubtopic :: binary()}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Channel) ->
    lager:info("init with ~p", [Channel]),
    DeviceID = router_channel:device_id(Channel),
    ChannelName = router_channel:name(Channel),
    #{endpoint := Endpoint, topic := Topic} = router_channel:args(Channel),
    FixedTopic = topic(Topic),
    case connect(Endpoint, DeviceID, ChannelName) of
        {ok, Conn} ->
            erlang:send_after(?PING_TIMEOUT, self(), ping),
            PubTopic = erlang:list_to_binary(io_lib:format("~shelium/~s/rx", [FixedTopic, DeviceID])),
            SubTopic = erlang:list_to_binary(io_lib:format("~shelium/~s/tx/#", [FixedTopic, DeviceID])),
            %% TODO use a better QoS to add some back pressure
            emqtt:subscribe(Conn, {SubTopic, 0}),
            {ok, #state{channel=Channel,
                        connection=Conn,
                        pubtopic=PubTopic}};
        error ->
            {error, mqtt_connection_failed}
    end.

handle_event({data, Data}, #state{channel=Channel, connection=Conn, pubtopic=Topic}=State) ->
    DeviceID = router_channel:device_id(Channel),
    ID = router_channel:id(Channel),
    Fcnt = maps:get(sequence, Data),
    Payload = jsx:encode(Data),
    case router_channel:dupes(Channel) of
        true ->
            Res = emqtt:publish(Conn, Topic, Payload, 0),
            lager:info("published: ~p result: ~p", [Data, Res]);
        false ->
            case throttle:check(packet_dedup, {DeviceID, ID, Fcnt}) of
                {ok, _, _} ->

                    Res = emqtt:publish(Conn, Topic, Payload, 0),
                    lager:info("published: ~p result: ~p", [Data, Res]);
                _ ->
                    lager:debug("ignornign duplicate ~p", [Data])
            end
    end,
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info({publish, #{payload := Payload0}=Map}, #state{channel=Channel}=State) ->
    try jsx:decode(Payload0, [return_maps]) of
        JSON ->
            case maps:find(<<"payload_raw">>, JSON) of
                {ok, Payload1} ->
                    DeviceWorkerPid = router_channel:device_worker(Channel),
                    Msg = {false, 1, base64:decode(Payload1)},
                    router_device_worker:queue_message(DeviceWorkerPid, Msg);
                error ->
                    lager:warning("JSON downlink did not contain raw_payload field: ~p", [JSON])
            end
    catch
        _:_ ->
            lager:warning("could not parse json downlink message ~p", [Map])
    end,
    {ok, State};
handle_info(ping, #state{connection=Connection}=State) ->
    (catch emqtt:ping(Connection)),
    erlang:send_after(25000, self(), ping),
    {ok, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{connection=Conn}) ->
    (catch emqtt:disconnect(Conn)).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec topic(binary() | list()) -> binary().
topic(<<>>) ->
    <<>>;
topic("") ->
    <<>>;
topic(Topic) when is_list(Topic) ->
    topic(erlang:list_to_binary(Topic));
topic(<<"/", Topic/binary>>) ->
    topic(Topic);
topic(Topic) ->
    case binary:last(Topic) == $/ of
        false -> <<Topic/binary, "/">>;
        true -> Topic
    end.

-spec connect(binary(), binary(), any()) -> {ok, pid()} | error.
connect(ConnectionString, DeviceID, Name) when is_binary(ConnectionString) ->
    Opts = [{scheme_defaults, [{mqtt, 1883}, {mqtts, 8883} | http_uri:scheme_defaults()]}, {fragment, false}],
    case http_uri:parse(ConnectionString, Opts) of
        {ok, {Scheme, UserInfo, Host, Port, _Path, _Query}} when Scheme == mqtt orelse
                                                                 Scheme == mqtts ->
            [Username, Password] = binary:split(UserInfo, <<":">>),
            EmqttOpts = [{host, erlang:binary_to_list(Host)},
                         {port, Port},
                         {client_id, DeviceID},
                         {username, Username},
                         {password, Password},
                         {logger, {lager, debug}},
                         {clean_sess, false},
                         {keepalive, 30},
                         {ssl, Scheme == mqtts}],
            {ok, C} = emqtt:start_link(EmqttOpts),
            {ok, Props} = emqtt:connect(C),
            lager:info("connect returned ~p", [Props]),
            {ok, C};
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s ~p", [ConnectionString, Name]),
            error
    end.
