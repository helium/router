%%%-------------------------------------------------------------------
%% @doc
%% == Router MQTT Channel ==
%%
%% Connects and publishes messages to User's MQTT instance.
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_mqtt_channel).

-behaviour(gen_event).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

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

-define(PING_TIMEOUT, timer:seconds(25)).
-define(BACKOFF_MIN, timer:seconds(10)).
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    channel :: router_channel:channel(),
    channel_id :: binary(),
    device :: router_device:device(),
    connection :: pid() | undefined,
    conn_backoff :: backoff:backoff(),
    conn_backoff_ref :: reference() | undefined,
    endpoint :: binary(),
    uplink_topic :: binary(),
    downlink_topic :: binary() | undefined,
    ping :: reference() | undefined
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    ok = router_utils:lager_md(Device),
    ChannelID = router_channel:unique_id(Channel),
    lager:info("[~s] ~p init with ~p", [ChannelID, ?MODULE, Channel]),
    #{
        endpoint := Endpoint,
        uplink_topic := UplinkTemplate,
        downlink_topic := DownlinkTemplate
    } = router_channel:args(Channel),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    send_connect_after(ChannelID, 0),
    {ok, #state{
        channel = Channel,
        channel_id = ChannelID,
        device = Device,
        conn_backoff = Backoff,
        endpoint = Endpoint,
        uplink_topic = render_topic(UplinkTemplate, Device),
        downlink_topic = render_topic(DownlinkTemplate, Device)
    }}.

handle_event({join, UUIDRef, Data}, #state{channel = Channel} = State0) ->
    State1 =
        case router_channel:receive_joins(Channel) of
            true -> do_handle_event(UUIDRef, Data, State0);
            false -> State0
        end,
    {ok, State1};
handle_event({data, UUIDRef, Data}, #state{} = State0) ->
    State1 = do_handle_event(UUIDRef, Data, State0),
    {ok, State1};
handle_event(_Msg, #state{channel_id = ChannelID} = State) ->
    lager:warning("[~s] rcvd unknown cast msg: ~p", [ChannelID, _Msg]),
    {ok, State}.

handle_call(
    {update, Channel, Device},
    #state{
        connection = Conn,
        endpoint = StateEndpoint,
        uplink_topic = StateUplinkTopic,
        downlink_topic = StateDownlinkTopic
    } = State
) ->
    #{
        endpoint := Endpoint,
        uplink_topic := UplinkTemplate,
        downlink_topic := DownlinkTemplate
    } = router_channel:args(Channel),
    UplinkTopic = render_topic(UplinkTemplate, Device),
    DownlinkTopic = render_topic(DownlinkTemplate, Device),
    case Endpoint == StateEndpoint of
        false ->
            {swap_handler, ok, swapped, State, router_channel:handler(Channel), [Channel, Device]};
        true ->
            case DownlinkTopic == StateDownlinkTopic andalso UplinkTopic == StateUplinkTopic of
                true ->
                    {ok, ok, State#state{
                        channel = Channel
                    }};
                false ->
                    _ = emqtt:unsubscribe(Conn, StateDownlinkTopic),
                    _ = emqtt:subscribe(Conn, DownlinkTopic, 0),
                    {ok, ok, State#state{
                        channel = Channel,
                        uplink_topic = UplinkTopic,
                        downlink_topic = DownlinkTopic
                    }}
            end
    end;
handle_call(_Msg, #state{channel_id = ChannelID} = State) ->
    lager:warning("[~s] rcvd unknown call msg: ~p", [ChannelID, _Msg]),
    {ok, ok, State}.

handle_info(
    {?MODULE, connect, ChannelID},
    #state{
        channel = Channel,
        channel_id = ChannelID,
        device = Device,
        connection = OldConn,
        conn_backoff = Backoff0,
        endpoint = Endpoint,
        downlink_topic = undefined,
        ping = TimerRef
    } = State
) ->
    ok = cleanup_connection(OldConn),
    _ = (catch erlang:cancel_timer(TimerRef)),
    DeviceID = router_device:id(Device),
    ChannelName = router_channel:name(Channel),
    try connect(Endpoint, DeviceID, ChannelName) of
        {ok, Conn} ->
            lager:info("[~s] connected to : ~p (~p)", [
                ChannelID,
                Endpoint,
                Conn
            ]),
            {_, Backoff1} = backoff:succeed(Backoff0),
            {ok, State#state{
                connection = Conn,
                conn_backoff = Backoff1,
                ping = schedule_ping(ChannelID)
            }};
        {error, _ConnReason} ->
            Report = io_lib:format(
                "[~s] failed to connect to ~p: ~p",
                [ChannelID, Endpoint, _ConnReason]
            ),
            lager:error(Report),
            router_device_channels_worker:report_integration_error(Device, Report, Channel),
            {ok, reconnect(State)}
    catch
        Type:Err ->
            Report = io_lib:format("[~s] failed to connect ~p: ~p", [ChannelID, Type, Err]),
            lager:error(Report),
            router_device_channels_worker:report_integration_error(Device, Report, Channel),
            {ok, reconnect(State)}
    end;
handle_info(
    {?MODULE, connect, ChannelID},
    #state{
        channel = Channel,
        channel_id = ChannelID,
        device = Device,
        connection = OldConn,
        conn_backoff = Backoff0,
        endpoint = Endpoint,
        downlink_topic = DownlinkTopic,
        ping = TimerRef
    } = State
) ->
    ok = cleanup_connection(OldConn),
    _ = (catch erlang:cancel_timer(TimerRef)),
    DeviceID = router_device:id(Device),
    ChannelName = router_channel:name(Channel),
    try connect(Endpoint, DeviceID, ChannelName) of
        {ok, Conn} ->
            case emqtt:subscribe(Conn, DownlinkTopic, 0) of
                {ok, _, _} ->
                    lager:info("[~s] connected to : ~p (~p) and subscribed to ~p", [
                        ChannelID,
                        Endpoint,
                        Conn,
                        DownlinkTopic
                    ]),
                    {_, Backoff1} = backoff:succeed(Backoff0),
                    {ok, State#state{
                        connection = Conn,
                        conn_backoff = Backoff1,
                        ping = schedule_ping(ChannelID)
                    }};
                {error, _SubReason} ->
                    lager:error("[~s] failed to subscribe to ~p: ~p", [
                        ChannelID,
                        DownlinkTopic,
                        _SubReason
                    ]),
                    {ok, reconnect(State)}
            end;
        {error, _ConnReason} ->
            Report = io_lib:format(
                "[~s] failed to connect to ~p: ~p",
                [ChannelID, Endpoint, _ConnReason]
            ),
            lager:error(Report),
            router_device_channels_worker:report_integration_error(Device, Report, Channel),
            {ok, reconnect(State)}
    catch
        Type:Err ->
            Report = io_lib:format("[~s] failed to connect ~p: ~p", [ChannelID, Type, Err]),
            lager:error(Report),
            router_device_channels_worker:report_integration_error(Device, Report, Channel),
            {ok, reconnect(State)}
    end;
%% Ignore connect message not for us
handle_info({_, connect, _}, State) ->
    {ok, State};
handle_info(
    {?MODULE, ping, ChannelID},
    #state{
        channel_id = ChannelID,
        connection = Conn,
        ping = TimerRef
    } = State
) ->
    _ = (catch erlang:cancel_timer(TimerRef)),
    try ping(Conn) of
        ok ->
            lager:debug("[~s] pinged MQTT connection ~p successfully", [ChannelID, Conn]),
            {ok, State#state{ping = schedule_ping(ChannelID)}};
        {error, _Reason} ->
            lager:error("[~s] failed to ping MQTT connection ~p: ~p", [
                ChannelID,
                Conn,
                _Reason
            ]),
            {ok, reconnect(State)}
    catch
        _Class:_Reason ->
            lager:error("[~s] failed to ping MQTT connection ~p: ~p", [
                ChannelID,
                Conn,
                {_Class, _Reason}
            ]),
            {ok, reconnect(State)}
    end;
handle_info(
    {publish, #{client_pid := Conn, payload := Payload}},
    #state{channel = Channel, connection = Conn} = State
) ->
    Controller = router_channel:controller(Channel),
    router_device_channels_worker:handle_downlink(Controller, Payload, Channel),
    {ok, State};
handle_info(
    {'EXIT', Conn, {_Type, _Reason}},
    #state{
        channel_id = ChannelID,
        connection = Conn,
        ping = TimerRef
    } = State
) ->
    _ = (catch erlang:cancel_timer(TimerRef)),
    lager:error("[~s] got an EXIT message: ~p ~p", [ChannelID, _Type, _Reason]),
    {ok, reconnect(State)};
handle_info({disconnected, _Type, _Reason}, #state{channel_id = ChannelID} = State) ->
    lager:error("[~s] got a disconnected message: ~p ~p", [ChannelID, _Type, _Reason]),
    {ok, State};
handle_info(_Msg, #state{channel_id = ChannelID} = State) ->
    lager:debug("[~s] rcvd unknown info msg: ~p", [ChannelID, _Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{connection = Conn}) ->
    ok = cleanup_connection(Conn).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec do_handle_event(
    UUIDRef :: router_utils:uuid_v4(),
    Data :: map(),
    #state{}
) -> #state{}.
do_handle_event(
    UUIDRef,
    Data,
    #state{
        channel = Channel
    } = State0
) ->
    Pid = router_channel:controller(Channel),
    Response = publish(Data, State0),
    RequestReport = make_request_report(Response, Data, State0),
    ok = router_device_channels_worker:report_request(Pid, UUIDRef, Channel, RequestReport),
    State1 =
        case Response of
            {error, failed_to_publish} ->
                reconnect(State0);
            _ ->
                State0
        end,
    ResponseReport = make_response_report(Response, Channel),
    ok = router_device_channels_worker:report_response(Pid, UUIDRef, Channel, ResponseReport),
    State1.

-spec ping(Conn :: pid()) -> ok | {error, any()}.
ping(Conn) ->
    try emqtt:ping(Conn) of
        pong ->
            ok
    catch
        _Class:Reason ->
            {error, Reason}
    end.

-spec publish(map(), #state{}) -> {ok, any()} | {error, not_connected | failed_to_publish}.
publish(_Data, #state{connection = undefined}) ->
    {error, not_connected};
publish(
    Data,
    #state{
        channel = Channel,
        channel_id = ChannelID,
        connection = Conn,
        uplink_topic = Topic
    }
) ->
    Body = router_channel:encode_data(Channel, Data),
    try emqtt:publish(Conn, Topic, Body, 0) of
        Resp ->
            lager:debug("[~s] published: ~p to ~p result: ~p", [ChannelID, Data, Topic, Resp]),
            {ok, Resp}
    catch
        _:_ ->
            lager:error("[~s] failed to publish", [ChannelID]),
            {error, failed_to_publish}
    end.

-spec schedule_ping(binary()) -> reference().
schedule_ping(ChannelID) ->
    erlang:send_after(?PING_TIMEOUT, self(), {?MODULE, ping, ChannelID}).

-spec send_connect_after(ChannelID :: binary(), Delay :: integer()) -> reference().
send_connect_after(ChannelID, Delay) ->
    erlang:send_after(Delay, self(), {?MODULE, connect, ChannelID}).

-spec reconnect(#state{}) -> #state{}.
reconnect(
    #state{channel_id = ChannelID, conn_backoff = Backoff0, conn_backoff_ref = TimerRef0} = State
) ->
    _ = (catch erlang:cancel_timer(TimerRef0)),
    {Delay, Backoff1} = backoff:fail(Backoff0),
    TimerRef1 = send_connect_after(ChannelID, Delay),
    State#state{conn_backoff = Backoff1, conn_backoff_ref = TimerRef1}.

-spec cleanup_connection(pid()) -> ok.
cleanup_connection(Conn) ->
    (catch emqtt:disconnect(Conn)),
    (catch emqtt:stop(Conn)),
    ok.

-spec make_request_report({ok | error, any()}, any(), #state{}) -> map().
make_request_report({error, Reason}, Data, #state{
    channel = Channel,
    endpoint = Endpoint,
    uplink_topic = Topic
}) ->
    %% Helium Error
    #{
        request => #{
            endpoint => Endpoint,
            topic => Topic,
            qos => 0,
            body => router_channel:encode_data(Channel, Data)
        },
        status => error,
        description => erlang:list_to_binary(io_lib:format("Error: ~p", [Reason]))
    };
make_request_report({ok, Response}, Data, #state{
    channel = Channel,
    endpoint = Endpoint,
    uplink_topic = Topic
}) ->
    Request = #{
        endpoint => Endpoint,
        topic => Topic,
        qos => 0,
        body => router_channel:encode_data(Channel, Data)
    },
    case Response of
        {error, Reason} ->
            %% Emqtt Error
            Description = erlang:list_to_binary(io_lib:format("Error: ~p", [Reason])),
            #{request => Request, status => error, description => Description};
        ok ->
            #{request => Request, status => success, description => <<"published">>};
        {ok, _PacketID} ->
            #{request => Request, status => success, description => <<"published">>}
    end.

-spec make_response_report({ok | error, any()}, router_channel:channel()) -> map().
make_response_report({error, Reason}, Channel) ->
    #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel),
        response => #{},
        status => error,
        description => erlang:list_to_binary(io_lib:format("Error: ~p", [Reason]))
    };
make_response_report({ok, Response}, Channel) ->
    Report = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel)
    },

    case Response of
        ok ->
            maps:merge(Report, #{
                response => #{},
                status => success,
                description => <<"ok">>
            });
        {ok, PacketID} ->
            maps:merge(Report, #{
                response => #{packet_id => PacketID},
                status => success,
                description => erlang:list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))
            });
        {error, Reason} ->
            maps:merge(Report, #{
                response => #{},
                status => error,
                description => erlang:list_to_binary(io_lib:format("~p", [Reason]))
            })
    end.

-spec connect(URI :: binary(), DeviceID :: binary(), Name :: binary()) ->
    {ok, pid()} | {error, term()}.
connect(URI, DeviceID, Name) ->
    case uri_string:parse(URI) of
        #{
            host := Host,
            scheme := Scheme
        } = Map when
            Scheme == <<"mqtt">> orelse
                Scheme == <<"mqtts">>
        ->
            SSL = Scheme == <<"mqtts">>,
            DefaultPort =
                case SSL of
                    true -> 8883;
                    false -> 1883
                end,
            Port = maps:get(port, Map, DefaultPort),
            UserInfo = maps:get(userinfo, Map, <<>>),
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
                [
                    {host, erlang:binary_to_list(Host)},
                    {port, Port},
                    {clientid, DeviceID}
                ] ++
                    [{username, Username} || Username /= undefined] ++
                    [{password, Password} || Password /= undefined] ++
                    [
                        {clean_start, false},
                        {keepalive, 30},
                        {ssl, SSL}
                    ],
            {ok, C} = emqtt:start_link(EmqttOpts),
            case emqtt:connect(C) of
                {ok, _Props} ->
                    lager:info("connect returned ~p ~p", [_Props, EmqttOpts]),
                    {ok, C};
                {error, Reason} ->
                    lager:info("Failed to connect to ~p : ~p", [
                        EmqttOpts,
                        Reason
                    ]),
                    {error, Reason}
            end;
        _ ->
            lager:info("BAD MQTT URI ~p for channel ~p", [URI, Name]),
            {error, invalid_mqtt_uri}
    end.

-spec render_topic(
    Template :: binary() | undefined,
    Device :: router_device:device()
) -> binary() | undefined.
render_topic(undefined, _Device) ->
    undefined;
render_topic(Template, Device) ->
    lager:notice("~p ~p", [Template, Device]),
    Metadata = router_device:metadata(Device),
    Map = #{
        "device_id" => router_device:id(Device),
        "device_name" => router_device:name(Device),
        "device_eui" => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
        "app_eui" => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
        "organization_id" => maps:get(organization_id, Metadata, <<>>)
    },
    bbmustache:render(Template, Map).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

render_topic_test() ->
    DeviceID = <<"device_123">>,
    DevEUI = lorawan_utils:binary_to_hex(<<0, 0, 0, 0, 0, 0, 0, 1>>),
    AppEUI = lorawan_utils:binary_to_hex(<<0, 0, 0, 2, 0, 0, 0, 1>>),
    DeviceUpdates = [
        {name, <<"device_name">>},
        {dev_eui, <<0, 0, 0, 0, 0, 0, 0, 1>>},
        {app_eui, <<0, 0, 0, 2, 0, 0, 0, 1>>},
        {metadata, #{organization_id => <<"org_123">>}}
    ],
    Device = router_device:update(DeviceUpdates, router_device:new(DeviceID)),

    ?assertEqual(
        <<"org_123/device_123">>,
        render_topic(<<"{{organization_id}}/{{device_id}}">>, Device)
    ),
    ?assertEqual(
        <<AppEUI/binary, "/", DevEUI/binary>>,
        render_topic(<<"{{app_eui}}/{{device_eui}}">>, Device)
    ),
    ?assertEqual(
        <<"org_123/device_name">>,
        render_topic(<<"{{organization_id}}/{{device_name}}">>, Device)
    ),
    ok.

-endif.
