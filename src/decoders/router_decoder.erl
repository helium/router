-module(router_decoder).

-export([new/3,
         id/1,
         type/1,
         args/1]).

-export([init_ets/0,
         add/1, delete/1,
         decode/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(ETS, router_decoder_ets).

-record(decoder, {id :: binary(),
                  type :: atom(),
                  args :: map()}).

-type decoder() :: #decoder{}.

-export_type([decoder/0]).

-spec new(binary(), atom(), map()) -> decoder().
new(ID, Type, Args) ->
    #decoder{id=ID, type=Type, args=Args}.

-spec id(decoder()) -> binary().
id(#decoder{id=ID}) ->
    ID.

-spec type(decoder()) -> atom().
type(Decoder) ->
    Decoder#decoder.type.

-spec args(decoder()) -> map().
args(Decoder) ->
    Decoder#decoder.args.

init_ets() ->
    ets:new(?ETS, [public, named_table, set]).

-spec add(decoder()) -> ok | {error, any()}.
add(Decoder) ->
    add(?MODULE:type(Decoder), Decoder).

-spec delete(binary()) -> ok.
delete(ID) ->
    true = ets:delete(?ETS, ID),
    ok.

-spec decode(binary(), binary(), integer()) -> {ok, any()} | {error, any()}.
decode(ID, Payload, Port) ->
    case lookup(ID) of
        {error, not_found} ->
            {error, unknown_decoder};
        {ok, #decoder{type=custom}=Decoder} ->
            router_decoder_custom_sup:decode(Decoder, erlang:binary_to_list(Payload), Port);
        {ok, _Decoder} ->
            {error, unhandled_decoder}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec add(atom(), decoder()) -> ok | {error, any()}.
add(custom, Decoder) ->
    case router_decoder_custom_sup:add(Decoder) of
        {error, _Reason}=Error -> Error;
        {ok, _Pid} -> insert(Decoder)
    end;
add(_Type, _Decoder) ->
    {error, unhandled_decoder}.

-spec lookup(binary()) -> {ok, decoder()} | {error, not_found}.
lookup(ID) ->
    case ets:lookup(?ETS, ID) of
        [] -> {error, not_found};
        [{ID, Decoder}] -> {ok, Decoder}
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
    Decoder = #decoder{id= <<"id">>, type=custom, args= #{}},
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
