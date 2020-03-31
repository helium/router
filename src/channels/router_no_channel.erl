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
init({[Channel, _Device], _}) ->
    lager:info("init with ~p", [Channel]),
    {ok, #state{channel=Channel}}.

handle_event({data, Data}, #state{channel=Channel}=State) ->
    Pid = router_channel:controller(Channel),
    Payload = maps:get(payload, Data),
    Report = #{status => success,
               description => <<"no channels configured">>,
               channel_id => router_channel:id(Channel),
               channel_name => router_channel:name(Channel),
               reported_at => erlang:system_time(seconds),
               category => <<"up">>,
               port => maps:get(port, Data),
               payload => base64:encode(Payload),
               payload_size => erlang:byte_size(Payload),
               hotspots => maps:get(hotspots, Data)},
    router_device_channels_worker:report_channel_status(Pid, Report),
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
