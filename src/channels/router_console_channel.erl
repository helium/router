%%%-------------------------------------------------------------------
%% @doc
%% == Router Console Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_console_channel).

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

-define(ETS, router_console_debug_ets).

-record(state, {channel :: router_channel:channel(),
                device ::router:device()}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    lager:info("init with ~p", [Channel]),
    {ok, #state{channel=Channel, device=Device}}.

handle_event({data, Ref, Data}, #state{channel=Channel, device=Device}=State) ->
    case debug_lookup(router_device:id(Device)) of
        false ->
            ok;
        true ->
            Pid = router_channel:controller(Channel),
            Report = #{status => <<"success">>,
                       description => <<"console debug">>,
                       id => router_channel:id(Channel),
                       name => router_channel:name(Channel),
                       reported_at => erlang:system_time(seconds),
                       debug => #{req => #{body => router_channel:encode_data(Channel, Data)}}},
            router_device_channels_worker:report_status(Pid, Ref, Report)
    end,
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

-spec debug_lookup(binary()) -> boolean().
debug_lookup(DeviceID) ->
    case ets:lookup(?ETS, DeviceID) of
        [] -> false;
        [{DeviceID, Limit}] -> Limit > 0
    end.