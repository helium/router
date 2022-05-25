-module(router_v8_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    invalid_context_test/1,
    browan_decoder_test/1,
    cayenne_decoder_test/1
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
    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),

    RunTest = fun({TestName, BinPayload, Port}) ->
        ListPayload = erlang:binary_to_list(BinPayload),

        {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
        JSResult =
            case JsResult0 of
                Bin when erlang:is_binary(Bin) -> error;
                Map when erlang:is_map(Map) ->
                    maps:from_list([
                        {erlang:binary_to_atom(Key), V}
                     || {Key, V} <- maps:to_list(JsResult0)
                    ]);
                Other ->
                    ct:fail({expected_bin_or_map, TestName, Other})
            end,
        ErlResult =
            case router_decoder_browan_object_locator:decode(undefined, BinPayload, Port) of
                {ok, M} -> M;
                {error, _Err} -> error
            end,

        %% ct:print(
        %%     "Running: ~p === ~p",
        %%     [TestName, JSResult == ErlResult]
        %% ),

        ?assertEqual(JSResult, ErlResult, {test_name, TestName})
    end,

    %% Check that decoding fails with invalid port
    RunTest({invalid_port, <<16#00, 16#70, 16#3d, 16#01, 16#ff, 16#8e, 16#02, 16#34, 16#e1>>, 1}),

    %% Check that payloads match with valid port 136
    %% NOTE: Battery is 16#70 to produce a float so we don't have to work around js inability to not cast floats.
    RunTest(
        {valid_port_136,
            <<16#00, 16#70, 16#3d, 16#52, 16#ff, 16#8e, 16#01, 16#34, 16#e1, 16#36, 16#5b>>, 136}
    ),
    %% Check that payloads match with valid port 204
    RunTest(
        {valid_port_204, <<16#00, 16#70, 16#3d, 16#01, 16#ff, 16#8e, 16#02, 16#34, 16#e1>>, 204}
    ),

    gen_server:stop(VMPid),
    ok.

cayenne_decoder_test(_Config) ->
    GoodFunction =
        <<
            "\n"
            "function Decoder(bytes, port, uplink_info) {\n"
            "  const DIGITAL_IN = 0\n"
            "  const DIGITAL_OUT = 1\n"
            "  const ANALOG_IN = 2\n"
            "  const ANALOG_OUT = 3\n"
            "  const GENERIC_SENSOR = 100\n"
            "  const LUMINANCE = 101\n"
            "  const PRESENCE = 102\n"
            "  const TEMPERATURE = 103\n"
            "  const HUMIDITY = 104\n"
            "  const ACCELEROMETER = 113\n"
            "  const BAROMETER = 115\n"
            "  const VOLTAGE = 116\n"
            "  const CURRENT = 117\n"
            "  const FREQUENCY = 118\n"
            "  const PERCENTAGE = 120\n"
            "  const ALTITUDE = 121\n"
            "  const CONCENTRATION = 125\n"
            "  const POWER = 128\n"
            "  const DISTANCE = 130\n"
            "  const ENERGY = 131\n"
            "  const DIRECTION = 132\n"
            "  const GYROMETER = 134\n"
            "  const COLOUR = 135\n"
            "  const GPS = 136\n"
            "  const SWITCH = 142\n"
            "\n"
            "  const parseBytes = (bytes, acc) => {\n"
            "    if (bytes.length == 0) return acc\n"
            "    if (bytes[0] > 99) {\n"
            "      return \"LPP reserved channel\"\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == DIGITAL_IN && bytes.length >= 3) {\n"
            "      const value = bytes[2]\n"
            "      const nextBytes = bytes.slice(3)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: DIGITAL_IN,\n"
            "          value,\n"
            "          name: \"digital_in\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == DIGITAL_OUT && bytes.length >= 3) {\n"
            "      const value = bytes[2]\n"
            "      const nextBytes = bytes.slice(3)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: DIGITAL_OUT,\n"
            "          value,\n"
            "          name: \"digital_out\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == ANALOG_IN && bytes.length >= 4) {\n"
            "      const value = (bytes[2] << 8 | bytes[3]) << 16 >> 16\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: ANALOG_IN,\n"
            "          value: value / 100,\n"
            "          name: \"analog_in\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == ANALOG_OUT && bytes.length >= 4) {\n"
            "      const value = (bytes[2] << 8 | bytes[3]) << 16 >> 16\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: ANALOG_OUT,\n"
            "          value: value / 100,\n"
            "          name: \"analog_out\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == GENERIC_SENSOR && bytes.length >= 6) {\n"
            "      const value = (((bytes[2] << 24 | bytes[3] << 16) | bytes[4] << 8) | bytes[5]) >>> 0\n"
            "      const nextBytes = bytes.slice(6)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: GENERIC_SENSOR,\n"
            "          value: value / 100,\n"
            "          name: \"generic_sensor\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == LUMINANCE && bytes.length >= 4) {\n"
            "      const value = bytes[2] << 8 | bytes[3]\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: LUMINANCE,\n"
            "          value,\n"
            "          name: \"luminance\",\n"
            "          unit: \"lux\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == PRESENCE && bytes.length >= 3) {\n"
            "      const value = bytes[2]\n"
            "      const nextBytes = bytes.slice(3)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: PRESENCE,\n"
            "          value,\n"
            "          name: \"presence\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == TEMPERATURE && bytes.length >= 4) {\n"
            "      const value = (bytes[2] << 8 | bytes[3]) << 16 >> 16\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: TEMPERATURE,\n"
            "          value: value / 10,\n"
            "          unit: \"celsius\",\n"
            "          name: \"temperature\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == HUMIDITY && bytes.length >= 3) {\n"
            "      const value = bytes[2]\n"
            "      const nextBytes = bytes.slice(3)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: HUMIDITY,\n"
            "          value: value / 2,\n"
            "          unit: \"percent\",\n"
            "          name: \"humidity\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == ACCELEROMETER && bytes.length >= 8) {\n"
            "      const x = (bytes[2] << 8 | bytes[3]) << 16 >> 16\n"
            "      const y = (bytes[4] << 8 | bytes[5]) << 16 >> 16\n"
            "      const z = (bytes[6] << 8 | bytes[7]) << 16 >> 16\n"
            "      const nextBytes = bytes.slice(8)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: ACCELEROMETER,\n"
            "          value: { x: x/1000, y: y/1000, z: z/1000},\n"
            "          unit: \"G\",\n"
            "          name: \"accelerometer\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == BAROMETER && bytes.length >= 4) {\n"
            "      const value = bytes[2] << 8 | bytes[3]\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: BAROMETER,\n"
            "          value: value / 10,\n"
            "          unit: \"hPa\",\n"
            "          name: \"barometer\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == VOLTAGE && bytes.length >= 4) {\n"
            "      const value = bytes[2] << 8 | bytes[3]\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: VOLTAGE,\n"
            "          value: value / 100,\n"
            "          unit: \"V\",\n"
            "          name: \"voltage\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == CURRENT && bytes.length >= 4) {\n"
            "      const value = bytes[2] << 8 | bytes[3]\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: CURRENT,\n"
            "          value: value / 1000,\n"
            "          unit: \"A\",\n"
            "          name: \"current\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == FREQUENCY && bytes.length >= 6) {\n"
            "      const value = (((bytes[2] << 24 | bytes[3] << 16) | bytes[4] << 8) | bytes[5]) >>> 0\n"
            "      const nextBytes = bytes.slice(6)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: FREQUENCY,\n"
            "          value,\n"
            "          unit: \"Hz\",\n"
            "          name: \"frequency\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == PERCENTAGE && bytes.length >= 3) {\n"
            "      const value = bytes[2]\n"
            "      const nextBytes = bytes.slice(3)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: PERCENTAGE,\n"
            "          value,\n"
            "          unit: \"%\",\n"
            "          name: \"percentage\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == ALTITUDE && bytes.length >= 4) {\n"
            "      const value = (bytes[2] << 8 | bytes[3]) << 16 >> 16\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: ALTITUDE,\n"
            "          value,\n"
            "          unit: \"m\",\n"
            "          name: \"altitude\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == CONCENTRATION && bytes.length >= 4) {\n"
            "      const value = bytes[2] << 8 | bytes[3]\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: CONCENTRATION,\n"
            "          value,\n"
            "          unit: \"PPM\",\n"
            "          name: \"concentration\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == POWER && bytes.length >= 4) {\n"
            "      const value = bytes[2] << 8 | bytes[3]\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: POWER,\n"
            "          value,\n"
            "          unit: \"W\",\n"
            "          name: \"power\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == DISTANCE && bytes.length >= 6) {\n"
            "      const value = (((bytes[2] << 24 | bytes[3] << 16) | bytes[4] << 8) | bytes[5]) >>> 0\n"
            "      const nextBytes = bytes.slice(6)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: DISTANCE,\n"
            "          value: value / 1000,\n"
            "          unit: \"m\",\n"
            "          name: \"distance\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == ENERGY && bytes.length >= 6) {\n"
            "      const value = (((bytes[2] << 24 | bytes[3] << 16) | bytes[4] << 8) | bytes[5]) >>> 0\n"
            "      const nextBytes = bytes.slice(6)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: ENERGY,\n"
            "          value: value / 1000,\n"
            "          unit: \"kWh\",\n"
            "          name: \"energy\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == DIRECTION && bytes.length >= 4) {\n"
            "      const value = bytes[2] << 8 | bytes[3]\n"
            "      const nextBytes = bytes.slice(4)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: DIRECTION,\n"
            "          value,\n"
            "          unit: 'º',\n"
            "          name: \"direction\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == GYROMETER && bytes.length >= 8) {\n"
            "      const x = (bytes[2] << 8 | bytes[3]) << 16 >> 16\n"
            "      const y = (bytes[4] << 8 | bytes[5]) << 16 >> 16\n"
            "      const z = (bytes[6] << 8 | bytes[7]) << 16 >> 16\n"
            "      const nextBytes = bytes.slice(8)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: GYROMETER,\n"
            "          value: { x: x/100, y: y/100, z: z/100},\n"
            "          unit: \"°/s\",\n"
            "          name: \"gyrometer\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == COLOUR && bytes.length >= 5) {\n"
            "      const r = bytes[2]\n"
            "      const g = bytes[3]\n"
            "      const b = bytes[4]\n"
            "      const nextBytes = bytes.slice(5)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: COLOUR,\n"
            "          value: { r, g, b },\n"
            "          name: \"colour\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == GPS && bytes.length >= 11) {\n"
            "      const lat = ((bytes[2] << 16 | bytes[3] << 8) | bytes[4]) << 8 >> 8\n"
            "      const lon = ((bytes[5] << 16 | bytes[6] << 8) | bytes[7]) << 8 >> 8\n"
            "      const alt = ((bytes[8] << 16 | bytes[9] << 8) | bytes[10]) << 8 >> 8\n"
            "      const nextBytes = bytes.slice(11)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: GPS,\n"
            "          value: { latitude: lat/10000, longitude: lon/10000, altitude: alt/100},\n"
            "          name: \"gps\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    if (bytes[1] == SWITCH && bytes.length >= 3) {\n"
            "      const value = bytes[2]\n"
            "      const nextBytes = bytes.slice(3)\n"
            "      return parseBytes(\n"
            "        nextBytes,\n"
            "        acc.concat({\n"
            "          channel: bytes[0],\n"
            "          type: SWITCH,\n"
            "          value,\n"
            "          name: \"switch\",\n"
            "          last: nextBytes.length == 0 ? true : undefined\n"
            "        })\n"
            "      )\n"
            "    }\n"
            "\n"
            "    return \"LPP decoder failure\"\n"
            "  }\n"
            "\n"
            "  return parseBytes(bytes, [])\n"
            "}\n"
        >>,

    VMPid =
        case router_v8:start_link(#{}) of
            {ok, Pid} -> Pid;
            {error, {already_started, Pid}} -> Pid
        end,
    {ok, VM} = router_v8:get(),
    {ok, Context1} = erlang_v8:create_context(VM),
    ?assertMatch({ok, undefined}, erlang_v8:eval(VM, Context1, GoodFunction)),

    CleanMap = fun CLEANMAP(M) ->
        maps:from_list([
            {
                erlang:binary_to_atom(Key),
                case V of
                    %% Convert nested maps keys to atoms
                    V2 when erlang:is_map(V) -> CLEANMAP(V2);
                    V -> V
                end
            }
         || {Key, V} <- maps:to_list(M)
        ])
    end,

    RunTest = fun({TestName, BinPayload, Port}) ->
        ListPayload = erlang:binary_to_list(BinPayload),

        {ok, JsResult0} = erlang_v8:call(VM, Context1, <<"Decoder">>, [ListPayload, Port]),
        JSResult =
            case JsResult0 of
                Bin when erlang:is_binary(Bin) -> error;
                List1 when erlang:is_list(List1) -> [CleanMap(M) || M <- List1];
                Other1 -> ct:fail({expected_bin_or_map, TestName, Other1})
            end,
        ErlResult =
            case router_decoder_cayenne:decode(undefined, BinPayload, Port) of
                {ok, List2} when erlang:is_list(List2) ->
                    [
                     %% NOTE: Leave booleans alone
                        maps:map(
                            fun
                                (_Key, V) when erlang:is_boolean(V) -> V;
                                (_Key, V) when erlang:is_atom(V) -> erlang:atom_to_binary(V);
                                (_Key, OV) -> OV
                            end,
                            M
                        )
                     || M <- List2
                    ];
                {error, _Err} ->
                    error;
                Other2 ->
                    ct:fail({unexpected_return_from_erlang, TestName, Other2})
            end,

        %% ct:print(
        %%     "Running: ~p === ~p",
        %%     [TestName, JSResult == ErlResult]
        %% ),

        ?assertEqual(JSResult, ErlResult, {test_name, TestName})
    end,

    %% Check that decoding fails when channel is over 99
    RunTest({fail_channel_over_99, <<16#ff>>, 1}),

    %% Check that decoding fails when type is not found
    RunTest({fail_type_not_found, <<16#00, 16#ff>>, 1}),

    %% Check that decoding fails when not enough bytes after valid channel
    RunTest({fail_not_enough_bytes, <<16#00, 16#00>>, 1}),

    %% Check valid digital_in type
    RunTest({pass_digital_in, <<16#00, 16#00, 16#0f>>, 1}),

    %% Check valid digital_out type
    RunTest({pass_digital_out, <<16#00, 16#01, 16#0f>>, 1}),

    %% Check valid analog_in type
    RunTest({pass_analog_in, <<16#00, 16#02, 16#ff, 16#00>>, 1}),

    %% Check valid analog_out type
    RunTest({pass_analog_out, <<16#00, 16#03, 16#ff, 16#00>>, 1}),

    %% Check valid generic_sensor type
    RunTest({pass_generic_sensor, <<16#00, 16#64, 16#ff, 16#00, 16#00, 16#00>>, 1}),

    %% Check valid luminance type
    RunTest({pass_luminance, <<16#00, 16#65, 16#ff, 16#00>>, 1}),

    %% Check valid presence type
    RunTest({pass_presence, <<16#00, 16#66, 16#ff>>, 1}),

    %% Check valid temperature type
    RunTest({pass_temperature, <<16#00, 16#67, 16#01, 16#10, 16#05, 16#67, 16#00, 16#ff>>, 1}),

    %% Check valid humidity type
    RunTest({pass_humidity, <<16#00, 16#68, 16#ff>>, 1}),

    %% Check valid accelerometer type
    RunTest({pass_accelerometer, <<16#06, 16#71, 16#04, 16#d2, 16#fb, 16#2e, 16#00, 16#01>>, 1}),

    %% Check valid barometer type
    RunTest({pass_barometer, <<16#00, 16#73, 16#ff, 16#a4>>, 1}),

    %% Check valid voltage type
    RunTest({pass_voltage, <<16#00, 16#74, 16#ff, 16#00>>, 1}),

    %% Check valid current type
    RunTest({pass_current, <<16#00, 16#75, 16#ff, 16#00>>, 1}),

    %% Check valid frequency type
    RunTest({pass_frequency, <<16#00, 16#76, 16#ff, 16#00, 16#00, 16#00>>, 1}),

    %% Check valid percentage type
    RunTest({pass_percentage, <<16#00, 16#78, 16#ff>>, 1}),

    %% Check valid altitude type
    RunTest({pass_altitude, <<16#00, 16#79, 16#ff, 16#00>>, 1}),

    %% Check valid concentration type
    RunTest({pass_concentration, <<16#00, 16#7d, 16#ff, 16#00>>, 1}),

    %% Check valid power type
    RunTest({pass_power, <<16#00, 16#80, 16#ff, 16#00>>, 1}),

    %% Check valid distance type
    RunTest({pass_distance, <<16#00, 16#82, 16#ff, 16#00, 16#00, 16#00>>, 1}),

    %% Check valid energy type
    RunTest({pass_energy, <<16#00, 16#83, 16#ff, 16#00, 16#00, 16#00>>, 1}),

    %% Check valid direction type
    %% NOTE: disabled due to difference in encoding of 'º' char.
    %% values have been manually verified
    %% RunTest({pass_direction, <<16#00, 16#84, 16#ff, 16#00>>, 1}),

    %% Check valid gyrometer type
    %% NOTE: disabled due to difference in encoding of 'º' char.
    %% values have been manually verified
    %% RunTest({pass_gyrometer, <<16#00, 16#86, 16#ff, 16#00, 16#ff, 16#00, 16#ff, 16#00>>, 1}),

    %% Check valid colour type
    RunTest({pass_colour, <<16#00, 16#87, 16#ff, 16#00, 16#00>>, 1}),

    %% Check valid gps type
    RunTest(
        {pass_gps, <<16#06, 16#88, 16#04, 16#d2, 16#fb, 16#2e, 16#00, 16#00, 16#ff, 16#00, 16#00>>,
            1}
    ),

    %% Check valid switch type
    RunTest({pass_switch, <<16#00, 16#8e, 16#ff>>, 1}),

    gen_server:stop(VMPid),
    ok.
