-module(router_decoder_cayenne).

-export([decode/3]).

-spec decode(router_decoder:decoder(), binary(), integer()) -> {ok, binary()}.
decode(_Decoder, Payload, _Port) ->
    {ok, Payload}.