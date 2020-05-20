-define(CONSOLE_IP_PORT, <<"127.0.0.1:3000">>).
-define(CONSOLE_URL, <<"http://", ?CONSOLE_IP_PORT/binary>>).
-define(CONSOLE_WS_URL, <<"ws://", ?CONSOLE_IP_PORT/binary, "/websocket">>).

-define(CONSOLE_DEVICE_ID, <<"yolo_id">>).
-define(CONSOLE_DEVICE_NAME, <<"yolo_name">>).

-define(CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN, <<"downlink_token_123">>).
-define(CONSOLE_HTTP_CHANNEL_ID, <<"12345">>).
-define(CONSOLE_HTTP_CHANNEL_NAME, <<"fake_http">>).
-define(CONSOLE_HTTP_CHANNEL, #{<<"type">> => <<"http">>,
                                <<"credentials">> => #{<<"headers">> => #{},
                                                       <<"endpoint">> => <<?CONSOLE_URL/binary, "/channel">>,
                                                       <<"method">> => <<"POST">>},
                                <<"downlink_token">> => ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN,
                                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME}).

-define(CONSOLE_MQTT_CHANNEL_ID, <<"56789">>).
-define(CONSOLE_MQTT_CHANNEL_NAME, <<"fake_mqtt">>).
-define(CONSOLE_MQTT_CHANNEL, #{<<"type">> => <<"mqtt">>,
                                <<"credentials">> => #{<<"endpoint">> => <<"mqtt://127.0.0.1:1883">>,
                                                       <<"topic">> => <<"test/">>},
                                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME}).

-define(CONSOLE_AWS_CHANNEL_ID, <<"101112">>).
-define(CONSOLE_AWS_CHANNEL_NAME, <<"fake_aws">>).
-define(CONSOLE_AWS_CHANNEL, #{<<"type">> => <<"aws">>,
                               <<"credentials">> => #{<<"aws_access_key">> => list_to_binary(os:getenv("aws_access_key")),
                                                      <<"aws_secret_key">> => list_to_binary(os:getenv("aws_secret_key")),
                                                      <<"aws_region">> => <<"us-west-1">>,
                                                      <<"topic">> => <<"helium/test">>},
                               <<"id">> => ?CONSOLE_AWS_CHANNEL_ID,
                               <<"name">> => ?CONSOLE_AWS_CHANNEL_NAME}).

-define(CONSOLE_DECODER_CHANNEL_ID, <<"131415">>).
-define(CONSOLE_DECODER_CHANNEL_NAME, <<"fake_http_decoder">>).
-define(CONSOLE_DECODER_CHANNEL, #{<<"type">> => <<"http">>,
                                   <<"credentials">> => #{<<"headers">> => #{},
                                                          <<"endpoint">> => <<?CONSOLE_URL/binary, "/channel">>,
                                                          <<"method">> => <<"POST">>},
                                   <<"id">> => ?CONSOLE_DECODER_CHANNEL_ID,
                                   <<"name">> => ?CONSOLE_DECODER_CHANNEL_NAME,
                                   <<"function">> => ?CONSOLE_DECODER}).

-define(CONSOLE_CONSOLE_CHANNEL_ID, <<"1617181920">>).
-define(CONSOLE_CONSOLE_CHANNEL_NAME, <<"fake_console">>).
-define(CONSOLE_CONSOLE_CHANNEL, #{<<"type">> => <<"console">>,
                                   <<"credentials">> => #{},
                                   <<"id">> => ?CONSOLE_CONSOLE_CHANNEL_ID,
                                   <<"name">> => ?CONSOLE_CONSOLE_CHANNEL_NAME,
                                   <<"function">> => ?CONSOLE_DECODER}).

-define(CONSOLE_DECODER_ID, <<"custom-decoder">>).
-define(CONSOLE_DECODER, #{<<"active">> => true,
                           <<"body">> => ?DECODER,
                           <<"format">> => <<"custom">>,
                           <<"id">> => ?CONSOLE_DECODER_ID,
                           <<"name">> => <<"decoder name">>,
                           <<"type">> => <<"decoder">>}).


-define(CONSOLE_LABELS, [#{<<"id">> => <<"label_id">>,
                           <<"name">> => <<"label_name">>,
                           <<"organization_id">> => <<"label_organization_id">>}]).


-define(DECODER, <<"
function dewpoint(t, rh) {
                          var c1 = 243.04;
                              var c2 = 17.625;
                              var h = rh / 100;
                              if (h <= 0.01)
                                 h = 0.01;
                                 else if (h > 1.0)
                                         h = 1.0;

                                         var lnh = Math.log(h);
                                         var tpc1 = t + c1;
                                         var txc2 = t * c2;
                                         var txc2_tpc1 = txc2 / tpc1;

                                         var tdew = c1 * (lnh + txc2_tpc1) / (c2 - lnh - txc2_tpc1);
                                         return tdew;
                                         }


function CalculateHeatIndex(t, rh) {
    var tRounded = Math.floor(t + 0.5);

    if (tRounded < 76 || tRounded > 126)
        return null;
    if (rh < 0 || rh > 100)
        return null;

    var tHeatEasy = 0.5 * (t + 61.0 + ((t - 68.0) * 1.2) + (rh * 0.094));

    if ((tHeatEasy + t) < 160.0)
        return tHeatEasy;

    var t2 = t * t;
    var rh2 = rh * rh; 
    var tResult = -42.379 +
        (2.04901523 * t) +
        (10.14333127 * rh) +
        (-0.22475541 * t * rh) +
        (-0.00683783 * t2) +
        (-0.05481717 * rh2) +
        (0.00122874 * t2 * rh) +
        (0.00085282 * t * rh2) +
        (-0.00000199 * t2 * rh2);

    var tAdjust;
    if (rh < 13.0 && 80.0 <= t && t <= 112.0)
        tAdjust = -((13.0 - rh) / 4.0) * Math.sqrt((17.0 - Math.abs(t - 95.0)) / 17.0);
    else if (rh > 85.0 && 80.0 <= t && t <= 87.0)
        tAdjust = ((rh - 85.0) / 10.0) * ((87.0 - t) / 5.0);
    else
        tAdjust = 0;

    tResult += tAdjust;

    if (tResult >= 183.5)
        return null;
    else
        return tResult;
}

function CalculatePmAqi(pm2_5, pm10) {
    var result = {};
    result.AQI_2_5 = null;
    result.AQI_10 = null;
    result.AQI = null;

    function interpolate(v, t) {
        if (v === null)
            return null;

        var i;
        for (i = t.length - 2; i > 0; --i)
            if (t[i][0] <= v)
                break;

        var entry = t[i];
        var baseX = entry[0];
        var baseY = entry[1];
        var dx = (t[i + 1][0] - baseX);
        var f = (v - baseX);
        var dy = (t[i + 1][1] - baseY);
        return Math.floor(baseY + f * dy / dx + 0.5);
    }

    var t2_5 = [
        [0, 0],
        [12.1, 51],
        [35.5, 101],
        [55.5, 151],
        [150.5, 201],
        [250.5, 301],
        [350.5, 401]
    ];
    var t10 = [
        [0, 0],
        [55, 51],
        [155, 101],
        [255, 151],
        [355, 201],
        [425, 301],
        [505, 401]
    ];

    result.AQI_2_5 = interpolate(pm2_5, t2_5);
    result.AQI_10 = interpolate(pm10, t10);
    if (result.AQI_2_5 === null)
        result.AQI = result.AQI_10;
    else if (result.AQI_10 === null)
        result.AQI = result.AQI_2_5;
    else if (result.AQI_2_5 > result.AQI_10)
        result.AQI = result.AQI_2_5;
    else
        result.AQI = result.AQI_10;

    return result;
}

function DecodeU16(Parse) {
    var i = Parse.i;
    var bytes = Parse.bytes;
    var Vraw = (bytes[i] << 8) + bytes[i + 1];
    Parse.i = i + 2;
    return Vraw;
}

function DecodeUflt16(Parse) {
    var rawUflt16 = DecodeU16(Parse);
    var exp1 = rawUflt16 >> 12;
    var mant1 = (rawUflt16 & 0xFFF) / 4096.0;
    var f_unscaled = mant1 * Math.pow(2, exp1 - 15);
    return f_unscaled;
}

function DecodePM(Parse) {
    return DecodeUflt16(Parse) * 65536.0;
}

function DecodeDust(Parse) {
    return DecodeUflt16(Parse) * 65536.0;
}

function DecodeI16(Parse) {
    var Vraw = DecodeU16(Parse);

    if (Vraw & 0x8000)
        Vraw += -0x10000;

    return Vraw;
}

function DecodeI16(Parse) {
    var i = Parse.i;
    var bytes = Parse.bytes;
    var Vraw = (bytes[i] << 8) + bytes[i + 1];
    Parse.i = i + 2;

    if (Vraw & 0x8000)
        Vraw += -0x10000;

    return Vraw;
}

function DecodeV(Parse) {
    return DecodeI16(Parse) / 4096.0;
}

function Decoder(bytes, port) {
    var decoded = {};

    if (!(port === 1))
        return null;

    var uFormat = bytes[0];
    if (!(uFormat === 0x20 || uFormat === 0x21))
        return uFormat;

    var Parse = {};
    Parse.bytes = bytes;
    Parse.i = 1;

    var flags = bytes[Parse.i++];

    if (flags & 0x1) {
        decoded.vBat = DecodeV(Parse);
    }

    if (flags & 0x2) {
        decoded.vSys = DecodeV(Parse);
    }

    if (flags & 0x4) {
        decoded.vBus = DecodeV(Parse);
    }

    if (flags & 0x8) {
        var iBoot = bytes[Parse.i++];
        decoded.boot = iBoot;
    }

    if (flags & 0x10) {
        decoded.tempC = DecodeI16(Parse) / 256;
        if (uFormat === 0x20)
            decoded.p = DecodeU16(Parse) * 4 / 100.0;
        decoded.rh = DecodeU16(Parse) * 100 / 65535.0;
        decoded.tDewC = dewpoint(decoded.tempC, decoded.rh);
        var tHeat = CalculateHeatIndex(decoded.tempC * 1.8 + 32, decoded.rh);
        if (tHeat !== null)
            decoded.tHeatIndexF = tHeat;
    }

    if (flags & 0x20) {
        decoded.pm = {};
        decoded.pm['1.0'] = DecodePM(Parse);
        decoded.pm['2.5'] = DecodePM(Parse);
        decoded.pm['10'] = DecodePM(Parse);

        decoded.aqi_partial = {};
        var aqi = CalculatePmAqi(decoded.pm['1.0'], null);
        decoded.aqi_partial['1.0'] = aqi.AQI;

        aqi = CalculatePmAqi(decoded.pm['2.5'], decoded.pm['10']);
        decoded.aqi_partial['2.5'] = aqi.AQI_2_5;
        decoded.aqi_partial['10'] = aqi.AQI_10;
        decoded.aqi = aqi.AQI;
    }

    if (flags & 0x40) {
        decoded.dust = {};
        decoded.dust['0.3'] = DecodeDust(Parse);
        decoded.dust['0.5'] = DecodeDust(Parse);
        decoded.dust['1.0'] = DecodeDust(Parse);
        decoded.dust['2.5'] = DecodeDust(Parse);
        decoded.dust['5'] = DecodeDust(Parse);
        decoded.dust['10'] = DecodeDust(Parse);
    }

    return decoded;
}
">>).
