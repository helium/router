-module(router_decoder_browan_object_locator).

-export([decode/3]).

-spec decode(router_decoder:decoder(), binary(), integer()) -> {ok, binary()} | {error, any()}.
decode(_Decoder, << 0:1/integer, 0:1/integer, 0:1/integer, GNSError:1/integer, GNSFix:1/integer, _:1/integer, Moving:1/integer, Button:1/integer,
                    _:4/integer, Battery:4/unsigned-integer,
                    _:1/integer, Temp:7/unsigned-integer,
                    Lat:32/integer-signed-little,
                    TempLon:24/integer-signed-little, Accuracy:3/integer, I:5/integer-unsigned>>, Port) when Port == 136 ->
    <<Lon:29/integer-signed-little>> = <<TempLon:24/integer-unsigned-little, I:5/integer-unsigned>>,
    {ok, #{gns_error => GNSError == 1, gns_fix => GNSFix == 1, moving => Moving == 1, button => Button == 1, battery => (25 + Battery) / 10,
           temperature => Temp - 32, latitude => Lat / 1000000, longitude => Lon / 1000000, accuracy => trunc(math:pow(2, Accuracy+2))}};
decode(_Decoder, <<0:8/integer, UpdateIntervalWhileMoving:26/integer-unsigned-little, 1:8/integer,
                   KeepAliveIntervalWhileStationary:16/integer-unsigned-little, 2:8/integer,
                   GSensorTimeoutWhenMoving:16/integer-unsigned-little>>, Port) when Port == 204 ->
    {ok, #{update_interval_moving => UpdateIntervalWhileMoving,
           keepalive_interval_stationary => KeepAliveIntervalWhileStationary,
           gsensor_timeout_moving => GSensorTimeoutWhenMoving}};
decode(_Decoder, _, _) ->
    {error, browan_decoder_failure}.
