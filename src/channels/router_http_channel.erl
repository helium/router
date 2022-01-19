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
    url_params :: list(),
    method :: atom()
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    ok = router_utils:lager_md(Device),
    lager:info("init with ~p", [Channel]),
    Args = #{url := URL, headers := Headers0, method := Method} = router_channel:args(Channel),
    UrlParams = maps:get(url_params, Args, []),
    Headers1 = content_type_or_default(Headers0),
    {ok, #state{
        channel = Channel,
        url = URL,
        headers = Headers1,
        method = Method,
        url_params = UrlParams
    }}.

handle_event({join, UUIDRef, Data}, #state{channel = Channel} = State0) ->
    State1 =
        case router_channel:receive_joins(Channel) of
            true -> do_handle_event(UUIDRef, Data, State0);
            false -> State0
        end,
    {ok, State1};
handle_event({data, UUIDRef, Data}, State0) ->
    State1 = do_handle_event(UUIDRef, Data, State0),
    {ok, State1};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call({update, Channel, _Device}, State) ->
    Args = #{url := URL, headers := Headers0, method := Method} = router_channel:args(Channel),
    UrlParams = maps:get(url_params, Args, []),
    Headers1 = content_type_or_default(Headers0),
    {ok, ok, State#state{
        channel = Channel,
        url = URL,
        headers = Headers1,
        method = Method,
        url_params = UrlParams
    }};
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

-spec do_handle_event(
    UUIDRef :: router_utils:uuid_v4(),
    Data :: map(),
    #state{}
) -> #state{}.
do_handle_event(
    UUIDRef,
    Data,
    #state{
        channel = Channel,
        url = URL0,
        headers = Headers,
        method = Method,
        url_params = UrlParams
    } = State
) ->
    lager:debug("got data: ~p", [Data]),
    Pid = router_channel:controller(Channel),
    DownlinkURL = router_console_api:get_downlink_url(Channel, maps:get(id, Data)),
    Body = router_channel:encode_data(Channel, maps:merge(Data, #{downlink_url => DownlinkURL})),

    {URL1, SentParams} =
        case jsx:is_json(Body) of
            true ->
                router_channel_utils:make_url(URL0, UrlParams, jsx:decode(Body, [return_maps]));
            false ->
                router_channel_utils:make_url(URL0, UrlParams, Body)
        end,
    Res = make_http_req(Method, URL1, Headers, Body),

    RequestReport = make_request_report(Res, Body, SentParams, State),
    ok = router_device_channels_worker:report_request(Pid, UUIDRef, Channel, RequestReport),

    case Res of
        {ok, {ok, StatusCode, _Headers, ResponseBody}} when StatusCode >= 200, StatusCode =< 300 ->
            ok = router_device_channels_worker:handle_downlink(Pid, ResponseBody, Channel);
        _ ->
            ok
    end,

    lager:debug("published: ~p result: ~p", [Body, Res]),

    ResponseReport = make_response_report(Res, Channel),
    ok = router_device_channels_worker:report_response(Pid, UUIDRef, Channel, ResponseReport),
    State.

-spec url_check_enabled() -> boolean().
url_check_enabled() ->
    case application:get_env(router, router_http_channel_url_check, true) of
        "false" -> false;
        false -> false;
        _ -> true
    end.

-spec make_http_req(atom(), binary(), list(), binary()) -> any().
make_http_req(Method, URL, Headers, Payload) ->
    case check_url(URL, url_check_enabled()) of
        {error, _Reason} = Error ->
            Error;
        ok ->
            try
                hackney:request(Method, URL, Headers, Payload, [
                    with_body,
                    {timeout, timer:seconds(2)}
                ])
            of
                Res -> {ok, Res}
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
    case uri_string:parse(URL) of
        #{
            host := BinHost,
            scheme := Scheme
        } when
            Scheme == <<"http">> orelse
                Scheme == <<"https">>
        ->
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
            end;
        _ ->
            lager:info("got bad URL ~p", [URL]),
            {error, bad_url}
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

-spec make_request_report(
    HeliumError | HackneyResponse,
    Body :: any(),
    UrlParams :: proplists:proplist(),
    State :: #state{}
) -> map() when
    HeliumError :: {error, atom()},
    HackneyResponse :: {ok, any()}.
make_request_report({error, Reason}, Body, UrlParams, #state{
    method = Method,
    url = URL,
    headers = Headers
}) ->
    %% Helium Error
    #{
        request => #{
            method => Method,
            url => URL,
            headers => Headers,
            url_params => UrlParams,
            body => Body
        },
        status => error,
        description => erlang:list_to_binary(io_lib:format("Error: ~p", [Reason]))
    };
make_request_report({ok, Response}, Body, UrlParams, #state{
    method = Method,
    url = URL,
    headers = Headers
}) ->
    Request = #{
        method => Method,
        url => URL,
        headers => Headers,
        url_params => UrlParams,
        body => Body
    },
    case Response of
        {error, Reason} ->
            %% Hackney Error
            #{
                status => error,
                description => erlang:list_to_binary(io_lib:format("Error: ~p", [Reason])),
                request => Request
            };
        {ok, _, _, _} ->
            #{
                request => Request,
                status => success
            }
    end.

-spec make_response_report(HeliumError | HackneyResponse, router_channel:channel()) -> map() when
    HeliumError :: {error, atom()},
    HackneyResponse :: {ok, any()}.
make_response_report({error, Reason}, Channel) ->
    %% Helium Error
    #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel),
        response => #{},
        status => error,
        description => list_to_binary(io_lib:format("Error: ~p", [Reason]))
    };
make_response_report({ok, Res}, Channel) ->
    Result0 = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel)
    },

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
        {ok, StatusCode, ResponseHeaders, ResponseBody} when StatusCode >= 200, StatusCode =< 300 ->
            maps:merge(Result0, #{
                response => #{
                    code => StatusCode,
                    headers => ResponseHeaders,
                    body => ResponseBody
                },
                status => success,
                description => <<"Connection Success">>
            });
        {ok, StatusCode, ResponseHeaders, ResponseBody} ->
            SCBin = erlang:integer_to_binary(StatusCode),
            maps:merge(Result0, #{
                response => #{
                    code => StatusCode,
                    headers => ResponseHeaders,
                    body => ResponseBody
                },
                status => error,
                description => <<"Error ResponseCode: ", SCBin/binary>>
            });
        {error, Reason} ->
            %% Hackney Error
            maps:merge(Result0, #{
                response => #{},
                status => error,
                description => list_to_binary(io_lib:format("Error: ~p", [Reason]))
            })
    end.

-spec content_type_or_default(list()) -> list().
content_type_or_default(Headers) ->
    lists:ukeysort(1, Headers ++ [{<<"Content-Type">>, <<"application/json">>}]).
