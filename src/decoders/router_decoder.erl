-module(router_decoder).

%% ------------------------------------------------------------------
%% Decoder API Exports
%% ------------------------------------------------------------------
-export([
    new/3,
    id/1,
    type/1,
    args/1
]).

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([
    init_ets/0,
    add/1,
    delete/1,
    decode/4
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(ETS, router_decoder_ets).

-record(decoder, {
    id :: binary(),
    type :: atom(),
    args :: map()
}).

-type decoder() :: #decoder{}.

-export_type([decoder/0]).

%% ------------------------------------------------------------------
%% Decoder Type Functions
%% ------------------------------------------------------------------

-spec new(binary(), atom(), map()) -> decoder().
new(ID, Type, Args) ->
    #decoder{id = ID, type = Type, args = Args}.

-spec id(decoder()) -> binary().
id(#decoder{id = ID}) ->
    ID.

-spec type(decoder()) -> atom().
type(Decoder) ->
    Decoder#decoder.type.

-spec args(decoder()) -> map().
args(Decoder) ->
    Decoder#decoder.args.

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [public, named_table, set]),
    ok.

-spec add(decoder()) -> ok | {error, any()}.
add(Decoder) ->
    add(?MODULE:type(Decoder), Decoder).

-spec delete(binary()) -> ok.
delete(ID) ->
    true = ets:delete(?ETS, ID),
    ok.

-spec decode(
    DecoderID :: binary(),
    Payload :: binary(),
    Port :: integer(),
    UplinkDetails :: map()
) -> {ok, any()} | {error, any()}.
decode(DecoderID, Payload, Port, UplinkDetails) ->
    Start = erlang:system_time(millisecond),
    try decode_(DecoderID, Payload, Port, UplinkDetails) of
        {Type, {ok, _} = OK} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:decoder_observe(Type, ok, End - Start),
            OK;
        {Type, {error, _} = Err} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:decoder_observe(Type, error, End - Start),
            Err
    catch
        _Class:_Reason:_Stacktrace ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:decoder_observe(decoder_crashed, error, End - Start),
            lager:error("decoder ~p crashed: ~p (~p) stacktrace ~p", [
                DecoderID,
                _Reason,
                Payload,
                _Stacktrace
            ]),
            {error, decoder_crashed}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec decode_(
    DecoderID :: binary(),
    Payload :: binary(),
    Port :: integer(),
    UplinkDetails :: map()
) -> {DecoderType :: atom(), {ok, DecodedPayload :: any()}} | {atom(), {error, any()}}.
decode_(DecoderID, Payload, Port, UplinkDetails) ->
    case lookup(DecoderID) of
        {error, not_found} ->
            {unknown_decoder, {error, unknown_decoder}};
        {ok, #decoder{type = custom} = Decoder} ->
            {custom,
                router_decoder_custom_sup:decode(
                    Decoder,
                    erlang:binary_to_list(Payload),
                    Port,
                    UplinkDetails
                )};
        {ok, #decoder{type = cayenne} = Decoder} ->
            {cayenne, router_decoder_cayenne:decode(Decoder, Payload, Port)};
        {ok, #decoder{type = browan_object_locator} = Decoder} ->
            {browan_object_locator,
                router_decoder_browan_object_locator:decode(Decoder, Payload, Port)};
        {ok, _Decoder} ->
            {unhandled_decoder, {error, unhandled_decoder}}
    end.

-spec add(atom(), decoder()) -> ok | {error, any()}.
add(custom, Decoder) ->
    case router_decoder_custom_sup:add(Decoder) of
        {error, _Reason} = Error -> Error;
        {ok, _Pid} -> insert(Decoder)
    end;
add(cayenne, Decoder) ->
    insert(Decoder);
add(browan_object_locator, Decoder) ->
    insert(Decoder);
add(_Type, _Decoder) ->
    {error, unhandled_decoder}.

-spec lookup(DecoderID :: binary()) -> {ok, decoder()} | {error, not_found}.
lookup(DecoderID) ->
    case ets:lookup(?ETS, DecoderID) of
        [] -> {error, not_found};
        [{DecoderID, Decoder}] -> {ok, Decoder}
    end.

-spec insert(decoder()) -> ok.
insert(Decoder) ->
    ID = ?MODULE:id(Decoder),
    true = ets:insert(?ETS, {ID, Decoder}),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    Decoder = #decoder{id = <<"id">>, type = custom, args = #{}},
    ?assertEqual(Decoder, new(<<"id">>, custom, #{})).

id_test() ->
    Decoder = new(<<"id">>, custom, #{}),
    ?assertEqual(<<"id">>, id(Decoder)).

type_test() ->
    Decoder = new(<<"id">>, custom, #{}),
    ?assertEqual(custom, type(Decoder)).

args_test() ->
    Decoder = new(<<"id">>, custom, #{}),
    ?assertEqual(#{}, args(Decoder)).

add_test() ->
    Decoder = new(<<"id">>, unkown, #{}),
    ?assertEqual({error, unhandled_decoder}, add(Decoder)).

insert_lookup_delete_test() ->
    _ = init_ets(),
    ID = <<"id">>,
    Decoder = new(ID, custom, #{}),
    ok = insert(Decoder),
    ok = delete(ID),
    ?assertEqual({error, not_found}, lookup(ID)),
    true = ets:delete(?ETS).

-endif.
