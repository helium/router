-define(CONSOLE_IP_PORT, <<"127.0.0.1:3000">>).
-define(CONSOLE_URL, <<"http://", ?CONSOLE_IP_PORT/binary>>).
-define(CONSOLE_WS_URL, <<"ws://", ?CONSOLE_IP_PORT/binary, "/websocket">>).

-define(CONSOLE_DEVICE_ID, <<"yolo_id">>).
-define(CONSOLE_DEVICE_NAME, <<"yolo_name">>).

-define(CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN, <<"downlink_token_123">>).
-define(CONSOLE_HTTP_CHANNEL_ID, <<"12345">>).
-define(CONSOLE_HTTP_CHANNEL_NAME, <<"fake_http">>).
-define(CONSOLE_HTTP_CHANNEL, #{
    <<"type">> => <<"http">>,
    <<"credentials">> => #{
        <<"headers">> => #{},
        <<"url_params">> => #{},
        <<"endpoint">> => <<?CONSOLE_URL/binary, "/channel">>,
        <<"method">> => <<"POST">>
    },
    <<"downlink_token">> => ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN,
    <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
    <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME
}).

-define(CONSOLE_MQTT_CHANNEL_ID, <<"56789">>).
-define(CONSOLE_MQTT_CHANNEL_NAME, <<"fake_mqtt">>).
-define(CONSOLE_MQTT_CHANNEL, #{
    <<"type">> => <<"mqtt">>,
    <<"credentials">> => #{
        <<"endpoint">> => <<"mqtt://broker.emqx.io:1883">>,
        <<"uplink">> => #{<<"topic">> => <<"uplink/{{organization_id}}/{{device_id}}">>},
        <<"downlink">> => #{<<"topic">> => <<"downlink/{{organization_id}}/{{device_id}}">>}
    },
    <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
    <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME
}).

-define(CONSOLE_AWS_CHANNEL_ID, <<"101112">>).
-define(CONSOLE_AWS_CHANNEL_NAME, <<"fake_aws">>).
-define(CONSOLE_AWS_CHANNEL, #{
    <<"type">> => <<"aws">>,
    <<"credentials">> => #{
        <<"aws_access_key">> => list_to_binary(os:getenv("aws_access_key")),
        <<"aws_secret_key">> => list_to_binary(os:getenv("aws_secret_key")),
        <<"aws_region">> => <<"us-west-1">>,
        <<"topic">> => <<"helium/test">>
    },
    <<"id">> => ?CONSOLE_AWS_CHANNEL_ID,
    <<"name">> => ?CONSOLE_AWS_CHANNEL_NAME
}).

-define(CONSOLE_IOT_HUB_CHANNEL_ID, <<"161718">>).
-define(CONSOLE_IOT_HUB_CHANNEL_NAME, <<"fake_azure">>).
-define(CONSOLE_IOT_HUB_CHANNEL, #{
    <<"type">> => <<"azure">>,
    <<"credentials">> => #{
        <<"azure_hub_name">> => <<"helium-iot-hub">>,
        <<"azure_policy_name">> => <<"fake-policy-name">>,
        <<"azure_policy_key">> => base64:encode(<<"obviously-fake-policy-token">>)
    },
    <<"id">> => ?CONSOLE_IOT_HUB_CHANNEL_ID,
    <<"name">> => ?CONSOLE_IOT_HUB_CHANNEL_NAME
}).

-define(CONSOLE_DECODER_CHANNEL_ID, <<"131415">>).
-define(CONSOLE_DECODER_CHANNEL_NAME, <<"fake_http_decoder">>).
-define(CONSOLE_DECODER_CHANNEL, #{
    <<"type">> => <<"http">>,
    <<"credentials">> => #{
        <<"headers">> => #{},
        <<"url_params">> => #{},
        <<"endpoint">> => <<?CONSOLE_URL/binary, "/channel">>,
        <<"method">> => <<"POST">>
    },
    <<"id">> => ?CONSOLE_DECODER_CHANNEL_ID,
    <<"name">> => ?CONSOLE_DECODER_CHANNEL_NAME,
    <<"function">> => ?CONSOLE_DECODER
}).

-define(CONSOLE_DECODER_ID, <<"custom-decoder">>).
-define(CONSOLE_DECODER, #{
    <<"active">> => true,
    <<"body">> => ?DECODER,
    <<"format">> => <<"custom">>,
    <<"id">> => ?CONSOLE_DECODER_ID,
    <<"name">> => <<"decoder name">>,
    <<"type">> => <<"decoder">>
}).

-define(CONSOLE_TEMPLATE_CHANNEL_ID, <<"091809830981">>).
-define(CONSOLE_TEMPLATE_CHANNEL_NAME, <<"fake_http_template">>).
-define(CONSOLE_TEMPLATE_CHANNEL, #{
    <<"type">> => <<"http">>,
    <<"credentials">> => #{
        <<"headers">> => #{},
        <<"url_params">> => #{},
        <<"endpoint">> => <<?CONSOLE_URL/binary, "/channel">>,
        <<"method">> => <<"POST">>
    },
    <<"id">> => ?CONSOLE_TEMPLATE_CHANNEL_ID,
    <<"name">> => ?CONSOLE_TEMPLATE_CHANNEL_NAME,
    <<"function">> => ?CONSOLE_TEMPLATE_DECODER,
    <<"payload_template">> => ?CONSOLE_TEMPLATE
}).

-define(CONSOLE_TEMPLATE_DECODER_ID, <<"custom-template_decoder">>).
-define(CONSOLE_TEMPLATE_DECODER, #{
    <<"active">> => true,
    <<"format">> => <<"browan_object_locator">>,
    <<"id">> => ?CONSOLE_TEMPLATE_DECODER_ID,
    <<"name">> => <<"decoder name">>,
    <<"type">> => <<"decoder">>
}).

-define(CONSOLE_TEMPLATE,
    <<"{{#decoded}}{{#payload}}{\"battery\":{{battery_percent}},",
        "\"lat\":{{latitude}},\"long\":{{longitude}}}{{/payload}}{{/decoded}}">>
).

-define(CONSOLE_CONSOLE_CHANNEL_ID, <<"1617181920">>).
-define(CONSOLE_CONSOLE_CHANNEL_NAME, <<"fake_console">>).
-define(CONSOLE_CONSOLE_CHANNEL, #{
    <<"type">> => <<"console">>,
    <<"credentials">> => #{},
    <<"id">> => ?CONSOLE_CONSOLE_CHANNEL_ID,
    <<"name">> => ?CONSOLE_CONSOLE_CHANNEL_NAME,
    <<"function">> => ?CONSOLE_DECODER
}).

-define(CONSOLE_LABELS, [
    #{
        <<"id">> => <<"label_id">>,
        <<"name">> => <<"label_name">>,
        <<"organization_id">> => <<"label_organization_id">>
    }
]).

-define(CONSOLE_ORG_ID, <<"ORG_123">>).

-define(DECODER, <<
    "\n"
    "function dewpoint(t, rh) {\n"
    "                          var c1 = 243.04;\n"
    "                              var c2 = 17.625;\n"
    "                              var h = rh / 100;\n"
    "                              if (h <= 0.01)\n"
    "                                 h = 0.01;\n"
    "                                 else if (h > 1.0)\n"
    "                                         h = 1.0;\n"
    "\n"
    "                                         var lnh = Math.log(h);\n"
    "                                         var tpc1 = t + c1;\n"
    "                                         var txc2 = t * c2;\n"
    "                                         var txc2_tpc1 = txc2 / tpc1;\n"
    "\n"
    "                                         var tdew = c1 * (lnh + txc2_tpc1) / \n"
    "                                                    (c2 - lnh - txc2_tpc1);\n"
    "                                         return tdew;\n"
    "                                         }\n"
    "\n"
    "\n"
    "function CalculateHeatIndex(t, rh) {\n"
    "    var tRounded = Math.floor(t + 0.5);\n"
    "\n"
    "    if (tRounded < 76 || tRounded > 126)\n"
    "        return null;\n"
    "    if (rh < 0 || rh > 100)\n"
    "        return null;\n"
    "\n"
    "    var tHeatEasy = 0.5 * (t + 61.0 + ((t - 68.0) * 1.2) + (rh * 0.094));\n"
    "\n"
    "    if ((tHeatEasy + t) < 160.0)\n"
    "        return tHeatEasy;\n"
    "\n"
    "    var t2 = t * t;\n"
    "    var rh2 = rh * rh; \n"
    "    var tResult = -42.379 +\n"
    "        (2.04901523 * t) +\n"
    "        (10.14333127 * rh) +\n"
    "        (-0.22475541 * t * rh) +\n"
    "        (-0.00683783 * t2) +\n"
    "        (-0.05481717 * rh2) +\n"
    "        (0.00122874 * t2 * rh) +\n"
    "        (0.00085282 * t * rh2) +\n"
    "        (-0.00000199 * t2 * rh2);\n"
    "\n"
    "    var tAdjust;\n"
    "    if (rh < 13.0 && 80.0 <= t && t <= 112.0)\n"
    "        tAdjust = -((13.0 - rh) / 4.0) * Math.sqrt((17.0 - Math.abs(t - 95.0)) / 17.0);\n"
    "    else if (rh > 85.0 && 80.0 <= t && t <= 87.0)\n"
    "        tAdjust = ((rh - 85.0) / 10.0) * ((87.0 - t) / 5.0);\n"
    "    else\n"
    "        tAdjust = 0;\n"
    "\n"
    "    tResult += tAdjust;\n"
    "\n"
    "    if (tResult >= 183.5)\n"
    "        return null;\n"
    "    else\n"
    "        return tResult;\n"
    "}\n"
    "\n"
    "function CalculatePmAqi(pm2_5, pm10) {\n"
    "    var result = {};\n"
    "    result.AQI_2_5 = null;\n"
    "    result.AQI_10 = null;\n"
    "    result.AQI = null;\n"
    "\n"
    "    function interpolate(v, t) {\n"
    "        if (v === null)\n"
    "            return null;\n"
    "\n"
    "        var i;\n"
    "        for (i = t.length - 2; i > 0; --i)\n"
    "            if (t[i][0] <= v)\n"
    "                break;\n"
    "\n"
    "        var entry = t[i];\n"
    "        var baseX = entry[0];\n"
    "        var baseY = entry[1];\n"
    "        var dx = (t[i + 1][0] - baseX);\n"
    "        var f = (v - baseX);\n"
    "        var dy = (t[i + 1][1] - baseY);\n"
    "        return Math.floor(baseY + f * dy / dx + 0.5);\n"
    "    }\n"
    "\n"
    "    var t2_5 = [\n"
    "        [0, 0],\n"
    "        [12.1, 51],\n"
    "        [35.5, 101],\n"
    "        [55.5, 151],\n"
    "        [150.5, 201],\n"
    "        [250.5, 301],\n"
    "        [350.5, 401]\n"
    "    ];\n"
    "    var t10 = [\n"
    "        [0, 0],\n"
    "        [55, 51],\n"
    "        [155, 101],\n"
    "        [255, 151],\n"
    "        [355, 201],\n"
    "        [425, 301],\n"
    "        [505, 401]\n"
    "    ];\n"
    "\n"
    "    result.AQI_2_5 = interpolate(pm2_5, t2_5);\n"
    "    result.AQI_10 = interpolate(pm10, t10);\n"
    "    if (result.AQI_2_5 === null)\n"
    "        result.AQI = result.AQI_10;\n"
    "    else if (result.AQI_10 === null)\n"
    "        result.AQI = result.AQI_2_5;\n"
    "    else if (result.AQI_2_5 > result.AQI_10)\n"
    "        result.AQI = result.AQI_2_5;\n"
    "    else\n"
    "        result.AQI = result.AQI_10;\n"
    "\n"
    "    return result;\n"
    "}\n"
    "\n"
    "function DecodeU16(Parse) {\n"
    "    var i = Parse.i;\n"
    "    var bytes = Parse.bytes;\n"
    "    var Vraw = (bytes[i] << 8) + bytes[i + 1];\n"
    "    Parse.i = i + 2;\n"
    "    return Vraw;\n"
    "}\n"
    "\n"
    "function DecodeUflt16(Parse) {\n"
    "    var rawUflt16 = DecodeU16(Parse);\n"
    "    var exp1 = rawUflt16 >> 12;\n"
    "    var mant1 = (rawUflt16 & 0xFFF) / 4096.0;\n"
    "    var f_unscaled = mant1 * Math.pow(2, exp1 - 15);\n"
    "    return f_unscaled;\n"
    "}\n"
    "\n"
    "function DecodePM(Parse) {\n"
    "    return DecodeUflt16(Parse) * 65536.0;\n"
    "}\n"
    "\n"
    "function DecodeDust(Parse) {\n"
    "    return DecodeUflt16(Parse) * 65536.0;\n"
    "}\n"
    "\n"
    "function DecodeI16(Parse) {\n"
    "    var Vraw = DecodeU16(Parse);\n"
    "\n"
    "    if (Vraw & 0x8000)\n"
    "        Vraw += -0x10000;\n"
    "\n"
    "    return Vraw;\n"
    "}\n"
    "\n"
    "function DecodeI16(Parse) {\n"
    "    var i = Parse.i;\n"
    "    var bytes = Parse.bytes;\n"
    "    var Vraw = (bytes[i] << 8) + bytes[i + 1];\n"
    "    Parse.i = i + 2;\n"
    "\n"
    "    if (Vraw & 0x8000)\n"
    "        Vraw += -0x10000;\n"
    "\n"
    "    return Vraw;\n"
    "}\n"
    "\n"
    "function DecodeV(Parse) {\n"
    "    return DecodeI16(Parse) / 4096.0;\n"
    "}\n"
    "\n"
    "function Decoder(bytes, port) {\n"
    "    var decoded = {};\n"
    "\n"
    "    if (!(port === 1))\n"
    "        return null;\n"
    "\n"
    "    var uFormat = bytes[0];\n"
    "    if (!(uFormat === 0x20 || uFormat === 0x21))\n"
    "        return uFormat;\n"
    "\n"
    "    var Parse = {};\n"
    "    Parse.bytes = bytes;\n"
    "    Parse.i = 1;\n"
    "\n"
    "    var flags = bytes[Parse.i++];\n"
    "\n"
    "    if (flags & 0x1) {\n"
    "        decoded.vBat = DecodeV(Parse);\n"
    "    }\n"
    "\n"
    "    if (flags & 0x2) {\n"
    "        decoded.vSys = DecodeV(Parse);\n"
    "    }\n"
    "\n"
    "    if (flags & 0x4) {\n"
    "        decoded.vBus = DecodeV(Parse);\n"
    "    }\n"
    "\n"
    "    if (flags & 0x8) {\n"
    "        var iBoot = bytes[Parse.i++];\n"
    "        decoded.boot = iBoot;\n"
    "    }\n"
    "\n"
    "    if (flags & 0x10) {\n"
    "        decoded.tempC = DecodeI16(Parse) / 256;\n"
    "        if (uFormat === 0x20)\n"
    "            decoded.p = DecodeU16(Parse) * 4 / 100.0;\n"
    "        decoded.rh = DecodeU16(Parse) * 100 / 65535.0;\n"
    "        decoded.tDewC = dewpoint(decoded.tempC, decoded.rh);\n"
    "        var tHeat = CalculateHeatIndex(decoded.tempC * 1.8 + 32, decoded.rh);\n"
    "        if (tHeat !== null)\n"
    "            decoded.tHeatIndexF = tHeat;\n"
    "    }\n"
    "\n"
    "    if (flags & 0x20) {\n"
    "        decoded.pm = {};\n"
    "        decoded.pm['1.0'] = DecodePM(Parse);\n"
    "        decoded.pm['2.5'] = DecodePM(Parse);\n"
    "        decoded.pm['10'] = DecodePM(Parse);\n"
    "\n"
    "        decoded.aqi_partial = {};\n"
    "        var aqi = CalculatePmAqi(decoded.pm['1.0'], null);\n"
    "        decoded.aqi_partial['1.0'] = aqi.AQI;\n"
    "\n"
    "        aqi = CalculatePmAqi(decoded.pm['2.5'], decoded.pm['10']);\n"
    "        decoded.aqi_partial['2.5'] = aqi.AQI_2_5;\n"
    "        decoded.aqi_partial['10'] = aqi.AQI_10;\n"
    "        decoded.aqi = aqi.AQI;\n"
    "    }\n"
    "\n"
    "    if (flags & 0x40) {\n"
    "        decoded.dust = {};\n"
    "        decoded.dust['0.3'] = DecodeDust(Parse);\n"
    "        decoded.dust['0.5'] = DecodeDust(Parse);\n"
    "        decoded.dust['1.0'] = DecodeDust(Parse);\n"
    "        decoded.dust['2.5'] = DecodeDust(Parse);\n"
    "        decoded.dust['5'] = DecodeDust(Parse);\n"
    "        decoded.dust['10'] = DecodeDust(Parse);\n"
    "    }\n"
    "\n"
    "    return decoded;\n"
    "}\n"
>>).
