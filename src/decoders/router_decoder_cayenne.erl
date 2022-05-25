%%%-------------------------------------------------------------------
%%% @doc
%%% == Cayenne Decoder ==
%%%
%%% LPP = Low Power Payload
%%% MyDevices Cayenne LPP Docs
%%% [https://developers.mydevices.com/cayenne/docs/lora/#lora-cayenne-low-power-payload]
%%% Test Vectors [https://github.com/myDevicesIoT/CayenneLPP]
%%% https://github.com/helium/router/issues/289#issuecomment-822964880
%%%
%%% `last' key is added to last map in collection for json templating
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(router_decoder_cayenne).

-export([decode/3]).

-define(DIGITAL_IN, 0).
-define(DIGITAL_OUT, 1).
-define(ANALOG_IN, 2).
-define(ANALOG_OUT, 3).
-define(GENERIC_SENSOR, 100).
-define(LUMINANCE, 101).
-define(PRESENCE, 102).
-define(TEMPERATURE, 103).
-define(HUMIDITY, 104).
-define(ACCELEROMETER, 113).
-define(BAROMETER, 115).
-define(VOLTAGE, 116).
-define(CURRENT, 117).
-define(FREQUENCY, 118).
-define(PERCENTAGE, 120).
-define(ALTITUDE, 121).
-define(CONCENTRATION, 125).
-define(POWER, 128).
-define(DISTANCE, 130).
-define(ENERGY, 131).
-define(DIRECTION, 132).
-define(GYROMETER, 134).
-define(COLOUR, 135).
-define(GPS, 136).
-define(SWITCH, 142).

-spec decode(router_decoder:decoder(), binary(), integer()) -> {ok, binary()} | {error, any()}.
decode(_Decoder, Payload, _Port) ->
    decode_lpp(Payload, []).

decode_lpp(<<>>, [M | Tail]) ->
    {ok, lists:reverse([maps:put(last, true, M) | Tail])};
decode_lpp(<<Channel:8/unsigned-integer, _/binary>>, _) when Channel > 99 ->
    {error, lpp_reserved_channel};
decode_lpp(
    <<Channel:8/unsigned-integer, ?DIGITAL_IN:8/integer, Value:8/unsigned-integer, Rest/binary>>,
    Acc
) ->
    %% TODO this should be 0 or 1
    decode_lpp(Rest, [
        #{channel => Channel, type => ?DIGITAL_IN, value => Value, name => digital_in}
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?DIGITAL_OUT:8/integer, Value:8/unsigned-integer, Rest/binary>>,
    Acc
) ->
    %% TODO this should be 0 or 1
    decode_lpp(Rest, [
        #{channel => Channel, type => ?DIGITAL_OUT, value => Value, name => digital_out}
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?ANALOG_IN:8/integer, Value:16/signed-integer, Rest/binary>>,
    Acc
) ->
    %% TODO is the value MSB or LSB
    decode_lpp(Rest, [
        #{channel => Channel, type => ?ANALOG_IN, value => Value / 100, name => analog_in}
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?ANALOG_OUT:8/integer, Value:16/big-signed-integer, Rest/binary>>,
    Acc
) ->
    %% TODO is the value MSB or LSB
    decode_lpp(Rest, [
        #{channel => Channel, type => ?ANALOG_OUT, value => Value / 100, name => analog_out}
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?GENERIC_SENSOR:8/integer, Value:32/integer-unsigned-big,
        Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{channel => Channel, type => ?GENERIC_SENSOR, value => Value / 100, name => generic_sensor}
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?LUMINANCE:8/integer, Value:16/integer-unsigned-big,
        Rest/binary>>,
    Acc
) ->
    %% TODO is the value MSB or LSB
    decode_lpp(Rest, [
        #{channel => Channel, type => ?LUMINANCE, value => Value, unit => lux, name => luminance}
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?PRESENCE:8/integer, Value:8/integer, Rest/binary>>,
    Acc
) ->
    %% TODO value is 0 or 1
    decode_lpp(Rest, [
        #{channel => Channel, type => ?PRESENCE, value => Value, name => presence}
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?TEMPERATURE:8/integer, Value:16/integer-signed-big,
        Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?TEMPERATURE,
            value => Value / 10,
            unit => celsius,
            name => temperature
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?HUMIDITY:8/integer, Value:8/integer-unsigned-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?HUMIDITY,
            value => Value / 2,
            unit => percent,
            name => humidity
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?ACCELEROMETER:8/integer, X:16/integer-signed-big,
        Y:16/integer-signed-big, Z:16/integer-signed-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?ACCELEROMETER,
            value => #{x => X / 1000, y => Y / 1000, z => Z / 1000},
            unit => 'G',
            name => accelerometer
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?BAROMETER:8/integer, Value:16/integer-unsigned-big,
        Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?BAROMETER,
            value => Value / 10,
            unit => 'hPa',
            name => humidity
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?VOLTAGE:8/integer, Value:16/integer-unsigned-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?VOLTAGE,
            value => Value / 100,
            unit => 'V',
            name => voltage
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?CURRENT:8/integer, Value:16/integer-unsigned-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?CURRENT,
            value => Value / 1000,
            unit => 'A',
            name => current
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?FREQUENCY:8/integer, Value:32/integer-unsigned-big,
        Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?FREQUENCY,
            value => Value,
            unit => 'Hz',
            name => frequency
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?PERCENTAGE:8/integer, Value:8/integer-unsigned, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?PERCENTAGE,
            value => Value,
            unit => '%',
            name => percentage
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?ALTITUDE:8/integer, Value:16/integer-signed-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?ALTITUDE,
            value => Value,
            unit => 'm',
            name => altitude
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?CONCENTRATION:8/integer, Value:16/integer-unsigned,
        Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?CONCENTRATION,
            value => Value,
            unit => 'PPM',
            name => concentration
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?POWER:8/integer, Value:16/integer-unsigned-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?POWER,
            value => Value,
            unit => 'W',
            name => power
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?DISTANCE:8/integer, Value:32/integer-unsigned-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?DISTANCE,
            value => Value / 1000,
            unit => 'm',
            name => distance
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?ENERGY:8/integer, Value:32/integer-unsigned-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?ENERGY,
            value => Value / 1000,
            unit => 'kWh',
            name => energy
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?DIRECTION:8/integer, Value:16/integer-unsigned-big,
        Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?DIRECTION,
            value => Value,
            unit => 'º',
            name => direction
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?GYROMETER:8/integer, X:16/integer-signed-big,
        Y:16/integer-signed-big, Z:16/integer-signed-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?GYROMETER,
            value => #{x => X / 100, y => Y / 100, z => Z / 100},
            unit => '°/s',
            name => gyrometer
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?COLOUR:8/integer, R:8/integer, G:8/integer, B:8/integer,
        Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?COLOUR,
            value => #{r => R, g => G, b => B},
            name => colour
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?GPS:8/integer, Lat:24/integer-signed-big,
        Lon:24/integer-signed-big, Alt:24/integer-signed-big, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?GPS,
            value => #{latitude => Lat / 10000, longitude => Lon / 10000, altitude => Alt / 100},
            name => gps
        }
        | Acc
    ]);
decode_lpp(
    <<Channel:8/unsigned-integer, ?SWITCH:8/integer, Value:8/integer, Rest/binary>>,
    Acc
) ->
    decode_lpp(Rest, [
        #{
            channel => Channel,
            type => ?SWITCH,
            value => Value,
            name => switch
        }
        | Acc
    ]);
decode_lpp(_, _) ->
    {error, lpp_decoder_failure}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

decode_test() ->
    %% test vectors from https://github.com/myDevicesIoT/CayenneLPP
    ?assertEqual(
        {ok, [
            #{
                channel => 3,
                value => 27.2,
                unit => celcius,
                name => temperature,
                type => ?TEMPERATURE
            },
            #{
                channel => 5,
                value => 25.5,
                unit => celcius,
                name => temperature,
                type => ?TEMPERATURE,
                last => true
            }
        ]},
        decode_lpp(<<16#03, 16#67, 16#01, 16#10, 16#05, 16#67, 16#00, 16#FF>>, [])
    ),

    ?assertEqual(
        {ok, [
            #{
                channel => 6,
                value => #{x => 1.234, y => -1.234, z => 0.0},
                name => accelerometer,
                type => ?ACCELEROMETER,
                unit => 'G',
                last => true
            }
        ]},
        decode_lpp(<<16#06, 16#71, 16#04, 16#D2, 16#FB, 16#2E, 16#00, 16#00>>, [])
    ).
-endif.
