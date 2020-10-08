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
init({[Channel, Device], _}) ->
    lager:md([{device_id, router_device:id(Device)}]),
    lager:info("init with ~p", [Channel]),
    {ok, #state{channel=Channel}}.

handle_event({data, Ref, _Data}, #state{channel=Channel}=State) ->
    Pid = router_channel:controller(Channel),
    Report = #{status => <<"no_channel">>,
               description => <<"no channels configured">>,
               id => router_channel:id(Channel),
               name => router_channel:name(Channel),
               reported_at => erlang:system_time(seconds)},
    router_device_channels_worker:report_status(Pid, Ref, Report),
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
