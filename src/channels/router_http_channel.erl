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

handle_event({data, Ref, Data}, #state{channel=Channel, url=URL, headers=Headers, method=Method}=State) ->
    lager:debug("got data: ~p", [Data]),
    Body = router_channel:encode_data(Channel, Data),
    Res = make_http_req(Method, URL, Headers, Body),
    lager:debug("published: ~p result: ~p", [Body, Res]),
    Debug = #{req => #{method => Method,
                       url => URL,
                       headers => Headers,
                       body => Body}},
    ok = handle_http_res(Res, Channel, Ref, Debug),
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

-spec make_http_req(atom(), binary(), list(), binary()) -> any().
make_http_req(Method, URL, Headers, Payload) ->
    try hackney:request(Method, URL, Headers, Payload, [with_body]) of
        Res -> Res
    catch
        What:Why:_Stacktrace -> {error, {What, Why}}
    end.

-spec handle_http_res(any(), router_channel:channel(), reference(), map()) -> ok.
handle_http_res(Res, Channel, Ref, Debug) ->
    Pid = router_channel:controller(Channel),
    Result0 = #{id => router_channel:id(Channel),
                name => router_channel:name(Channel),
                reported_at => erlang:system_time(seconds)},
    Result1 = case Res of
                  {ok, StatusCode, ResponseHeaders, <<>>} when StatusCode >= 200, StatusCode =< 300 ->
                      maps:merge(Result0, #{debug => maps:merge(Debug, #{res => #{code => StatusCode,
                                                                                  headers => ResponseHeaders,
                                                                                  body => <<>>}}),
                                            status => success,
                                            description => <<"Connection established">>});
                  {ok, StatusCode, ResponseHeaders, ResponseBody} when StatusCode >= 200, StatusCode =< 300 ->
                      router_device_channels_worker:handle_downlink(Pid, ResponseBody),
                      maps:merge(Result0, #{debug => maps:merge(Debug, #{res => #{code => StatusCode,
                                                                                  headers => ResponseHeaders,
                                                                                  body => ResponseBody}}),
                                            status => success,
                                            description => ResponseBody});
                  {ok, StatusCode, ResponseHeaders, ResponseBody} ->
                      maps:merge(Result0, #{debug => maps:merge(Debug, #{res => #{code => StatusCode,
                                                                                  headers => ResponseHeaders,
                                                                                  body => ResponseBody}}),
                                            status => failure, 
                                            description => <<"ResponseCode: ", (list_to_binary(integer_to_list(StatusCode)))/binary,
                                                             " Body ", ResponseBody/binary>>});
                  {error, Reason} ->
                      maps:merge(Result0, #{debug => maps:merge(Debug, #{res => #{}}),
                                            status => failure,
                                            description => list_to_binary(io_lib:format("~p", [Reason]))})
              end,
    router_device_channels_worker:report_status(Pid, Ref, Result1).
