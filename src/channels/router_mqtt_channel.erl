%%%-------------------------------------------------------------------
%% @doc
%% == Router MQTT Channel ==
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
-export([init/1,
         handle_event/2,
         handle_call/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(PING_TIMEOUT, timer:seconds(25)).

-record(state, {channel :: router_channel:channel(),
                connection :: pid(),
                endpoint :: binary(),
                pub_topic :: binary(),
                sub_topic :: binary(),
                ping :: reference()}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    lager:md([{device_id, router_device:id(Device)}]),
    lager:info("~p init with ~p", [?MODULE, Channel]),
    DeviceID = router_channel:device_id(Channel),
    ChannelName = router_channel:name(Channel),
    #{endpoint := Endpoint,
      uplink_topic := UplinkTemplate,
      downlink_topic := DownlinkTemplate} = router_channel:args(Channel),
    %% Render topic mustache template 
    UplinkTopic = render_topic(UplinkTemplate, Device),
    DownlinkTopic = render_topic(DownlinkTemplate, Device),
    case connect(Endpoint, DeviceID, ChannelName) of
        {ok, Conn} ->
            %% Crash if we can't subscribe so that will be caught and reported to user via console 
            {ok, _, _} = emqtt:subscribe(Conn, DownlinkTopic, 0),
            {ok, #state{channel=Channel,
                        connection=Conn,
                        endpoint=Endpoint,
                        pub_topic=UplinkTopic,
                        sub_topic=DownlinkTopic,
                        ping=ping(Conn)}};
        {error, Reason} ->
            {error, Reason}
    end.

handle_event({data, Ref, Data}, #state{channel=Channel, connection=Conn, endpoint=Endpoint, pub_topic=Topic}=State) ->
    Body = router_channel:encode_data(Channel, Data),
    Res = emqtt:publish(Conn, Topic, Body, 0),
    lager:debug("published: ~p result: ~p", [Data, Res]),
    Debug = #{req => #{endpoint => Endpoint,
                       topic => Topic,
                       qos => 0,
                       body => Body}},
    ok = handle_publish_res(Res, Channel, Ref, Debug),
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call({update, Channel, Device}, #state{connection=Conn,
                                              endpoint=StateEndpoint,
                                              pub_topic=StatePubTopic,
                                              sub_topic=StateSubTopic}=State) ->
    #{endpoint := Endpoint,
      uplink_topic := UplinkTemplate,
      downlink_topic := DownlinkTemplate} = router_channel:args(Channel),
    UplinkTopic = render_topic(UplinkTemplate, Device),
    DownlinkTopic = render_topic(DownlinkTemplate, Device),
    case Endpoint == StateEndpoint of
        false ->
            {swap_handler, ok, swapped, State, router_channel:handler(Channel), [Channel, Device]};
        true ->
            case DownlinkTopic == StateSubTopic andalso UplinkTopic == StatePubTopic of
                true ->
                    {ok, ok, State};
                false ->
                    {ok, _, _} = emqtt:unsubscribe(Conn, StateSubTopic),
                    {ok, _, _} = emqtt:subscribe(Conn, DownlinkTopic, 0),
                    {ok, ok, State#state{pub_topic=UplinkTopic, sub_topic=DownlinkTopic}}
            end
    end;
handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info({publish, #{client_pid := Pid, payload := Payload}}, #state{connection=Pid, channel=Channel}=State) ->
    Controller = router_channel:controller(Channel),
    router_device_channels_worker:handle_downlink(Controller, Payload, mqtt),
    {ok, State};
handle_info({ping, Conn}, #state{connection=Conn, ping=TimerRef}=State) ->
    _ = erlang:cancel_timer(TimerRef),
    pong = (catch emqtt:ping(Conn)),
    lager:debug("pinging MQTT connection ~p", [Conn]),
    {ok, State#state{ping=ping(Conn)}};
handle_info({disconnected, _Type, _Reason}, #state{channel=Channel, endpoint=Endpoint,
                                                  sub_topic=DownlinkTopic, ping=TimerRef}=State) ->
    _ = erlang:cancel_timer(TimerRef),
    DeviceID = router_channel:device_id(Channel),
    ChannelName = router_channel:name(Channel),
    {ok, Conn} = connect(Endpoint, DeviceID, ChannelName),
    {ok, _, _} = emqtt:subscribe(Conn, DownlinkTopic, 0),
    {ok, State#state{connection=Conn, ping=ping(Conn)}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{connection=Conn}) ->
    (catch emqtt:disconnect(Conn)),
    (catch emqtt:stop(Conn)),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec render_topic(binary(), router_device:device()) -> binary().
render_topic(Template, Device) ->
    Metadata = router_device:metadata(Device),
    Map = #{"device_id" => router_device:id(Device),
            "device_eui" => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
            "app_eui" => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
            "organization_id" => maps:get(organization_id, Metadata, <<>>)},
    bbmustache:render(Template, Map).

-spec ping(pid()) -> reference().
ping(Conn) ->
    erlang:send_after(?PING_TIMEOUT, self(), {ping, Conn}).

-spec handle_publish_res(any(), router_channel:channel(), reference(), map()) -> ok.
handle_publish_res(Res, Channel, Ref, Debug) ->
    Pid = router_channel:controller(Channel),
    Result0 = #{id => router_channel:id(Channel),
                name => router_channel:name(Channel),
                reported_at => erlang:system_time(seconds)},
    Result1 = case Res of
                  {ok, PacketID} ->
                      maps:merge(Result0, #{debug => maps:merge(Debug, #{res => #{packet_id => PacketID}}),
                                            status => success,
                                            description => list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))});
                  ok ->
                      maps:merge(Result0, #{debug => maps:merge(Debug, #{res => #{}}),
                                            status => success,
                                            description => <<"ok">>});
                  {error, Reason} ->
                      maps:merge(Result0, #{debug => maps:merge(Debug, #{res => #{}}),
                                            status => failure,
                                            description => list_to_binary(io_lib:format("~p", [Reason]))})
              end,
    router_device_channels_worker:report_status(Pid, Ref, Result1).

-spec connect(binary(), binary(), any()) -> {ok, pid()} | {error, term()}.
connect(URI, DeviceID, Name) ->
    Opts = [{scheme_defaults, [{mqtt, 1883}, {mqtts, 8883} | http_uri:scheme_defaults()]}, {fragment, false}],
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
            {Username, Password} = case binary:split(UserInfo, <<":">>) of
                                       [Un, <<>>] -> {Un, undefined};
                                       [Un, Pw] -> {Un, Pw};
                                       [<<>>] -> {undefined, undefined};
                                       [Un] -> {Un, undefined}
                                   end,
            EmqttOpts = [{host, erlang:binary_to_list(Host)},
                         {port, Port},
                         {clientid, DeviceID}] ++
                [{username, Username} || Username /= undefined] ++
                [{password, Password} || Password /= undefined] ++
                [{clean_start, false},
                 {keepalive, 30},
                 {ssl, Scheme == mqtts}],
            {ok, C} = emqtt:start_link(EmqttOpts),
            case emqtt:connect(C) of
                {ok, _Props} ->
                    lager:info("connect returned ~p", [_Props]),
                    {ok, C};
                {error, Reason} ->
                    lager:info("Failed to connect to ~p ~p : ~p", [Host, Port,
                                                                   Reason]),
                    {error, Reason}
            end;
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s ~p", [URI, Name]),
            {error, invalid_mqtt_uri}
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

render_topic_test() ->
    DeviceID = <<"device_123">>,
    DevEUI = lorawan_utils:binary_to_hex(<<0,0,0,0,0,0,0,1>>),
    AppEUI = lorawan_utils:binary_to_hex(<<0,0,0,2,0,0,0,1>>),
    DeviceUpdates = [{dev_eui, <<0,0,0,0,0,0,0,1>>},
                     {app_eui, <<0,0,0,2,0,0,0,1>>},
                     {metadata, #{organization_id => <<"org_123">>}}],
    Device = router_device:update(DeviceUpdates, router_device:new(DeviceID)),

    ?assertEqual(<<"org_123/device_123">>, render_topic(<<"{{organization_id}}/{{device_id}}">>, Device)),
    ?assertEqual(<<AppEUI/binary, "/", DevEUI/binary>>, render_topic(<<"{{app_eui}}/{{device_eui}}">>, Device)),
    ok.

-endif.
