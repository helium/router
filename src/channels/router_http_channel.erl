%%%-------------------------------------------------------------------
%% @doc
%% == Router HTTP Channel ==
%%
%% Send packet data to a User's Http endpoint.
%% Responses are queued as downlinks for their device.
%%
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

-define(IPV6_128, inet_cidr:parse("::1/128")).
-define(IPV6_10, inet_cidr:parse("fe80::/10")).
-define(IPV6_7, inet_cidr:parse("fc00::/7")).

-record(state, {
    channel :: router_channel:channel(),
    url :: binary(),
    headers :: list(),
    method :: atom()
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    ok = router_utils:lager_md(Device),
    lager:info("init with ~p", [Channel]),
    #{url := URL, headers := Headers0, method := Method} = router_channel:args(Channel),
    Headers1 = content_type_or_default(Headers0),
    {ok, #state{channel = Channel, url = URL, headers = Headers1, method = Method}}.

handle_event(
    {data, Ref, Data},
    #state{channel = Channel, url = URL, headers = Headers, method = Method} = State
) ->
    lager:debug("got data: ~p", [Data]),
    DownlinkURL = router_console_api:get_downlink_url(Channel, maps:get(id, Data)),
    Body = router_channel:encode_data(Channel, maps:merge(Data, #{downlink_url => DownlinkURL})),
    Res = make_http_req(Method, URL, Headers, Body),
    lager:debug("published: ~p result: ~p", [Body, Res]),
    Request = #{
        method => Method,
        url => URL,
        headers => Headers,
        body => Body
    },
    ok = handle_http_res(Res, Channel, Ref, Request),
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call({update, Channel, _Device}, State) ->
    #{url := URL, headers := Headers0, method := Method} = router_channel:args(Channel),
    Headers1 = content_type_or_default(Headers0),
    {ok, ok, State#state{channel = Channel, url = URL, headers = Headers1, method = Method}};
handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

%% Ignore connect message not for us
handle_info({_, ping, _}, State) ->
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

-spec make_http_req(atom(), binary(), list(), binary()) -> any().
make_http_req(Method, URL, Headers, Payload) ->
    case check_url(URL, application:get_env(router, router_http_channel_url_check, true)) of
        {error, _Reason} = Error ->
            Error;
        ok ->
            try hackney:request(Method, URL, Headers, Payload, [with_body]) of
                Res -> Res
            catch
                _What:_Why:_Stacktrace ->
                    lager:warning("failed http req ~p,  What: ~p Why: ~p / ~p", [
                        {Method, URL, Headers, Payload},
                        _What,
                        _Why,
                        _Stacktrace
                    ]),
                    {error, http_req_failed}
            end
    end.

-spec check_url(URL :: binary(), boolean()) -> ok | {error, any()}.
check_url(_URL, false) ->
    ok;
check_url(URL, true) ->
    Opts = [
        {scheme_defaults, [{http, 80}, {https, 443}]},
        {fragment, false}
    ],
    case http_uri:parse(URL, Opts) of
        {error, _Reason} ->
            lager:info("got bad URL ~p ~p", [URL, _Reason]),
            {error, bad_url};
        {ok, {_Scheme, _UserInfo, BinHost, _Port, _Path, _Query}} ->
            Host = erlang:binary_to_list(BinHost),
            case is_non_local_address(Host) of
                {error, _Reason} ->
                    lager:info("got bad Host ~p ~p", [Host, _Reason]),
                    {error, bad_host};
                ok ->
                    case inet_res:resolve(Host, any, a) of
                        {error, _Reason} ->
                            lager:info("got bad dns record ~p ~p", [Host, _Reason]),
                            {error, bad_dns};
                        {ok, _} ->
                            ok
                    end
            end
    end.

-spec is_non_local_address(Host :: list()) -> ok | {error, any()}.
is_non_local_address(Host) ->
    case inet:parse_address(Host) of
        {error, _Reason} ->
            ok;
        {ok, {127, _, _, _}} ->
            {error, local_address};
        {ok, {10, _, _, _}} ->
            {error, local_address};
        {ok, {192, 168, _, _}} ->
            {error, local_address};
        {ok, {169, 254, _, _}} ->
            {error, local_address};
        {ok, {172, Byte2, _, _}} ->
            case lists:member(Byte2, lists:seq(16, 31)) of
                true ->
                    {error, local_address};
                false ->
                    ok
            end;
        {ok, {_, _, _, _, _, _, _, _} = IPV6} ->
            case
                inet_cidr:contains(?IPV6_128, IPV6) orelse
                    inet_cidr:contains(?IPV6_10, IPV6) orelse
                    inet_cidr:contains(?IPV6_7, IPV6)
            of
                true -> {error, local_address};
                false -> ok
            end;
        {ok, _} ->
            ok
    end.

-spec handle_http_res(any(), router_channel:channel(), router_utils:uuid_v4(), map()) -> ok.
handle_http_res(Res, Channel, UUIDRef, Request) ->
    Pid = router_channel:controller(Channel),
    Result0 = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel),
        request => Request
    },
    Result1 =
        case Res of
            {ok, StatusCode, ResponseHeaders, <<>>} when StatusCode >= 200, StatusCode =< 300 ->
                maps:merge(Result0, #{
                    response => #{
                        code => StatusCode,
                        headers => ResponseHeaders,
                        body => <<>>
                    },
                    status => success,
                    description => <<"Connection established">>
                });
            {ok, StatusCode, ResponseHeaders, ResponseBody} when
                StatusCode >= 200, StatusCode =< 300
            ->
                router_device_channels_worker:handle_downlink(Pid, ResponseBody, Channel),
                maps:merge(Result0, #{
                    response => #{
                        code => StatusCode,
                        headers => ResponseHeaders,
                        body => ResponseBody
                    },
                    status => success,
                    description => ResponseBody
                });
            {ok, StatusCode, ResponseHeaders, ResponseBody} ->
                SCBin = erlang:integer_to_binary(StatusCode),
                maps:merge(Result0, #{
                    response => #{
                        code => StatusCode,
                        headers => ResponseHeaders,
                        body => ResponseBody
                    },
                    status => failure,
                    description => <<"ResponseCode: ", SCBin/binary, " Body ", ResponseBody/binary>>
                });
            {error, Reason} ->
                maps:merge(Result0, #{
                    response => #{},
                    status => failure,
                    description => list_to_binary(io_lib:format("~p", [Reason]))
                })
        end,
    router_device_channels_worker:report_status(Pid, UUIDRef, Result1).

-spec content_type_or_default(list()) -> list().
content_type_or_default(Headers) ->
    lists:ukeysort(1, Headers ++ [{<<"Content-Type">>, <<"application/json">>}]).
