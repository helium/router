-module(router_v8_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    invalid_context_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [invalid_context_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

invalid_context_test(_Config) ->
    GoodFunction =
        <<"function Decoder(bytes, port) {\n"
            "  var payload = {\"Testing\": \"42\"};\n"
            "  return payload;\n"
            "}">>,
    BadFunction = <<"function Decoder() { returrrrrrrn 0; }">>,

    {ok, _VMPid} = router_v8:start_link(#{}),
    {ok, VM} = router_v8:get(),
    {ok, Context1} = erlang_v8:create_context(VM),
    {ok, Context2} = erlang_v8:create_context(VM),

    Payload = erlang:binary_to_list(base64:decode(<<"H4Av/xACRU4=">>)),
    Port = 6,
    Result = #{<<"Testing">> => <<"42">>},

    %% Eval good function and ensure function works more than once
    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    ?assertMatch({ok, Result}, erlang_v8:call(VM, Context1, <<"Decoder">>, [Payload, Port])),
    ?assertMatch({ok, Result}, erlang_v8:call(VM, Context1, <<"Decoder">>, [Payload, Port])),

    %% Call undefined function
    ?assertMatch(
        {error, <<"ReferenceError: Decoder is not defined", _/binary>>},
        erlang_v8:call(VM, Context2, <<"Decoder">>, [Payload, Port])
    ),

    %% First Context still works
    ?assertMatch({ok, Result}, erlang_v8:call(VM, Context1, <<"Decoder">>, [Payload, Port])),

    %% Eval bad function
    ?assertMatch({error, crashed}, erlang_v8:eval(VM, Context2, BadFunction)),

    %% First Context no longer works
    ?assertMatch({ok, Result}, erlang_v8:call(VM, Context1, <<"Decoder">>, [Payload, Port])),

    gen_server:stop(_VMPid),
    ok.
