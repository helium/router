%%%-------------------------------------------------------------------
%% @doc
%% == Router HTTP Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_http_channel).

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

-define(SERVER, ?MODULE).

-record(state, {channel :: router_channel:channel(),
                url :: binary(),
                headers :: list(),
                method :: atom()}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Channel) ->
    lager:info("init with ~p", [Channel]),
    #{url := URL, headers := Headers, method := Method} = router_channel:args(Channel),
    {ok, #state{channel=Channel, url=URL, headers=Headers, method=Method}}.

handle_event({data, Data}, #state{channel=Channel, url=URL, headers=Headers, method=Method}=State) ->
    DeviceID = router_channel:device_id(Channel),
    ID = router_channel:id(Channel),
    Fcnt = maps:get(sequence, Data),
    Payload = jsx:encode(Data),
    case router_channel:dupes(Channel) of
        true ->
            Res = hackney:request(Method, URL, Headers, Payload, [with_body]),
            lager:info("published: ~p result: ~p", [Data, Res]);
        false ->
            case throttle:check(packet_dedup, {DeviceID, ID, Fcnt}) of
                {ok, _, _} ->
                    Res = hackney:request(Method, URL, Headers, Payload, [with_body]),
                    lager:info("published: ~p result: ~p", [Data, Res]);
                _ ->
                    lager:debug("ignornign duplicate ~p", [Data])
            end
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
