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
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-define(PING_TIMEOUT, timer:seconds(25)).

-record(state, {
    channel :: router_channel:channel(),
    connection :: pid(),
    endpoint :: binary(),
    pub_topic :: binary(),
    sub_topic :: binary()
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, _Device], _}) ->
    lager:info("~p init with ~p", [?MODULE, Channel]),
    DeviceID = router_channel:device_id(Channel),
    ChannelName = router_channel:name(Channel),
    #{endpoint := Endpoint, topic := Topic} = router_channel:args(Channel),
    FixedTopic = topic(Topic),
    case connect(Endpoint, DeviceID, ChannelName) of
        {ok, Conn} ->
            _ = ping(Conn),
            PubTopic = erlang:list_to_binary(
                io_lib:format("~shelium/~s/rx", [FixedTopic, DeviceID])
            ),
            SubTopic = erlang:list_to_binary(
                io_lib:format("~shelium/~s/tx/#", [FixedTopic, DeviceID])
            ),
            %% TODO use a better QoS to add some back pressure
            {ok, _, _} = emqtt:subscribe(Conn, SubTopic, 0),
            {ok, #state{
                channel = Channel,
                connection = Conn,
                endpoint = Endpoint,
                pub_topic = PubTopic,
                sub_topic = SubTopic
            }};
        {error, Reason} ->
            {error, Reason}
    end.

handle_event(
    {data, Ref, Data},
    #state{channel = Channel, connection = Conn, endpoint = Endpoint, pub_topic = Topic} =
        State
) ->
    Body = router_channel:encode_data(Channel, Data),
    Res = emqtt:publish(Conn, Topic, Body, 0),
    lager:debug("published: ~p result: ~p", [Data, Res]),
    Debug = #{req => #{endpoint => Endpoint, topic => Topic, qos => 0, body => Body}},
    ok = handle_publish_res(Res, Channel, Ref, Debug),
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call(
    {update, Channel, Device},
    #state{
        connection = Conn,
        endpoint = StateEndpoint,
        pub_topic = StatePubTopic,
        sub_topic = StateSubTopic
    } = State
) ->
    #{endpoint := Endpoint, topic := Topic} = router_channel:args(Channel),
    case Endpoint == StateEndpoint of
        false ->
            {swap_handler, ok, swapped, State,
                router_channel:handler(Channel), [Channel, Device]};
        true ->
            DeviceID = router_channel:device_id(Channel),
            FixedTopic = topic(Topic),
            PubTopic = erlang:list_to_binary(
                io_lib:format("~shelium/~s/rx", [FixedTopic, DeviceID])
            ),
            SubTopic = erlang:list_to_binary(
                io_lib:format("~shelium/~s/tx/#", [FixedTopic, DeviceID])
            ),
            case SubTopic == StateSubTopic andalso PubTopic == StatePubTopic of
                true ->
                    {ok, ok, State};
                false ->
                    {ok, _, _} = emqtt:unsubscribe(Conn, StateSubTopic),
                    {ok, _, _} = emqtt:subscribe(Conn, SubTopic, 0),
                    {ok, ok, State#state{pub_topic = PubTopic, sub_topic = SubTopic}}
            end
    end;
handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info(
    {publish, #{client_pid := Pid, payload := Payload}},
    #state{connection = Pid, channel = Channel} = State
) ->
    Controller = router_channel:controller(Channel),
    router_device_channels_worker:handle_downlink(Controller, Payload),
    {ok, State};
handle_info({Conn, ping}, #state{connection = Conn} = State) ->
    _ = ping(Conn),
    Res = (catch emqtt:ping(Conn)),
    lager:debug("pinging MQTT connection ~p", [Res]),
    {ok, State};
handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{connection = Conn}) ->
    (catch emqtt:disconnect(Conn)).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec ping(pid()) -> reference().
ping(Conn) ->
    erlang:send_after(?PING_TIMEOUT, self(), {Conn, ping}).

-spec handle_publish_res(any(), router_channel:channel(), reference(), map()) -> ok.
handle_publish_res(Res, Channel, Ref, Debug) ->
    Pid = router_channel:controller(Channel),
    Result0 = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel),
        reported_at => erlang:system_time(seconds)
    },
    Result1 =
        case Res of
            {ok, PacketID} ->
                maps:merge(Result0, #{
                    debug => maps:merge(Debug, #{res => #{packet_id => PacketID}}),
                    status => success,
                    description =>
                        list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))
                });
            ok ->
                maps:merge(Result0, #{
                    debug => maps:merge(Debug, #{res => #{}}),
                    status => success,
                    description => <<"ok">>
                });
            {error, Reason} ->
                maps:merge(Result0, #{
                    debug => maps:merge(Debug, #{res => #{}}),
                    status => failure,
                    description => list_to_binary(io_lib:format("~p", [Reason]))
                })
        end,
    router_device_channels_worker:report_status(Pid, Ref, Result1).

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

-spec connect(binary(), binary(), any()) -> {ok, pid()} | {error, term()}.
connect(URI, DeviceID, Name) ->
    Opts = [
        {scheme_defaults, [{mqtt, 1883}, {mqtts, 8883} | http_uri:scheme_defaults()]},
        {fragment, false}
    ],
    case http_uri:parse(URI, Opts) of
        {ok, {Scheme, UserInfo, Host, Port, _Path, _Query}} when Scheme == mqtt orelse
                                                                     Scheme == mqtts ->
            %% An optional userinfo subcomponent that may consist of a user name
            %% and an optional password preceded by a colon (:), followed by an
            %% at symbol (@). Use of the format username:password in the userinfo
            %% subcomponent is deprecated for security reasons. Applications
            %% should not render as clear text any data after the first colon
            %% (:) found within a userinfo subcomponent unless the data after
            %% the colon is the empty string (indicating no password).
            {Username, Password} =
                case binary:split(UserInfo, <<":">>) of
                    [Un, <<>>] -> {Un, undefined};
                    [Un, Pw] -> {Un, Pw};
                    [<<>>] -> {undefined, undefined};
                    [Un] -> {Un, undefined}
                end,
            EmqttOpts =
                [{host, erlang:binary_to_list(Host)}, {port, Port}, {clientid, DeviceID}] ++
                    [{username, Username} || Username /= undefined] ++
                    [{password, Password} || Password /= undefined] ++
                    [{clean_start, false}, {keepalive, 30}, {ssl, Scheme == mqtts}],
            {ok, C} = emqtt:start_link(EmqttOpts),
            case emqtt:connect(C) of
                {ok, _Props} ->
                    lager:info("connect returned ~p", [_Props]),
                    {ok, C};
                {error, Reason} ->
                    lager:info("Failed to connect to ~p ~p : ~p", [Host, Port, Reason]),
                    {error, Reason}
            end;
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s ~p", [URI, Name]),
            {error, invalid_mqtt_uri}
    end.
