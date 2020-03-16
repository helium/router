%%%-------------------------------------------------------------------
%% @doc
%% == Router no Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_no_channel).

-behaviour(gen_event).

%% ------------------------------------------------------------------
%% gen_event Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_event/2,
         handle_call/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {channel :: router_channel:channel()}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Channel) ->
    lager:info("init with ~p", [Channel]),
    {ok, #state{channel=Channel}}.

handle_event({data, Data}, #state{channel=Channel}=State) ->
    DeviceWorkerPid = router_channel:device_worker(Channel),
    Payload = maps:get(payload, Data),
    Report = #{status => success,
               description => <<"no channels configured">>,
               channel_id => router_channel:id(Channel),
               channel_name => router_channel:name(Channel),
               port => maps:get(port, Data),
               payload => base64:encode(Payload),
               payload_size => erlang:byte_size(Payload), 
               reported_at => erlang:system_time(seconds),
               rssi => maps:get(rssi, Data),
               snr => maps:get(snr, Data),
               hotspot_name => maps:get(hotspot_name, Data),
               category => <<"up">>,
               frame_up => maps:get(sequence, Data)},
    router_device_worker:report_channel_status(DeviceWorkerPid, Report),
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
