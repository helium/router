-module(router_mqtt_worker).
-behaviour(gen_server).

-export([start_link/3, send/2]).%, recv/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
                connection :: pid(),
                pubtopic :: binary()
               }).

start_link(MAC, ChannelName, Args) ->
    gen_server:start_link(?MODULE, [MAC, ChannelName, Args], []).

send(Pid, Payload) ->
    gen_server:call(Pid, {send, Payload}).

init([MAC, ChannelName, Args]) ->
    #{endpoint := Endpoint, topic := Topic} = Args,
    ets:insert(router_mqtt_workers, {{MAC, ChannelName}, self()}),
    case connect(Endpoint, MAC, ChannelName) of
        {ok, Client} ->
            PubTopic = list_to_binary(io_lib:format("~shelium/~.16b/rx", [Topic, MAC])),
            SubTopic = list_to_binary(io_lib:format("~shelium/~.16b/tx/#", [Topic, MAC])),
            emqtt:subscribe(Client, {SubTopic, 1}),
            {ok, #state{connection=Client, pubtopic=PubTopic}};
        error ->
            {stop, mqtt_connection_failed}
    end.

handle_call({send, Payload}, _From, State) ->
    Res = emqtt:publish(State#state.connection, State#state.pubtopic, Payload, 0),
    lager:info("publish result ~p", [Res]),
    {reply, Res, State};
handle_call(_Msg, _From, State) ->
    lager:info("CALL ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:info("CAST ~p", [_Msg]),
    {noreply, State}.


handle_info(_Msg, State) ->
    lager:info("INFO ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, State) ->
    emqtt:disconnect(State#state.connection).

connect(ConnectionString, Mac, Name) when is_binary(ConnectionString) ->
    case http_uri:parse(ConnectionString, [{scheme_defaults, [{mqtt, 1883}, {mqtts, 8883} | http_uri:scheme_defaults()]}, {fragment, false}]) of
        {ok, {Scheme, UserInfo, Host, Port, _Path, _Query}} when Scheme == mqtt orelse Scheme == mqtts ->
            [Username, Password] = binary:split(UserInfo, <<":">>),
            {ok, C} = emqtt:start_link([{host, binary_to_list(Host)}, {port, Port}, {client_id, list_to_binary(io_lib:format("~.16b", [Mac]))},
                                        {username, Username}, {password, Password}, {logger, {lager, debug}},
                                                %manual_puback,
                                        {clean_sess, false},
                                        {keepalive, 30}
                                                %{ssl, [
                                                %{versions, ['tlsv1.2', 'tlsv1.1']}
                                                % ]}
                                       ]),
            {ok, Props} = emqtt:connect(C),
            lager:info("connect returned ~p", [Props]),
            {ok, C};
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s", [ConnectionString, Name]),
            error
    end.
