%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Channel ==
%%%
%%% Event Manager for router_---_channels to add themselves as handlers.
%%%
%%% Started from router_device_channels_worker:init/1
%%%
%%% Handlers are added from router_device_channels_worker:start_channel/4
%%%  and router_device_channels_worker:maybe_start_no_channel/2
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(router_channel).

%% ------------------------------------------------------------------
%% gen_event Exports
%% ------------------------------------------------------------------
-export([
    start_link/0,
    add/3,
    delete/2,
    update/3,
    handle_data/3
]).

%% ------------------------------------------------------------------
%% router_channel type exports
%% ------------------------------------------------------------------
-export([
    new/6, new/7, new/8,
    id/1,
    unique_id/1,
    handler/1,
    name/1,
    args/1,
    device_id/1,
    controller/1,
    decoder/1,
    payload_template/1,
    hash/1,
    to_map/1
]).

%% ------------------------------------------------------------------
%% router_channel_handler API
%% ------------------------------------------------------------------
-export([encode_data/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(channel, {
    id :: binary(),
    handler :: atom(),
    name :: binary(),
    args :: map(),
    device_id :: binary(),
    controller :: pid() | undefined,
    decoder :: undefined | router_decoder:decoder(),
    payload_template :: undefined | binary()
}).

-type channel() :: #channel{}.

-export_type([channel/0]).

%% ------------------------------------------------------------------
%% Gen Event functions
%% ------------------------------------------------------------------

-spec start_link() -> {ok, EventManagerPid :: pid()} | {error, any()}.
start_link() ->
    gen_event:start_link().

-spec add(
    EventManagerPid :: pid(),
    Channel :: channel(),
    Device :: router_device:device()
) -> ok | {'EXIT', term()} | {error, term()}.
add(Pid, Channel, Device) ->
    Handler = ?MODULE:handler(Channel),
    gen_event:add_sup_handler(Pid, Handler, {Channel, Device}).

-spec delete(
    EventManagerPid :: pid(),
    Channel :: channel()
) -> ok.
delete(Pid, Channel) ->
    Handler = ?MODULE:handler(Channel),
    _ = gen_event:delete_handler(Pid, Handler, []),
    ok.

-spec update(
    EventManagerPid :: pid(),
    Channel :: channel(),
    Device :: router_device:device()
) -> ok | {error, term()}.
update(Pid, Channel, Device) ->
    Handler = ?MODULE:handler(Channel),
    gen_event:call(Pid, Handler, {update, Channel, Device}).

-spec handle_data(
    EventManagerPid :: pid(),
    Data :: map(),
    Ref :: reference()
) -> ok.
handle_data(Pid, Data, Ref) ->
    ok = gen_event:notify(Pid, {data, Ref, Data}).

%% ------------------------------------------------------------------
%% Channel Functions
%% ------------------------------------------------------------------

-spec new(
    ID :: binary(),
    Handler :: atom(),
    Name :: binary(),
    Args :: map(),
    DeviceID :: binary(),
    Pid :: pid()
) -> channel().
new(ID, Handler, Name, Args, DeviceID, Pid) ->
    new(ID, Handler, Name, Args, DeviceID, Pid, undefined).

-spec new(
    ID :: binary(),
    Handler :: atom(),
    Name :: binary(),
    Args :: map(),
    DeviceID :: binary(),
    Pid :: pid(),
    Decoder :: undefined | router_decoder:decoder()
) -> channel().
new(ID, Handler, Name, Args, DeviceID, Pid, Decoder) ->
    new(ID, Handler, Name, Args, DeviceID, Pid, Decoder, undefined).

-spec new(
    ID :: binary(),
    Handler :: atom(),
    Name :: binary(),
    Args :: map(),
    DeviceID :: binary(),
    Pid :: pid(),
    Decoder :: undefined | router_decoder:decoder(),
    Template :: undefined | binary()
) -> channel().
new(ID, Handler, Name, Args, DeviceID, Pid, Decoder, Template) ->
    #channel{
        id = ID,
        handler = Handler,
        name = Name,
        args = Args,
        device_id = DeviceID,
        controller = Pid,
        decoder = Decoder,
        payload_template = Template
    }.

-spec id(channel()) -> binary().
id(#channel{id = ID}) ->
    ID.

-spec unique_id(channel()) -> binary().
unique_id(#channel{id = ID, decoder = undefined}) ->
    ID;
unique_id(#channel{id = ID, decoder = Decoder}) ->
    DecoderID = router_decoder:id(Decoder),
    <<ID/binary, DecoderID/binary>>.

-spec handler(channel()) -> {atom(), binary()}.
handler(Channel) ->
    {Channel#channel.handler, ?MODULE:unique_id(Channel)}.

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
    Channel1 = Channel0#channel{controller = undefined},
    crypto:hash(sha256, erlang:term_to_binary(Channel1)).

-spec to_map(channel()) -> map().
to_map(Channel) ->
    #{
        id => ?MODULE:id(Channel),
        name => ?MODULE:name(Channel)
    }.

%% ------------------------------------------------------------------
%% Channel Handler Functions
%% ------------------------------------------------------------------

-spec encode_data(channel(), map()) -> binary().
encode_data(Channel, TemplateArgs) ->
    encode_data(?MODULE:decoder(Channel), TemplateArgs, Channel).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec encode_data(router_decoder:decoder() | undefined, map(), channel()) -> binary().
encode_data(undefined, #{payload := Payload} = TemplateArgs, Channel) ->
    maybe_apply_template(
        ?MODULE:payload_template(Channel),
        maps:put(payload, base64:encode(Payload), TemplateArgs)
    );
encode_data(Decoder, #{payload := Payload, port := Port} = TemplateArgs, Channel) ->
    DecoderID = router_decoder:id(Decoder),
    case router_decoder:decode(DecoderID, Payload, Port) of
        {ok, DecodedPayload} ->
            maybe_apply_template(
                ?MODULE:payload_template(Channel),
                maps:merge(TemplateArgs, #{
                    decoded => #{
                        status => success,
                        payload => DecodedPayload
                    },
                    payload => base64:encode(Payload)
                })
            );
        {error, Reason} ->
            lager:warning(
                "~p failed to decode payload ~p/~p: ~p for device ~p",
                [DecoderID, Payload, Port, Reason, ?MODULE:device_id(Channel)]
            ),
            maybe_apply_template(
                ?MODULE:payload_template(Channel),
                maps:merge(TemplateArgs, #{
                    decoded => #{
                        status => error,
                        error => Reason
                    },
                    payload => base64:encode(Payload)
                })
            )
    end.

-spec maybe_apply_template(undefined | binary(), map()) -> binary().
maybe_apply_template(undefined, Data) ->
    jsx:encode(Data);
maybe_apply_template(Template, TemplateArgs) ->
    NormalMap = jsx:decode(jsx:encode(TemplateArgs), [return_maps]),
    Data = mk_data_fun(NormalMap, []),
    try bbmustache:render(Template, Data, [{key_type, binary}]) of
        Res -> Res
    catch
        _E:_R ->
            lager:warning("mustache template render failed ~p:~p, Template: ~p Data: ~p", [
                _E,
                _R,
                Template,
                Data
            ]),
            <<"mustache template render failed">>
    end.

mk_data_fun(Data, FunStack) ->
    fun(Key0) ->
        case parse_key(Key0, FunStack) of
            error ->
                error;
            {NewFunStack, Key} ->
                case kvc:path(Key, Data) of
                    [] ->
                        error;
                    Val when is_map(Val) ->
                        {ok, mk_data_fun(Val, NewFunStack)};
                    Val ->
                        Res = lists:foldl(
                            fun(Fun, Acc) ->
                                Fun(Acc)
                            end,
                            Val,
                            NewFunStack
                        ),
                        {ok, Res}
                end
        end
    end.

parse_key(<<"base64_to_hex(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun base64_to_hex/1 | FunStack]);
parse_key(<<"hex_to_base64(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun hex_to_base64/1 | FunStack]);
parse_key(<<"base64_to_bytes(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun base64_to_bytes/1 | FunStack]);
parse_key(<<"hex_to_bytes(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun hex_to_bytes/1 | FunStack]);
parse_key(<<"bytes_to_list(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun bytes_to_list/1 | FunStack]);
parse_key(<<"epoch_to_iso8601(", Key/binary>>, FunStack) ->
    parse_key(Key, [fun epoch_to_iso8601/1 | FunStack]);
parse_key(Key0, FunStack) ->
    case binary:split(Key0, <<")">>, [trim, global]) of
        [Key] ->
            {FunStack, Key};
        _Other ->
            error
    end.

base64_to_hex(Val) ->
    Bin = base64:decode(Val),
    lorawan_utils:binary_to_hex(Bin).

hex_to_base64(Val) ->
    base64:encode(lorawan_utils:hex_to_binary(Val)).

base64_to_bytes(Val) ->
    base64:decode_to_string(Val).

hex_to_bytes(Val) ->
    binary_to_list(lorawan_utils:hex_to_binary(Val)).

epoch_to_iso8601(Val) ->
    iso8601:format(calendar:system_time_to_universal_time(Val, second)).

bytes_to_list(Val) ->
    list_to_binary(io_lib:format("~w", [Val])).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    Channel0 = #channel{
        id = <<"channel_id">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = undefined,
        payload_template = undefined
    },
    ?assertEqual(
        Channel0,
        new(
            <<"channel_id">>,
            router_http_channel,
            <<"channel_name">>,
            [],
            <<"device_id">>,
            self()
        )
    ),
    Decoder = router_decoder:new(<<"decoder_id">>, custom, #{}),
    Channel1 = #channel{
        id = <<"channel_id">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = Decoder,
        payload_template = undefined
    },
    ?assertEqual(
        Channel1,
        new(
            <<"channel_id">>,
            router_http_channel,
            <<"channel_name">>,
            [],
            <<"device_id">>,
            self(),
            Decoder
        )
    ),
    Channel2 = #channel{
        id = <<"channel_id">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = Decoder,
        payload_template = <<"template">>
    },
    ?assertEqual(
        Channel2,
        new(
            <<"channel_id">>,
            router_http_channel,
            <<"channel_name">>,
            [],
            <<"device_id">>,
            self(),
            Decoder,
            <<"template">>
        )
    ).

id_test() ->
    Channel0 = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual(<<"channel_id">>, id(Channel0)),
    Decoder = router_decoder:new(<<"decoder_id">>, custom, #{}),
    Channel1 = #channel{
        id = <<"channel_id">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = Decoder,
        payload_template = undefined
    },
    ?assertEqual(<<"channel_id">>, id(Channel1)).

unique_id_test() ->
    Channel0 = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual(<<"channel_id">>, unique_id(Channel0)),
    Decoder = router_decoder:new(<<"decoder_id">>, custom, #{}),
    Channel1 = #channel{
        id = <<"channel_id">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = Decoder,
        payload_template = undefined
    },
    ?assertEqual(<<"channel_iddecoder_id">>, unique_id(Channel1)).

handler_test() ->
    Channel = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual({router_http_channel, <<"channel_id">>}, handler(Channel)).

name_test() ->
    Channel = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual(<<"channel_name">>, name(Channel)).

args_test() ->
    Channel = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual([], args(Channel)).

device_id_test() ->
    Channel = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual(<<"device_id">>, device_id(Channel)).

controller_test() ->
    Channel = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual(self(), controller(Channel)).

decoder_test() ->
    Channel = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual(undefined, decoder(Channel)).

payload_template_test() ->
    Channel = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    ?assertEqual(undefined, payload_template(Channel)).

template_test() ->
    Template1 = <<"{{base64_to_hex(foo)}}">>,
    Map1 = #{foo => base64:encode(<<16#deadbeef:32/integer>>)},
    ?assertEqual(<<"DEADBEEF">>, maybe_apply_template(Template1, Map1)),
    Template2 = <<"{{base64_to_hex(foo.bar)}}">>,
    Map2 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(<<"DEADBEEF">>, maybe_apply_template(Template2, Map2)),
    Template3 = <<"{{hex_to_base64(base64_to_hex(foo))}}">>,
    Map3 = #{foo => base64:encode(<<16#deadbeef:32/integer>>)},
    ?assertEqual(base64:encode(<<16#deadbeef:32/integer>>), maybe_apply_template(Template3, Map3)),
    Template4 = <<"{{hex_to_base64(base64_to_hex(foo.bar))}}">>,
    Map4 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(base64:encode(<<16#deadbeef:32/integer>>), maybe_apply_template(Template4, Map4)),
    Template5 = <<"{{hex_to_bytes(base64_to_hex(foo.bar))}}">>,
    Map5 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(<<16#deadbeef:32/integer>>, maybe_apply_template(Template5, Map5)),
    Template6 = <<"{{base64_to_bytes(foo.bar))}}">>,
    Map6 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(<<16#deadbeef:32/integer>>, maybe_apply_template(Template6, Map6)),
    Template7 = <<"{{epoch_to_iso8601(time1)}} {{epoch_to_iso8601(time2)}}">>,
    Map7 = #{time1 => 1111111111, time2 => 1234567890},
    ?assertEqual(
        <<"2005-03-18T01:58:31Z 2009-02-13T23:31:30Z">>,
        maybe_apply_template(Template7, Map7)
    ),
    Template8 = <<"{{bytes_to_list(base64_to_bytes(foo.bar))}}">>,
    Map8 = #{foo => #{bar => base64:encode(<<16#deadbeef:32/integer>>)}},
    ?assertEqual(
        list_to_binary(io_lib:format("~w", [binary_to_list(<<16#deadbeef:32/integer>>)])),
        maybe_apply_template(Template8, Map8)
    ),
    ok.

hash_test() ->
    Channel0 = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self()
    ),
    Channel1 = Channel0#channel{controller = undefined},
    Hash = crypto:hash(sha256, erlang:term_to_binary(Channel1)),
    ?assertEqual(Hash, hash(Channel0)).

-endif.
