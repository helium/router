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
    handle_uplink/3,
    handle_join/3
]).

%% ------------------------------------------------------------------
%% router_channel type exports
%% ------------------------------------------------------------------
-export([
    new/6, new/7, new/8, new/9,
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
    receive_joins/1,
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
    payload_template :: undefined | binary(),
    channel_options :: map()
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
    gen_event:add_sup_handler(Pid, Handler, {[Channel, Device], ok}).

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

-spec handle_uplink(
    EventManagerPid :: pid(),
    Data :: map(),
    UUID :: router_utils:uuid_v4()
) -> ok.
handle_uplink(Pid, Data, UUID) ->
    ok = gen_event:notify(Pid, {data, UUID, Data}).

-spec handle_join(
    EventManagerPid :: pid(),
    Data :: map(),
    UUID :: router_utils:uuid_v4()
) -> ok.
handle_join(Pid, Data, UUID) ->
    ok = gen_event:notify(Pid, {join, UUID, Data}).

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
        payload_template = Template,
        channel_options = #{}
    }.

-spec new(
    ID :: binary(),
    Handler :: atom(),
    Name :: binary(),
    Args :: map(),
    DeviceID :: binary(),
    Pid :: pid(),
    Decoder :: undefined | router_decoder:decoder(),
    Template :: undefined | binary(),
    ChannelOptions :: map()
) -> channel().
new(ID, Handler, Name, Args, DeviceID, Pid, Decoder, Template, ChannelOptions) ->
    #channel{
        id = ID,
        handler = Handler,
        name = Name,
        args = Args,
        device_id = DeviceID,
        controller = Pid,
        decoder = Decoder,
        payload_template = Template,
        channel_options = ChannelOptions
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

-spec receive_joins(channel()) -> boolean().
receive_joins(Channel) ->
    maps:get(receive_joins, Channel#channel.channel_options, false).

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
    router_channel_utils:maybe_apply_template(
        ?MODULE:payload_template(Channel),
        maps:put(payload, base64:encode(Payload), TemplateArgs)
    );
encode_data(Decoder, #{payload := Payload, port := Port} = TemplateArgs, Channel) ->
    DecoderID = router_decoder:id(Decoder),
    case router_decoder:decode(DecoderID, Payload, Port, TemplateArgs) of
        {ok, DecodedPayload} ->
            router_channel_utils:maybe_apply_template(
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
            router_channel_utils:maybe_apply_template(
                ?MODULE:payload_template(Channel),
                maps:merge(TemplateArgs, #{
                    decoded => #{
                        status => error,
                        error => Reason
                    },
                    payload => base64:encode(Payload)
                })
            )
    end;
encode_data(_Decoder, TemplateArgs, _Channel) ->
    lager:info("encoding join [device: ~p] [channel: ~p]", [
        ?MODULE:device_id(_Channel),
        ?MODULE:unique_id(_Channel)
    ]),
    jsx:encode(TemplateArgs).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    Channel0 = #channel{
        id = <<"channel_id0">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = undefined,
        payload_template = undefined,
        channel_options = #{}
    },
    ?assertEqual(
        Channel0,
        new(
            <<"channel_id0">>,
            router_http_channel,
            <<"channel_name">>,
            [],
            <<"device_id">>,
            self()
        )
    ),
    Decoder = router_decoder:new(<<"decoder_id">>, custom, #{}),
    Channel1 = #channel{
        id = <<"channel_id1">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = Decoder,
        payload_template = undefined,
        channel_options = #{}
    },
    ?assertEqual(
        Channel1,
        new(
            <<"channel_id1">>,
            router_http_channel,
            <<"channel_name">>,
            [],
            <<"device_id">>,
            self(),
            Decoder
        )
    ),
    Channel2 = #channel{
        id = <<"channel_id2">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = Decoder,
        payload_template = <<"template">>,
        channel_options = #{}
    },
    ?assertEqual(
        Channel2,
        new(
            <<"channel_id2">>,
            router_http_channel,
            <<"channel_name">>,
            [],
            <<"device_id">>,
            self(),
            Decoder,
            <<"template">>
        )
    ),
    Channel3 = #channel{
        id = <<"channel_id3">>,
        handler = router_http_channel,
        name = <<"channel_name">>,
        args = [],
        device_id = <<"device_id">>,
        controller = self(),
        decoder = Decoder,
        payload_template = <<"template">>,
        channel_options = #{foo => true, bar => false}
    },
    ?assertEqual(
        Channel3,
        new(
            <<"channel_id3">>,
            router_http_channel,
            <<"channel_name">>,
            [],
            <<"device_id">>,
            self(),
            Decoder,
            <<"template">>,
            #{foo => true, bar => false}
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
        payload_template = undefined,
        channel_options = #{}
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
        payload_template = undefined,
        channel_options = #{}
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

receive_joins_test() ->
    Channel = new(
        <<"channel_id">>,
        router_http_channel,
        <<"channel_name">>,
        [],
        <<"device_id">>,
        self(),
        <<>>,
        <<>>,
        #{receive_joins => true}
    ),
    ?assertEqual(true, receive_joins(Channel)).

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
