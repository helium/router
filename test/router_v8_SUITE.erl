-module(router_v8_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    invalid_context_test/1,
    browan_decoder_test/1,
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
    [invalid_context_test, browan_decoder_test].

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
        <<
            "function Decoder(bytes, port) {\n"
            "  var payload = {\"Testing\": \"42\"};\n"
            "  return payload;\n"
            "}"
        >>,
    BadFunction = <<"function Decoder() { returrrrrrrn 0; }">>,

    VMPid =
        case router_v8:start_link(#{}) of
            {ok, Pid} -> Pid;
            {error, {already_started, Pid}} -> Pid
        end,
    {ok, VM} = router_v8:get(),
    {ok, Context1} = erlang_v8:create_context(VM),
    {ok, Context2} = erlang_v8:create_context(VM),
    ?assertNotMatch(Context1, Context2),

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

    %% Upon an error (other than invalid_source_size), v8 Port gets
    %% killed and restarted
    ?assertMatch(true, erlang:is_process_alive(VMPid)),

    %% Unintuitively, we get invalid context when attempting to reuse first Context:
    ?assertMatch(
        {error, invalid_context},
        erlang_v8:call(VM, Context1, <<"Decoder">>, [Payload, Port])
    ),
    %% But that's because set of Context needs to be repopulated within V8's VM:
    erlang_v8:restart_vm(VM),

    %% First Context no longer works-- not ideal behavior but what we
    %% have at hand.  Ideally, return value would still match `Result'.
    ?assertMatch(
        {error, invalid_context},
        erlang_v8:call(VM, Context1, <<"Decoder">>, [Payload, Port])
    ),

    gen_server:stop(VMPid),
    ok.

browan_decoder_test(_Config) ->
    GoodFunction =
        <<
            ""
            "function Decoder(bytes, port, uplink_info) {\n"
            "  if (port == 136 && bytes.length == 11) {\n"
            "    const positionLat = ((bytes[6] << 24 | bytes[5] << 16) | bytes[4] << 8) | bytes[3]\n"
            ""
            "    const accuracy = Math.trunc(Math.pow((bytes[10] >> 5) + 2, 2))\n"
            "    bytes[10] &= 0x1f;\n"
            "    if ((bytes[10] & 0x10) !== 0) {\n"
            "      bytes[10] |= 0xe0;\n"
            "    }\n"
            "    const positionLon = ((bytes[10] << 24 | bytes[9] << 16) | bytes[8] << 8) | bytes[7]\n"
            ""
            "    return {\n"
            "      gns_error: (bytes[0] & 0x10) >>> 4 == 1,\n"
            "      gns_fix: (bytes[0] & 0x08) >>> 3 == 1,\n"
            "      moving: (bytes[0] & 0x02) >>> 1 == 1,\n"
            "      button: (bytes[0] & 0x01) == 1,\n"
            "      battery_percent: 100 * ((bytes[1] >>> 4) / 15),\n"
            "      battery: ((bytes[1] & 0x0f) + 25) / 10,\n"
            "      temperature: bytes[2] & 0x7f - 32,\n"
            "      latitude: positionLat / 1000000,\n"
            "      longitude: positionLon / 1000000,\n"
            "      accuracy\n"
            "    }\n"
            "  }\n"
            ""
            "    if (port == 204 && bytes[0] == 0 && bytes[3] == 1 && bytes[6] == 2 && bytes.length >= 9) {\n"
            "      return {\n"
            "        update_interval_moving: (bytes[2] << 8) | bytes[1],\n"
            "        keepalive_interval_stationary: (bytes[5] << 8) | bytes[4],\n"
            "        gsensor_timeout_moving: (bytes[8] << 8) | bytes[7]\n"
            "      }\n"
            "    }\n"
            ""
            "  return 'Invalid arguments passed to decoder'\n"
            "}\n"
            ""
        >>,

    VMPid =
        case router_v8:start_link(#{}) of
            {ok, Pid} -> Pid;
            {error, {already_started, Pid}} -> Pid
        end,
    {ok, VM} = router_v8:get(),
    {ok, Context1} = erlang_v8:create_context(VM),

    %% Check that decoding fails with invalid port
    BinaryPayload = <<16#00, 16#6d, 16#3d, 16#01, 16#ff, 16#8e, 16#02, 16#34, 16#e1>>,
    ListPayload = [16#00, 16#6d, 16#3d, 16#01, 16#ff, 16#8e, 16#02, 16#34, 16#e1],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_browan_object_locator:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),
    %% ok = test_utils:match_map(JsResult, ErlResult),

    %% Check that payloads match with valid port 136
    BinaryPayload = <<16#00, 16#6d, 16#3d, 16#52, 16#ff, 16#8e, 16#01, 16#34, 16#e1, 16#36, 16#5b>>,
    ListPayload = [16#00, 16#6d, 16#3d, 16#52, 16#ff, 16#8e, 16#01, 16#34, 16#e1, 16#36, 16#5b],
    Port = 136,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_browan_object_locator:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),
    %% ok = test_utils:match_map(JsResult, ErlResult),

    %% Check that payloads match with valid port 204
    BinaryPayload = <<16#00, 16#6d, 16#3d, 16#01, 16#ff, 16#8e, 16#02, 16#34, 16#e1>>,
    ListPayload = [16#00, 16#6d, 16#3d, 16#01, 16#ff, 16#8e, 16#02, 16#34, 16#e1],
    Port = 136,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_browan_object_locator:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),
    %% ok = test_utils:match_map(JsResult, ErlResult),

    gen_server:stop(VMPid),
    ok.
