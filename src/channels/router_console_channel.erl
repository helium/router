%%%-------------------------------------------------------------------
%% @doc
%% == Router Console Channel ==
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_console_channel).

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

-record(state, {
    channel :: router_channel:channel(),
    device :: router:device()
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    ok = router_utils:lager_md(Device),
    lager:info("init with ~p", [Channel]),
    {ok, #state{channel = Channel, device = Device}}.

handle_event({data, UUIDRef, Data}, #state{channel = Channel} = State) ->
    Pid = router_channel:controller(Channel),
    Report = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel),
        status => success,
        description => <<"console debug">>,
        request => #{body => router_channel:encode_data(Channel, Data)}
    },
    ok = router_device_channels_worker:report_request(Pid, UUIDRef, Channel, Report),
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info({ping, _}, State) ->
    {ok, State};
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
