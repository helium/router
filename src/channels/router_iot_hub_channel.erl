%%%-------------------------------------------------------------------
%% @doc
%% == Router IoT Hub Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_iot_hub_channel).

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

-define(PING_TIMEOUT, timer:seconds(25)).
-define(BACKOFF_MIN, timer:seconds(10)).
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    channel :: router_channel:channel(),
    channel_id :: binary(),
    azure :: router_iot_hub_connection:azure(),
    conn_backoff :: backoff:backoff(),
    conn_backoff_ref :: reference() | undefined,
    ping :: reference() | undefined
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    ok = router_utils:lager_md(Device),
    ChannelID = router_channel:unique_id(Channel),
    lager:info("init iot_hub with ~p", [Channel]),
    case setup_iot_hub(Channel) of
        {ok, Account} ->
            Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
            send_connect_after(ChannelID, 0),
            {ok, #state{
                channel = Channel,
                channel_id = ChannelID,
                azure = Account,
                conn_backoff = Backoff
            }};
        Err ->
            lager:warning("could not setup iot_hub connection ~p", [Err]),
            Err
    end.

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
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call({update, Channel, Device}, State) ->
    {swap_handler, ok, swapped, State, router_channel:handler(Channel), [Channel, Device]};
handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info(
    {publish, PublishPayload},
    #state{azure = Azure, channel = Channel, channel_id = ChannelID} = State
) ->
    case router_iot_hub_connection:mqtt_response(Azure, PublishPayload) of
        {ok, Payload} ->
            Controller = router_channel:controller(Channel),
            router_device_channels_worker:handle_downlink(Controller, Payload, Channel);
        {error, _Reason} ->
            lager:warning("[~s] ~p mqtt_response", [ChannelID, _Reason]),
            ok
    end,
    {ok, State};
handle_info(
    {?MODULE, connect, ChannelID},
    #state{channel_id = ChannelID, ping = TimerRef} = State0
) ->
    _ = (catch erlang:cancel_timer(TimerRef)),
    case connect(State0) of
        {ok, State1} ->
            {ok, State1#state{ping = schedule_ping(ChannelID)}};
        {error, State1} ->
            {ok, State1#state{ping = undefined}}
    end;
%% Ignore connect message not for us
handle_info({?MODULE, connect, _}, State) ->
    {ok, State};
handle_info({?MODULE, ping, ChannelID}, #state{channel_id = ChannelID, azure = Azure} = State) ->
    case router_iot_hub_connection:mqtt_ping(Azure) of
        ok ->
            lager:debug("[~s] pinged Azure successfully", [ChannelID]),
            {ok, State#state{ping = schedule_ping(ChannelID)}};
        {error, _Reason} ->
            lager:error("[~s] failed to ping Azure connection: ~p", [ChannelID, _Reason]),
            {ok, reconnect(State)}
    end;
handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

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
    #state{azure = Azure, channel = Channel, channel_id = ChannelID} = State0
) ->
    lager:debug("got data: ~p", [Data]),

    EncodedData = router_channel:encode_data(Channel, Data),
    Response = router_iot_hub_connection:mqtt_publish(Azure, EncodedData),

    RequestReport = make_request_report(Response, Data, State0),
    Pid = router_channel:controller(Channel),
    ok = router_device_channels_worker:report_request(Pid, UUIDRef, Channel, RequestReport),

    State1 =
        case Response of
            {error, failed_to_publish} ->
                lager:error("[~s] failed to publish", [ChannelID]),
                reconnect(State0);
            _ ->
                lager:debug("[~s] published result: ~p data: ~p", [ChannelID, Response, EncodedData]),
                State0
        end,

    ResponseReport = make_response_report(Response, Channel),
    ok = router_device_channels_worker:report_response(Pid, UUIDRef, Channel, ResponseReport),
    State1.

-spec setup_iot_hub(router_channel:channel()) ->
    {ok, router_iot_hub_connection:azure()} | {error, any()}.
setup_iot_hub(Channel) ->
    #{
        azure_hub_name := HubName,
        azure_policy_name := PolicyName,
        azure_policy_key := PolicyKey
    } = router_channel:args(Channel),

    DeviceID = router_channel:device_id(Channel),
    {ok, Account} = router_iot_hub_connection:new(HubName, PolicyName, PolicyKey, DeviceID),

    case router_iot_hub_connection:ensure_device_exists(Account) of
        ok -> {ok, Account};
        Err -> Err
    end.

-spec connect(#state{}) -> {ok | error, #state{}}.
connect(#state{azure = Azure0, conn_backoff = Backoff0, channel_id = ChannelID} = State) ->
    {ok, Azure1} = router_iot_hub_connection:mqtt_cleanup(Azure0),

    case router_iot_hub_connection:mqtt_connect(Azure1) of
        {ok, Azure2} ->
            case router_iot_hub_connection:mqtt_subscribe(Azure2) of
                {ok, _, _} ->
                    lager:info("[~s] connected and subscribed", [ChannelID]),
                    {_, Backoff1} = backoff:succeed(Backoff0),
                    {ok, State#state{
                        conn_backoff = Backoff1,
                        azure = Azure2
                    }};
                {error, _SubReason} ->
                    lager:error("[~s] failed to subscribe: ~p", [ChannelID, _SubReason]),
                    {error, reconnect(State#state{azure = Azure2})}
            end;
        {error, _ConnReason} ->
            lager:error("[~s] failed to connect to: ~p", [ChannelID, _ConnReason]),
            {error, reconnect(State)}
    end.

-spec reconnect(#state{}) -> #state{}.
reconnect(#state{channel_id = ChannelID, conn_backoff = Backoff0} = State) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    TimerRef1 = send_connect_after(ChannelID, Delay),
    State#state{
        conn_backoff = Backoff1,
        conn_backoff_ref = TimerRef1
    }.

-spec schedule_ping(binary()) -> reference().
schedule_ping(ChannelID) ->
    erlang:send_after(?PING_TIMEOUT, self(), {?MODULE, ping, ChannelID}).

-spec send_connect_after(ChannelID :: binary(), Delay :: non_neg_integer()) -> reference().
send_connect_after(ChannelID, Delay) ->
    lager:info("[~s] trying connect in ~p", [ChannelID, Delay]),
    erlang:send_after(Delay, self(), {?MODULE, connect, ChannelID}).

%% ------------------------------------------------------------------
%% Reporting
%% ------------------------------------------------------------------

-spec make_request_report({ok | error, any()}, any(), #state{}) -> map().
make_request_report({error, Reason}, Data, #state{channel = Channel}) ->
    %% Helium Error
    #{
        request => #{
            qos => 0,
            body => router_channel:encode_data(Channel, Data)
        },
        status => error,
        description => erlang:list_to_binary(io_lib:format("Error: ~p", [Reason]))
    };
make_request_report({ok, Response}, Data, #state{channel = Channel}) ->
    Request = #{
        qos => 0,
        body => router_channel:encode_data(Channel, Data)
    },
    case Response of
        {error, Reason} ->
            %% Emqtt Error
            Description = list_to_binary(io_lib:format("Error: ~p", [Reason])),
            #{request => Request, status => error, description => Description};
        ok ->
            #{request => Request, status => success, description => <<"published">>};
        {ok, _} ->
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
    Result0 = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel)
    },

    case Response of
        ok ->
            maps:merge(Result0, #{
                response => #{},
                status => success,
                description => <<"ok">>
            });
        {ok, PacketID} ->
            maps:merge(Result0, #{
                response => #{packet_id => PacketID},
                status => success,
                description => list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))
            });
        {error, Reason} ->
            maps:merge(Result0, #{
                response => #{},
                status => error,
                description => list_to_binary(io_lib:format("~p", [Reason]))
            })
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
