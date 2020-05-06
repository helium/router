-module(router_decoder_browan_object_locator).

-export([decode/3]).

-spec decode(router_decoder:decoder(), binary(), integer()) -> {ok, binary()} | {error, any()}.
decode(_Decoder, Payload, _Port) ->
    {ok, Payload}.
