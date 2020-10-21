-module(router_channel).

-export([new/6, new/7, new/8,
         id/1, unique_id/1,
         handler/1,
         name/1,
         args/1,
         device_id/1,
         controller/1,
         decoder/1,
         payload_template/1,
         hash/1]).

-export([start_link/0,
         add/3, delete/2, update/3,
         handle_data/3,
         encode_data/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(channel, {id :: binary(),
                  handler :: atom(),
                  name :: binary(),
                  args :: map(),
                  device_id  :: binary(),
                  controller :: pid() | undefined,
                  decoder :: undefined | router_decoder:decoder(),
                  payload_template :: undefined | binary()}).

-type channel() :: #channel{}.

-export_type([channel/0]).

-spec new(binary(), atom(), binary(), map(), binary(), pid()) -> channel().
new(ID, Handler, Name, Args, DeviceID, Pid) ->
    new(ID, Handler, Name, Args, DeviceID, Pid, undefined).

-spec new(binary(), atom(), binary(), map(), binary(), pid(), undefined | router_decoder:decoder()) -> channel().
new(ID, Handler, Name, Args, DeviceID, Pid, Decoder) ->
    new(ID, Handler, Name, Args, DeviceID, Pid, Decoder, undefined).

-spec new(binary(), atom(), binary(), map(), binary(), pid(),
          undefined | router_decoder:decoder(), undefined | binary()) -> channel().
new(ID, Handler, Name, Args, DeviceID, Pid, Decoder, Template) ->
    #channel{id=ID,
             handler=Handler,
             name=Name,
             args=Args,
             device_id=DeviceID,
             controller=Pid,
             decoder=Decoder,
             payload_template=Template}.

-spec id(channel()) -> binary().
id(#channel{id=ID}) ->
    ID.

-spec unique_id(channel()) -> binary().
unique_id(#channel{id=ID, decoder=undefined}) ->
    ID;
unique_id(#channel{id=ID, decoder=Decoder}) ->
    DecoderID = router_decoder:id(Decoder),
    <<ID/binary, DecoderID/binary>>.

-spec handler(channel()) -> {atom(), binary()}.
handler(Channel) ->
    {Channel#channel.handler, ?MODULE:id(Channel)}.

-spec name(channel()) -> binary().
name(Channel) ->
    Channel#channel.name.

-spec args(channel()) -> map().
args(Channel) ->
    Channel#channel.args.

-spec device_id(channel()) -> binary().
device_id(Channel) ->
    Channel#channel.device_id.

-spec controller(channel()) -> pid().
controller(Channel) ->
    Channel#channel.controller.

-spec decoder(channel()) -> undefined | router_decoder:decoder().
decoder(Channel) ->
    Channel#channel.decoder.

-spec payload_template(channel()) -> undefined | binary().
payload_template(Channel) ->
    Channel#channel.payload_template.

-spec hash(channel()) -> binary().
hash(Channel0) ->
    Channel1 = Channel0#channel{controller=undefined},
    crypto:hash(sha256, erlang:term_to_binary(Channel1)).

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    gen_event:start_link().

-spec add(pid(), channel(), router_device:device()) -> ok | {'EXIT', term()} | {error, term()}.
add(Pid, Channel, Device) ->
    Handler = ?MODULE:handler(Channel),
    gen_event:add_sup_handler(Pid, Handler, {[Channel, Device], ok}).

-spec delete(pid(), channel()) -> ok.
delete(Pid, Channel) ->
    Handler = ?MODULE:handler(Channel),
    _ = gen_event:delete_handler(Pid, Handler, []),
    ok.

-spec update(pid(), channel(), router_device:device()) -> ok | {error, term()}.
update(Pid, Channel, Device) ->
    Handler = ?MODULE:handler(Channel),
    gen_event:call(Pid, Handler, {update, Channel, Device}).

-spec handle_data(pid(), map(), any()) -> ok.
handle_data(Pid, Data, Ref) ->
    ok = gen_event:notify(Pid, {data, Ref, Data}).

-spec encode_data(channel(), map()) -> binary().
encode_data(Channel, Map) ->
    encode_data(?MODULE:decoder(Channel), Map, Channel).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec encode_data(router_decoder:decoder() | undefined, map(), channel()) -> binary().
encode_data(undefined, #{payload := Payload}=Map, _Channel) ->
    jsx:encode(maps:put(payload, base64:encode(Payload), Map));
encode_data(Decoder, #{payload := Payload, port := Port}=Map, Channel) ->
    DecoderID = router_decoder:id(Decoder),
    case router_decoder:decode(DecoderID, Payload, Port) of
        {ok, DecodedPayload} when is_map(DecodedPayload) ->
            case ?MODULE:payload_template(Channel) of
                undefined ->
                    jsx:encode(maps:merge(Map, #{decoded => #{status => success,
                                                              payload => DecodedPayload},
                                                 payload => base64:encode(Payload)}));
                Template -> 
                    render_tempate(Template, DecodedPayload)
            end;
        {ok, DecodedPayload}  ->
            jsx:encode(maps:merge(Map, #{decoded => #{status => success,
                                                      payload => DecodedPayload},
                                         payload => base64:encode(Payload)}));
        {error, Reason} ->
            lager:warning("~p failed to decode payload ~p/~p: ~p for device ~p",
                          [DecoderID, Payload, Port, Reason, ?MODULE:device_id(Channel)]),
            jsx:encode(maps:merge(Map, #{decoded => #{status => error,
                                                      error => Reason},
                                         payload => base64:encode(Payload)}))
    end.

-spec render_tempate(binary(), map()) -> binary().
render_tempate(Template, Map0) ->
    Map1 = maps:from_list([{to_string(K), V} || {K, V} <- maps:to_list(Map0)]),
    bbmustache:render(Template, Map1).

-spec to_string(any()) -> string() | any().
to_string(Atom) when is_atom(Atom) ->
    erlang:atom_to_list(Atom);
to_string(Bin) when is_binary(Bin) ->
    erlang:binary_to_list(Bin);
to_string(Unknown) ->
    Unknown.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    Channel0 = #channel{id= <<"channel_id">>,
                        handler=router_http_channel,
                        name= <<"channel_name">>,
                        args=[],
                        device_id= <<"device_id">>,
                        controller=self(),
                        decoder=undefined,
                        payload_template=undefined},
    ?assertEqual(Channel0, new(<<"channel_id">>, router_http_channel, <<"channel_name">>,
                               [], <<"device_id">>, self())),
    Decoder = router_decoder:new(<<"decoder_id">>, custom, #{}),
    Channel1 = #channel{id= <<"channel_id">>,
                        handler=router_http_channel,
                        name= <<"channel_name">>,
                        args=[],
                        device_id= <<"device_id">>,
                        controller=self(),
                        decoder=Decoder,
                        payload_template=undefined},
    ?assertEqual(Channel1, new(<<"channel_id">>, router_http_channel, <<"channel_name">>,
                               [], <<"device_id">>, self(), Decoder)),
    Channel2 = #channel{id= <<"channel_id">>,
                        handler=router_http_channel,
                        name= <<"channel_name">>,
                        args=[],
                        device_id= <<"device_id">>,
                        controller=self(),
                        decoder=Decoder,
                        payload_template= <<"template">>},
    ?assertEqual(Channel2, new(<<"channel_id">>, router_http_channel, <<"channel_name">>,
                               [], <<"device_id">>, self(), Decoder, <<"template">>)).

id_test() ->
    Channel0 = new(<<"channel_id">>, router_http_channel,
                   <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(<<"channel_id">>, id(Channel0)),
    Decoder = router_decoder:new(<<"decoder_id">>, custom, #{}),
    Channel1 = #channel{id= <<"channel_id">>,
                        handler=router_http_channel,
                        name= <<"channel_name">>,
                        args=[],
                        device_id= <<"device_id">>,
                        controller=self(),
                        decoder=Decoder,
                        payload_template=undefined},
    ?assertEqual(<<"channel_id">>, id(Channel1)).

unique_id_test() ->
    Channel0 = new(<<"channel_id">>, router_http_channel,
                   <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(<<"channel_id">>, unique_id(Channel0)),
    Decoder = router_decoder:new(<<"decoder_id">>, custom, #{}),
    Channel1 = #channel{id= <<"channel_id">>,
                        handler=router_http_channel,
                        name= <<"channel_name">>,
                        args=[],
                        device_id= <<"device_id">>,
                        controller=self(),
                        decoder=Decoder,
                        payload_template=undefined},
    ?assertEqual(<<"channel_iddecoder_id">>, unique_id(Channel1)).

handler_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual({router_http_channel, <<"channel_id">>}, handler(Channel)).

name_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(<<"channel_name">>, name(Channel)).

args_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual([], args(Channel)).

device_id_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(<<"device_id">>, device_id(Channel)).

controller_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(self(), controller(Channel)).

decoder_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(undefined, decoder(Channel)).

payload_template_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(undefined, payload_template(Channel)).

hash_test() ->
    Channel0 = new(<<"channel_id">>, router_http_channel,
                   <<"channel_name">>, [], <<"device_id">>, self()),
    Channel1 = Channel0#channel{controller=undefined},
    Hash = crypto:hash(sha256, erlang:term_to_binary(Channel1)),
    ?assertEqual(Hash, hash(Channel0)).

-endif.
