%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Channel Utils ==
%%%
%%% - URL handling
%%% - Template application
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(router_channel_utils).

-include_lib("hackney/include/hackney_lib.hrl").

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([maybe_apply_template/2, make_url/3]).

%% ------------------------------------------------------------------
%% Functions
%% ------------------------------------------------------------------

-spec make_url(
    Base :: binary(),
    Params :: proplists:proplist(),
    Data :: map() | binary()
) -> {binary(), proplists:proplist()}.
make_url(Base, Params, Data) when erlang:is_binary(Data) ->
    #hackney_url{qs = StaticParams0} = HUrl = hackney_url:parse_url(Base),

    StaticParams1 = hackney_url:parse_qs(StaticParams0),
    CombinedParams = StaticParams1 ++ Params,
    ParsedParams = hackney_url:qs(CombinedParams),

    {
        hackney_url:unparse_url(HUrl#hackney_url{qs = ParsedParams}),
        CombinedParams
    };
make_url(Base, DynamicParams0, Data) ->
    #hackney_url{qs = StaticParams0} = HUrl = hackney_url:parse_url(Base),

    StaticParams1 = hackney_url:parse_qs(StaticParams0),
    DynamicParams1 = apply_template_to_qs(DynamicParams0, Data),

    CombinedParams = StaticParams1 ++ DynamicParams1,
    ParsedParams = hackney_url:qs(CombinedParams),

    {
        hackney_url:unparse_url(HUrl#hackney_url{qs = ParsedParams}),
        CombinedParams
    }.

-spec maybe_apply_template(undefined | binary(), map()) -> binary().
maybe_apply_template(undefined, Data) ->
    jsx:encode(Data);
maybe_apply_template(Template, TemplateArgs) ->
    NormalMap = jsx:decode(jsx:encode(TemplateArgs), [return_maps]),
    Data = mk_data_fun(NormalMap, []),
    try bbmustache:render(Template, Data, [{key_type, binary}]) of
        Res -> Res
    catch
        _E:_R ->
            lager:warning("mustache template render failed ~p:~p, Template: ~p Data: ~p", [
                _E,
                _R,
                Template,
                Data
            ]),
            <<"mustache template render failed">>
    end.

%% ------------------------------------------------------------------
%% Internal Functions
%% ------------------------------------------------------------------

-spec apply_template_to_qs(proplists:proplist(), map()) -> list().
apply_template_to_qs(Qs, Data) ->
    lists:map(
        fun({Key, Value}) ->
            {maybe_apply_template(Key, Data), maybe_apply_template(Value, Data)}
        end,
        Qs
    ).

mk_data_fun(Data, FunStack) ->
    fun(Key0) ->
        case parse_key(Key0, FunStack) of
            error ->
                error;
            {NewFunStack, Key} ->
                case kvc:path(Key, Data) of
                    [] ->
                        error;
                    Val when is_map(Val) ->
                        {ok, mk_data_fun(Val, NewFunStack)};
                    Val ->
                        Res = lists:foldl(
                            fun(Fun, Acc) ->
                                Fun(Acc)
                            end,
                            Val,
                            NewFunStack
                        ),
                        {ok, Res}
                end
        end
    end.

parse_key(<<"base64_to_hex(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun base64_to_hex/1 | FunStack]);
parse_key(<<"hex_to_base64(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun hex_to_base64/1 | FunStack]);
parse_key(<<"base64_to_bytes(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun base64_to_bytes/1 | FunStack]);
parse_key(<<"hex_to_bytes(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun hex_to_bytes/1 | FunStack]);
parse_key(<<"bytes_to_list(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun bytes_to_list/1 | FunStack]);
parse_key(<<"epoch_to_iso8601(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun epoch_to_iso8601/1 | FunStack]);
parse_key(Key0, FunStack) ->
    case binary:split(Key0, <<")">>, [trim, global]) of
        [Key] ->
            {FunStack, Key};
        _Other ->
            error
    end.

base64_to_hex(Val) ->
    Bin = base64:decode(Val),
    lorawan_utils:binary_to_hex(Bin).

hex_to_base64(Val) ->
    base64:encode(lorawan_utils:hex_to_binary(Val)).

base64_to_bytes(Val) ->
    base64:decode_to_string(Val).

hex_to_bytes(Val) ->
    binary_to_list(lorawan_utils:hex_to_binary(Val)).

epoch_to_iso8601(Val) ->
    iso8601:format(calendar:system_time_to_universal_time(Val, second)).

bytes_to_list(Val) ->
    list_to_binary(io_lib:format("~w", [Val])).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

url_test_() ->
    [
        ?_assertEqual(
            {
                <<"https://website.com/">>,
                []
            },
            make_url("https://website.com", [], #{})
        ),
        ?_assertEqual(
            {
                <<"https://website.com/?one=two">>,
                [{<<"one">>, <<"two">>}]
            },
            make_url("https://website.com?one=two", [], #{})
        ),
        ?_assertEqual(
            {
                <<"https://website.com/?one=two">>,
                [{<<"one">>, <<"two">>}]
            },
            make_url("https://website.com", [{<<"one">>, <<"two">>}], #{})
        ),
        ?_assertEqual(
            {
                <<"https://website.com/?one=two&three=four">>,
                [{<<"one">>, <<"two">>}, {<<"three">>, <<"four">>}]
            },
            make_url("https://website.com?one=two", [{<<"three">>, <<"four">>}], #{})
        ),
        ?_assertEqual(
            {
                <<"https://website.com/?one=2">>,
                [{<<"one">>, <<"2">>}]
            },
            make_url("https://website.com", [{<<"one">>, <<"{{value}}">>}], #{<<"value">> => 2})
        ),
        ?_assertEqual(
            {
                <<"https://website.com/?one=%7b%7bvalue%7d%7d">>,
                [{<<"one">>, <<"{{value}}">>}]
            },
            make_url("https://website.com?one={{value}}", [], #{<<"value">> => 2})
        ),
        ?_assertEqual(
            {
                <<"https://website.com/?one=42">>,
                [{<<"one">>, <<"42">>}]
            },
            make_url(
                "https://website.com",
                [{<<"one">>, <<"{{deep.value}}">>}],
                #{<<"deep">> => #{<<"value">> => 42}}
            )
        ),
        ?_assertEqual(
            {
                <<"https://website.com/?one=two">>,
                [{<<"one">>, <<"two">>}]
            },
            make_url(
                "https://website.com",
                [{<<"{{key}}">>, <<"{{value}}">>}],
                #{<<"key">> => <<"one">>, <<"value">> => <<"two">>}
            )
        ),
        ?_assertEqual(
            {
                <<"https://127.0.0.1:3000/channel?decoded_param=42&one=yolo_name">>,
                [{<<"decoded_param">>, <<"42">>}, {<<"one">>, <<"yolo_name">>}]
            },
            make_url(
                <<"https://127.0.0.1:3000/channel">>,
                [
                    {<<"decoded_param">>, <<"{{decoded.payload.value}}">>},
                    {<<"one">>, <<"{{name}}">>}
                ],
                jsx:decode(
                    <<"{\"decoded\":{\"payload\":{\"value\":\"42\"}},\"name\":\"yolo_name\"}">>,
                    [return_maps]
                )
            )
        )
    ].

template_test() ->
    Template1 = <<"{{base64_to_hex(foo)}}">>,
    Map1 = #{foo => base64:encode(<<16#deadbeef:32/integer>>)},
    ?assertEqual(<<"DEADBEEF">>, maybe_apply_template(Template1, Map1)),
    Template2 = <<"{{base64_to_hex(foo.bar)}}">>,
    Map2 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(<<"DEADBEEF">>, maybe_apply_template(Template2, Map2)),
    Template3 = <<"{{hex_to_base64(base64_to_hex(foo))}}">>,
    Map3 = #{foo => base64:encode(<<16#deadbeef:32/integer>>)},
    ?assertEqual(base64:encode(<<16#deadbeef:32/integer>>), maybe_apply_template(Template3, Map3)),
    Template4 = <<"{{hex_to_base64(base64_to_hex(foo.bar))}}">>,
    Map4 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(base64:encode(<<16#deadbeef:32/integer>>), maybe_apply_template(Template4, Map4)),
    Template5 = <<"{{hex_to_bytes(base64_to_hex(foo.bar))}}">>,
    Map5 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(<<16#deadbeef:32/integer>>, maybe_apply_template(Template5, Map5)),
    Template6 = <<"{{base64_to_bytes(foo.bar))}}">>,
    Map6 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(<<16#deadbeef:32/integer>>, maybe_apply_template(Template6, Map6)),
    Template7 = <<"{{epoch_to_iso8601(time1)}} {{epoch_to_iso8601(time2)}}">>,
    Map7 = #{time1 => 1111111111, time2 => 1234567890},
    ?assertEqual(
        <<"2005-03-18T01:58:31Z 2009-02-13T23:31:30Z">>,
        maybe_apply_template(Template7, Map7)
    ),
    Template8 = <<"{{bytes_to_list(base64_to_bytes(foo.bar))}}">>,
    Map8 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(
        list_to_binary(io_lib:format("~w", [binary_to_list(<<16#deadbeef:32/integer>>)])),
        maybe_apply_template(Template8, Map8)
    ),
    ok.

-endif.
