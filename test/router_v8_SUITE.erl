-module(router_v8_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    invalid_context_test/1,
    browan_decoder_test/1,
    cayenne_decoder_test/1,
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
    [invalid_context_test, browan_decoder_test, cayenne_decoder_test].

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

cayenne_decoder_test(_Config) ->
    GoodFunction =
        <<
            "
              function Decoder(bytes, port, uplink_info) {
                const DIGITAL_IN = 0
                const DIGITAL_OUT = 1
                const ANALOG_IN = 2
                const ANALOG_OUT = 3
                const GENERIC_SENSOR = 100
                const LUMINANCE = 101
                const PRESENCE = 102
                const TEMPERATURE = 103
                const HUMIDITY = 104
                const ACCELEROMETER = 113
                const BAROMETER = 115
                const VOLTAGE = 116
                const CURRENT = 117
                const FREQUENCY = 118
                const PERCENTAGE = 120
                const ALTITUDE = 121
                const CONCENTRATION = 125
                const POWER = 128
                const DISTANCE = 130
                const ENERGY = 131
                const DIRECTION = 132
                const GYROMETER = 134
                const COLOUR = 135
                const GPS = 136
                const SWITCH = 142

                const parseBytes = (bytes, acc) => {
                  if (bytes.length == 0) return acc
                  if (bytes[0] > 99) {
                    return \"LPP reserved channel\"
                  }

                  if (bytes[1] == DIGITAL_IN && bytes.length >= 3) {
                    const value = bytes[2]
                    const nextBytes = bytes.slice(3)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: DIGITAL_IN,
                        value,
                        name: \"digital_in\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == DIGITAL_OUT && bytes.length >= 3) {
                    const value = bytes[2]
                    const nextBytes = bytes.slice(3)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: DIGITAL_OUT,
                        value,
                        name: \"digital_out\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == ANALOG_IN && bytes.length >= 4) {
                    const value = (bytes[2] << 8 | bytes[3]) << 16 >> 16
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: ANALOG_IN,
                        value: value / 100,
                        name: \"analog_in\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == ANALOG_OUT && bytes.length >= 4) {
                    const value = (bytes[2] << 8 | bytes[3]) << 16 >> 16
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: ANALOG_OUT,
                        value: value / 100,
                        name: \"analog_out\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == GENERIC_SENSOR && bytes.length >= 6) {
                    const value = (((bytes[2] << 24 | bytes[3] << 16) | bytes[4] << 8) | bytes[5]) >>> 0
                    const nextBytes = bytes.slice(6)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: GENERIC_SENSOR,
                        value: value / 100,
                        name: \"generic_sensor\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == LUMINANCE && bytes.length >= 4) {
                    const value = bytes[2] << 8 | bytes[3]
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: LUMINANCE,
                        value,
                        name: \"luminance\",
                        unit: \"lux\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == PRESENCE && bytes.length >= 3) {
                    const value = bytes[2]
                    const nextBytes = bytes.slice(3)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: PRESENCE,
                        value,
                        name: \"presence\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == TEMPERATURE && bytes.length >= 4) {
                    const value = (bytes[2] << 8 | bytes[3]) << 16 >> 16
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: TEMPERATURE,
                        value: value / 10,
                        unit: \"celsius\",
                        name: \"temperature\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == HUMIDITY && bytes.length >= 3) {
                    const value = bytes[2]
                    const nextBytes = bytes.slice(3)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: HUMIDITY,
                        value: value / 2,
                        unit: \"percent\",
                        name: \"humidity\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == ACCELEROMETER && bytes.length >= 8) {
                    const x = (bytes[2] << 8 | bytes[3]) << 16 >> 16
                    const y = (bytes[4] << 8 | bytes[5]) << 16 >> 16
                    const z = (bytes[6] << 8 | bytes[7]) << 16 >> 16
                    const nextBytes = bytes.slice(8)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: ACCELEROMETER,
                        value: { x: x/1000, y: y/1000, z: z/1000},
                        unit: \"G\",
                        name: \"accelerometer\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == BAROMETER && bytes.length >= 4) {
                    const value = bytes[2] << 8 | bytes[3]
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: BAROMETER,
                        value: value / 10,
                        unit: \"hPa\",
                        name: \"barometer\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == VOLTAGE && bytes.length >= 4) {
                    const value = bytes[2] << 8 | bytes[3]
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: VOLTAGE,
                        value: value / 100,
                        unit: \"V\",
                        name: \"voltage\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == CURRENT && bytes.length >= 4) {
                    const value = bytes[2] << 8 | bytes[3]
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: CURRENT,
                        value: value / 1000,
                        unit: \"A\",
                        name: \"current\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == FREQUENCY && bytes.length >= 6) {
                    const value = (((bytes[2] << 24 | bytes[3] << 16) | bytes[4] << 8) | bytes[5]) >>> 0
                    const nextBytes = bytes.slice(6)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: FREQUENCY,
                        value,
                        unit: \"Hz\",
                        name: \"frequency\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == PERCENTAGE && bytes.length >= 3) {
                    const value = bytes[2]
                    const nextBytes = bytes.slice(3)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: PERCENTAGE,
                        value,
                        unit: \"%\",
                        name: \"percentage\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == ALTITUDE && bytes.length >= 4) {
                    const value = (bytes[2] << 8 | bytes[3]) << 16 >> 16
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: ALTITUDE,
                        value,
                        unit: \"m\",
                        name: \"altitude\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == CONCENTRATION && bytes.length >= 4) {
                    const value = bytes[2] << 8 | bytes[3]
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: CONCENTRATION,
                        value,
                        unit: \"PPM\",
                        name: \"concentration\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == POWER && bytes.length >= 4) {
                    const value = bytes[2] << 8 | bytes[3]
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: POWER,
                        value,
                        unit: \"W\",
                        name: \"power\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == DISTANCE && bytes.length >= 6) {
                    const value = (((bytes[2] << 24 | bytes[3] << 16) | bytes[4] << 8) | bytes[5]) >>> 0
                    const nextBytes = bytes.slice(6)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: DISTANCE,
                        value: value / 1000,
                        unit: \"m\",
                        name: \"distance\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == ENERGY && bytes.length >= 6) {
                    const value = (((bytes[2] << 24 | bytes[3] << 16) | bytes[4] << 8) | bytes[5]) >>> 0
                    const nextBytes = bytes.slice(6)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: ENERGY,
                        value: value / 1000,
                        unit: \"kWh\",
                        name: \"energy\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == DIRECTION && bytes.length >= 4) {
                    const value = bytes[2] << 8 | bytes[3]
                    const nextBytes = bytes.slice(4)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: DIRECTION,
                        value,
                        unit: \"º\",
                        name: \"direction\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == GYROMETER && bytes.length >= 8) {
                    const x = (bytes[2] << 8 | bytes[3]) << 16 >> 16
                    const y = (bytes[4] << 8 | bytes[5]) << 16 >> 16
                    const z = (bytes[6] << 8 | bytes[7]) << 16 >> 16
                    const nextBytes = bytes.slice(8)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: GYROMETER,
                        value: { x: x/100, y: y/100, z: z/100},
                        unit: \"°/s\",
                        name: \"gyrometer\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == COLOUR && bytes.length >= 5) {
                    const r = bytes[2]
                    const g = bytes[3]
                    const b = bytes[4]
                    const nextBytes = bytes.slice(5)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: COLOUR,
                        value: { r, g, b },
                        name: \"colour\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == GPS && bytes.length >= 11) {
                    const lat = ((bytes[2] << 16 | bytes[3] << 8) | bytes[4]) << 8 >> 8
                    const lon = ((bytes[5] << 16 | bytes[6] << 8) | bytes[7]) << 8 >> 8
                    const alt = ((bytes[8] << 16 | bytes[9] << 8) | bytes[10]) << 8 >> 8
                    const nextBytes = bytes.slice(11)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: GPS,
                        value: { latitude: lat/10000, longitude: lon/10000, altitude: alt/100},
                        name: \"gps\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  if (bytes[1] == SWITCH && bytes.length >= 3) {
                    const value = bytes[2]
                    const nextBytes = bytes.slice(3)
                    return parseBytes(
                      nextBytes,
                      acc.concat({
                        channel: bytes[0],
                        type: SWITCH,
                        value,
                        name: \"switch\",
                        last: nextBytes.length == 0 ? true : undefined
                      })
                    )
                  }

                  return \"LPP decoder failure\"
                }

                return parseBytes(bytes, [])
              }
            "
        >>,

    VMPid =
        case router_v8:start_link(#{}) of
            {ok, Pid} -> Pid;
            {error, {already_started, Pid}} -> Pid
        end,
    {ok, VM} = router_v8:get(),
    {ok, Context1} = erlang_v8:create_context(VM),

    %% Check that decoding fails when channel is over 99
    BinaryPayload = <<16#ff>>,
    ListPayload = [16#ff],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check that decoding fails when type is not found
    BinaryPayload = <<16#00, 16#ff>>,
    ListPayload = [16#00, 16#ff],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check that decoding fails when not enough bytes after valid channel
    BinaryPayload = <<16#00, 16#00>>,
    ListPayload = [16#00, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid digital_in type
    BinaryPayload = <<16#00, 16#00, 16#0f>>,
    ListPayload = [16#00, 16#00, 16#0f],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid digital_out type
    BinaryPayload = <<16#00, 16#01, 16#0f>>,
    ListPayload = [16#00, 16#01, 16#0f],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid analog_in type
    BinaryPayload = <<16#00, 16#02, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#02, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid analog_out type
    BinaryPayload = <<16#00, 16#03, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#03, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid generic_sensor type
    BinaryPayload = <<16#00, 16#64, 16#ff, 16#00, 16#00, 16#00>>,
    ListPayload = [16#00, 16#64, 16#ff, 16#00, 16#00, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid luminance type
    BinaryPayload = <<16#00, 16#65, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#65, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid presence type
    BinaryPayload = <<16#00, 16#66, 16#ff>>,
    ListPayload = [16#00, 16#66, 16#ff],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid temperature type
    BinaryPayload = <<16#00, 16#67, 16#01, 16#10, 16#05, 16#67, 16#00, 16#ff>>,
    ListPayload = [16#00, 16#67, 16#01, 16#10, 16#05, 16#67, 16#00, 16#ff],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid humidity type
    BinaryPayload = <<16#00, 16#68, 16#ff>>,
    ListPayload = [16#00, 16#68, 16#ff],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid accelerometer type
    BinaryPayload = <<16#06, 16#71, 16#04, 16#d2, 16#fb, 16#2e, 16#00, 16#00>>,
    ListPayload = [16#06, 16#71, 16#04, 16#d2, 16#fb, 16#2e, 16#00, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid barometer type
    BinaryPayload = <<16#00, 16#73, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#73, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid voltage type
    BinaryPayload = <<16#00, 16#74, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#74, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid current type
    BinaryPayload = <<16#00, 16#75, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#75, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid frequency type
    BinaryPayload = <<16#00, 16#76, 16#ff, 16#00, 16#00, 16#00>>,
    ListPayload = [16#00, 16#76, 16#ff, 16#00, 16#00, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid percentage type
    BinaryPayload = <<16#00, 16#78, 16#ff>>,
    ListPayload = [16#00, 16#78, 16#ff],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid altitude type
    BinaryPayload = <<16#00, 16#79, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#79, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid concentration type
    BinaryPayload = <<16#00, 16#7d, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#7d, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid power type
    BinaryPayload = <<16#00, 16#80, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#80, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid distance type
    BinaryPayload = <<16#00, 16#82, 16#ff, 16#00, 16#00, 16#00>>,
    ListPayload = [16#00, 16#82, 16#ff, 16#00, 16#00, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid energy type
    BinaryPayload = <<16#00, 16#83, 16#ff, 16#00, 16#00, 16#00>>,
    ListPayload = [16#00, 16#83, 16#ff, 16#00, 16#00, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid direction type
    BinaryPayload = <<16#00, 16#84, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#84, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid gyrometer type
    BinaryPayload = <<16#00, 16#86, 16#ff, 16#00, 16#ff, 16#00, 16#ff, 16#00>>,
    ListPayload = [16#00, 16#86, 16#ff, 16#00, 16#ff, 16#00, 16#ff, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid colour type
    BinaryPayload = <<16#00, 16#87, 16#ff, 16#00, 16#00>>,
    ListPayload = [16#00, 16#87, 16#ff, 16#00, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid gps type
    BinaryPayload = <<16#06, 16#88, 16#04, 16#d2, 16#fb, 16#2e, 16#00, 16#00, 16#ff, 16#00, 16#00>>,
    ListPayload = [16#06, 16#88, 16#04, 16#d2, 16#fb, 16#2e, 16#00, 16#00, 16#ff, 16#00, 16#00],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    %% Check valid switch type
    BinaryPayload = <<16#00, 16#8e, 16#ff>>,
    ListPayload = [16#00, 16#8e, 16#ff],
    Port = 1,

    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),
    {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
    {ok, ErlResult} = router_decoder_cayenne:decode(undefined, BinaryPayload, Port),
    JsResult = maps:from_list([
        {erlang:binary_to_atom(Key), V}
     || {Key, V} <- maps:to_list(JsResult0)
    ]),
    ct:print("JSResult: ~n~p", [JsResult]),
    ct:print("ErlResult: ~n~p", [ErlResult]),

    gen_server:stop(VMPid),
    ok.
