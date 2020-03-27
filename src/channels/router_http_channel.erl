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
-export([init/1,
         handle_event/2,
         handle_call/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {channel :: router_channel:channel(),
                url :: binary(),
                headers :: list(),
                method :: atom()}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, _Device], _}) ->
    lager:info("init with ~p", [Channel]),
    #{url := URL, headers := Headers0, method := Method} = router_channel:args(Channel),
    Headers1 = lists:ukeymerge(1, lists:ukeysort(1, Headers0),
                               [{<<"Content-Type">>, <<"application/json">>}]),
    {ok, #state{channel=Channel, url=URL, headers=Headers1, method=Method}}.

handle_event({data, Data}, #state{channel=Channel, url=URL, headers=Headers, method=Method}=State) ->
    Res = make_http_req(Method, URL, Headers, encode_data(Data)),
    ok = handle_http_res(Res, Channel, Data),
    lager:debug("published: ~p result: ~p", [Data, Res]),
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call({update, Channel, _Device}, State) ->
    #{url := URL, headers := Headers0, method := Method} = router_channel:args(Channel),
    Headers1 = lists:ukeymerge(1, lists:ukeysort(1, Headers0),
                               [{<<"Content-Type">>, <<"application/json">>}]),
    {ok, ok, State#state{channel=Channel, url=URL, headers=Headers1, method=Method}};
handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

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

-spec encode_data(map()) -> binary().
encode_data(#{payload := Payload}=Map) ->
    jsx:encode(maps:put(payload, base64:encode(Payload), Map)).

-spec make_http_req(atom(), binary(), list(), binary()) -> any().
make_http_req(Method, URL, Headers, Payload) ->
    try hackney:request(Method, URL, Headers, Payload, [with_body]) of
        Res -> Res
    catch
        What:Why:_Stacktrace -> {error, {What, Why}}
    end.

-spec handle_http_res(any(), router_channel:channel(), map()) -> ok.
handle_http_res(Res, Channel, Data) ->
    DeviceWorkerPid = router_channel:device_worker(Channel),
    Payload = maps:get(payload, Data),
    Result0 = #{channel_id => router_channel:id(Channel),
                channel_name => router_channel:name(Channel),
                reported_at => erlang:system_time(seconds),
                category => <<"up">>,
                port => maps:get(port, Data),
                payload => base64:encode(Payload),
                payload_size => erlang:byte_size(Payload),
                hotspots => maps:get(hotspots, Data)},
    Result1 = case Res of
                  {ok, StatusCode, _ResponseHeaders, ResponseBody} when StatusCode >= 200, StatusCode =< 300 ->
                      router_device_worker:handle_downlink(ResponseBody, Channel),
                      maps:merge(Result0, #{status => success, description => ResponseBody});
                  {ok, StatusCode, _ResponseHeaders, ResponseBody} ->
                      maps:merge(Result0, #{status => failure, 
                                            description => <<"ResponseCode: ", (list_to_binary(integer_to_list(StatusCode)))/binary,
                                                             " Body ", ResponseBody/binary>>});
                  {error, Reason} ->
                      maps:merge(Result0, #{status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))})
              end,
    router_device_worker:report_channel_status(DeviceWorkerPid, Result1).
