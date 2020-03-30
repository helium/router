%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Channels Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_channels_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(BACKOFF_MIN, timer:seconds(15)).
-define(BACKOFF_MAX, timer:minutes(5)).
-define(BACKOFF_INIT,
        {backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
         erlang:make_ref()}).

-record(state, {event_mgr :: pid(),
                device_worker :: pid(),
                device :: router_device:device(),
                channels = #{} :: map(),
                channels_backoffs = #{} :: map()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    DeviceWorker = maps:get(device_worker, Args),
    Device = maps:get(device, Args),
    {ok, EventMgrRef} = router_channel:start_link(),
    self() ! refresh_channels,
    {ok, #state{event_mgr=EventMgrRef, device_worker=DeviceWorker, device=Device}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(refresh_channels, #state{device=Device, event_mgr=EventMgrRef, channels=Channels0}=State) ->
    APIChannels = lists:foldl(
                    fun(Channel, Acc) ->
                            ID = router_channel:id(Channel),
                            maps:put(ID, Channel, Acc)
                    end,
                    #{},
                    router_device_api:get_channels(Device, self())),
    Channels1 =
        case maps:size(APIChannels) == 0 of
            true ->
                %% API returned no channels removing all of them and adding the "no channel"
                lists:foreach(
                  fun({router_no_channel, <<"no_channel">>}) -> ok;
                     (Handler) -> gen_event:delete_handler(EventMgrRef, Handler, [])
                  end,
                  gen_event:which_handlers(EventMgrRef)),
                NoChannel = maybe_start_no_channel(Device, EventMgrRef),
                #{router_channel:id(NoChannel) => NoChannel};
            false ->
                %% Start channels asynchronously 
                lists:foreach(
                  fun(Channel) -> self() ! {start_channel, Channel} end,
                  maps:values(APIChannels)),
                %% Removing old channels left in cache but not in API call
                remove_old_channels(EventMgrRef, APIChannels, Channels0)

        end,
    _ = erlang:send_after(?BACKOFF_MAX, self(), refresh_channels),
    {noreply, State#state{channels=Channels1}};
handle_info({start_channel, Channel}, #state{device=Device, event_mgr=EventMgrRef,
                                             channels=Channels, channels_backoffs=Backoffs0}=State) ->
    ChannelID = router_channel:id(Channel),
    case maps:get(ChannelID, Channels, undefined) of
        undefined ->
            case start_channel(EventMgrRef, Channel, Device, Backoffs0) of
                {ok, Backoffs1} ->
                    {noreply, State#state{channels=maps:put(ChannelID, Channel, Channels),
                                          channels_backoffs=Backoffs1}};
                {error, _Reason, Backoffs1} ->
                    {noreply, State#state{channels_backoffs=Backoffs1}}
            end;
        CachedChannel ->
            ChannelHash = router_channel:hash(Channel),
            case router_channel:hash(CachedChannel) of
                ChannelHash ->
                    lager:info("channel ~p already started", [ChannelID]),
                    {noreply, State};
                _OldHash ->
                    lager:info("updating channel ~p", [ChannelID]),
                    case update_channel(EventMgrRef, Channel, Device, Backoffs0) of  
                        {ok, Backoffs1} ->
                            lager:info("channel ~p updated", [ChannelID]),
                            {noreply, State#state{channels=maps:put(ChannelID, Channel, Channels),
                                                  channels_backoffs=Backoffs1}};
                        {error, _Reason, Backoffs1} ->
                            {noreply, State#state{channels=maps:remove(ChannelID, Channels),
                                                  channels_backoffs=Backoffs1}}
                    end
            end
    end;
handle_info({gen_event_EXIT, {_Handler, ChannelID}, ExitReason}, #state{device=Device, channels=Channels,
                                                                        event_mgr=EventMgrRef,
                                                                        channels_backoffs=Backoffs0}=State) ->
    case ExitReason of
        {swapped, _NewHandler, _Pid} ->
            lager:info("channel ~p got swapped ~p", [ChannelID, {_NewHandler, _Pid}]),
            {noreply, State};
        R when R == normal orelse R == shutdown ->
            lager:info("channel ~p went down normally", [ChannelID]),
            {noreply, State#state{channels=maps:remove(ChannelID, Channels),
                                  channels_backoffs=maps:remove(ChannelID, Backoffs0)}};
        Error ->
            Channel = maps:get(ChannelID, Channels),
            ChannelName = router_channel:name(Channel),
            lager:error("channel ~p crashed: ~p", [{ChannelID, ChannelName}, Error]),
            router_device_api:report_channel_status(Device, #{channel_id => ChannelID, channel_name => ChannelName,
                                                              status => failure, category => <<"channel_crash">>,
                                                              description => list_to_binary(io_lib:format("~p", [Error]))}),
            case start_channel(EventMgrRef, Channel, Device, Backoffs0) of  
                {ok, Backoffs1} ->
                    {noreply, State#state{channels_backoffs=Backoffs1}};
                {error, _Reason, Backoffs1} ->
                    {noreply, State#state{channels=maps:remove(ChannelID, Channels),
                                          channels_backoffs=Backoffs1}}
            end
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


-spec start_channel(pid(), router_channel:channel(), router_device:device(), map()) -> {ok, map()} | {error, any(), map()}.
start_channel(EventMgrRef, Channel, Device, Backoffs) ->
    ChannelID = router_channel:id(Channel),
    ChannelName = router_channel:name(Channel),
    case router_channel:add(EventMgrRef, Channel, Device) of
        ok ->
            lager:info("channel ~p started", [{ChannelID, ChannelName}]),
            {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs, ?BACKOFF_INIT),
            _ = erlang:cancel_timer(TimerRef0),
            {_Delay, Backoff1} = backoff:succeed(Backoff0),
            {ok, maps:put(ChannelID, {Backoff1, erlang:make_ref()}, Backoffs)};
        {E, Reason} when E == 'EXIT'; E == error ->
            router_device_api:report_channel_status(Device,
                                                    #{channel_id => ChannelID,
                                                      channel_name => ChannelName,
                                                      status => failure, category => <<"start_channel_failure">>,
                                                      description => list_to_binary(io_lib:format("~p ~p", [E, Reason]))}),
            {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs, ?BACKOFF_INIT),
            _ = erlang:cancel_timer(TimerRef0),
            {Delay, Backoff1} = backoff:fail(Backoff0),
            TimerRef1 = erlang:send_after(Delay, self(), {start_channel, Channel}),
            lager:error("failed to start channel ~p: ~p, retrying in ~pms", [{ChannelID, ChannelName}, {E, Reason}, Delay]),
            {error, Reason, maps:put(ChannelID, {Backoff1, TimerRef1}, Backoffs)}
    end.

-spec update_channel(pid(), router_channel:channel(), router_device:device(), map()) -> {ok, map()} | {error, any(), map()}.
update_channel(EventMgrRef, Channel, Device, Backoffs) ->
    ChannelID = router_channel:id(Channel),
    ChannelName = router_channel:name(Channel),
    case router_channel:update(EventMgrRef, Channel, Device) of
        ok ->
            lager:info("channel ~p updated", [{ChannelID, ChannelName}]),
            {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs, ?BACKOFF_INIT),
            _ = erlang:cancel_timer(TimerRef0),
            {_Delay, Backoff1} = backoff:succeed(Backoff0),
            {ok, maps:put(ChannelID, {Backoff1, erlang:make_ref()}, Backoffs)};
        {E, Reason} when E == 'EXIT'; E == error ->
            lager:error("failed to update channel ~p: ~p", [{ChannelID, ChannelName}, {E, Reason}]),
            router_device_api:report_channel_status(Device,
                                                    #{channel_id => ChannelID,
                                                      channel_name => ChannelName,
                                                      status => failure, category => <<"update_channel_failure">>,
                                                      description => list_to_binary(io_lib:format("~p ~p", [E, Reason]))}),
            {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs, ?BACKOFF_INIT),
            _ = erlang:cancel_timer(TimerRef0),
            {Delay, Backoff1} = backoff:fail(Backoff0),
            TimerRef1 = erlang:send_after(Delay, self(), {start_channel, Channel}),
            {error, Reason, maps:put(ChannelID, {Backoff1, TimerRef1}, Backoffs)}
    end.

-spec remove_old_channels(pid(), map(), map()) -> map().
remove_old_channels(EventMgrRef, APIChannels, Channels) ->
    maps:filter(
      fun(ChannelID, Channel) ->
              case maps:get(ChannelID, APIChannels, undefined) of
                  undefined ->
                      ok = router_channel:delete(EventMgrRef, Channel),
                      false;
                  _ ->
                      true
              end
      end,
      Channels).

-spec maybe_start_no_channel(router_device:device(), pid()) -> router_channel:channel().
maybe_start_no_channel(Device, EventMgrRef) ->
    Handlers = gen_event:which_handlers(EventMgrRef),
    NoChannel = router_channel:new(<<"no_channel">>,
                                   router_no_channel,
                                   <<"no_channel">>,
                                   #{},
                                   router_device:id(Device),
                                   self()),
    case lists:keyfind(router_no_channel, 1, Handlers) of
        {router_no_channel, _} -> noop;
        _ -> router_channel:add(EventMgrRef, NoChannel, Device)
    end,
    NoChannel.
