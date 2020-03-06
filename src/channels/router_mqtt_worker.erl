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
                device_id :: binary(),
                connection :: pid(),
                pubtopic :: binary()
               }).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(DeviceID, ChannelName, Args) ->
    gen_server:start_link(?SERVER, [DeviceID, ChannelName, Args], []).

send(Pid, Payload) ->
    gen_server:call(Pid, {send, Payload}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([DeviceID, ChannelName, #{endpoint := Endpoint, topic := Topic}]) ->
    case connect(Endpoint, DeviceID, ChannelName) of
        {ok, Conn} ->
            erlang:send_after(25000, self(), {ping, Conn}),
            ets:insert(router_mqtt_workers, {{DeviceID, ChannelName}, self()}),
            PubTopic = erlang:list_to_binary(io_lib:format("~shelium/~s/rx", [topic(Topic), DeviceID])),
            SubTopic = erlang:list_to_binary(io_lib:format("~shelium/~s/tx/#", [topic(Topic), DeviceID])),
            %% TODO use a better QoS to add some back pressure
            emqtt:subscribe(Conn, {SubTopic, 0}),
            {ok, #state{device_id=DeviceID, connection=Conn, pubtopic=PubTopic}};
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

handle_info({publish, #{payload := Pay}=Map}, #state{device_id=DeviceID}=State) ->
    try jsx:decode(Pay, [return_maps]) of
        JSON ->
            case maps:find(<<"payload_raw">>, JSON) of
                {ok, Payload} ->
                    lager:info("JSON downlink not implented yet, sorry ~p", [Payload]),
                    case router_devices_sup:lookup_device_worker(DeviceID) of
                        {error, _Reason} ->
                            lager:info("could not find device ~p : ~p", [DeviceID, _Reason]);
                        {ok, Pid} ->
                            Msg = {false, 1, base64:decode(Payload)},
                            router_device_worker:queue_message(Pid, Msg)
                    end;
                error ->
                    lager:info("JSON downlink did not contain raw_payload field: ~p", [JSON])
            end
    catch
        _:_ ->
            lager:info("could not parse json downlink message ~p", [Map])
    end,
    {noreply, State};
handle_info({ping, Connection}, State = #state{connection=Connection}) ->
    erlang:send_after(25000, self(), {ping, Connection}),
    Res = (catch emqtt:ping(Connection)),
    lager:info("pinging MQTT connection ~p", [Res]),
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
            EmqttOpts = [
                         {host, erlang:binary_to_list(Host)},
                         {port, Port},
                         {client_id, DeviceID},
                         {username, Username},
                         {password, Password},
                         {logger, {lager, debug}},
                         {clean_sess, false},
                         {keepalive, 30},
                         {ssl, Scheme == mqtts}
                        ],
            {ok, C} = emqtt:start_link(EmqttOpts),
            {ok, Props} = emqtt:connect(C),
            lager:info("connect returned ~p", [Props]),
            {ok, C};
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s ~p", [ConnectionString, Name]),
            error
    end.
