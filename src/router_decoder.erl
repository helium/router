-module(router_decoder).

-export([new/3,
         id/1,
         type/1,
         args/1]).

-export([init_ets/0,
         add/1,
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

-spec decode(binary(), binary(), integer()) -> {ok, any()} | {error, any()}.
decode(ID, Payload, Port) ->
    case lookup(ID) of
        {ok, custom, {_Hash, VM, Context}} ->
            erlang_v8:call(VM, Context, <<"Decoder">>, [erlang:binary_to_list(Payload), Port]);
        {error, not_found} ->
            {error, unknown_decoder};
        {ok, Type, _} ->
            {error, {unhandled_decoder, Type}}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec add(atom(), decoder()) -> ok | {error, any()}.
add(custom, Decoder) ->
    ID = ?MODULE:id(Decoder),
    Args = ?MODULE:args(Decoder),
    Function = maps:get(function, Args),
    case binary:match(Function, <<"function Decoder(bytes, port)">>) of
        nomatch ->
            {error, no_decoder_fun_found};
        _ ->
            {ok, VM} = router_v8:get(),
            Hash = crypto:hash(sha256, Function),
            case lookup(ID) of
                {error, not_found} ->
                    create_context(VM, ID, Function);
                {ok, custom, {Hash, _VM, _Context}} ->
                    lager:debug("context ~p already exists", [ID]),
                    ok;
                {ok, custom, {_Hash, _VM, _Context}} ->
                    ok = delete(ID),
                    create_context(VM, ID, Function)
            end
    end;
add(Other, _Decoder) ->
    {error, {decoder_not_handled, Other}}.

-spec create_context(pid(), binary(), binary()) -> ok | {error, any()}.
create_context(VM, ID, Function) ->
    {ok, Context} = erlang_v8:create_context(VM),
    case erlang_v8:eval(VM, Context, Function) of
        {ok, _} ->
            lager:info("context ~p created with ~p", [ID, Function]),
            Hash = crypto:hash(sha256, Function),
            ok = insert(ID, custom, {Hash, VM, Context}),
            ok;
        {error, _Reason}=Error ->
            lager:warning("failed to create context ~p: ~p", [ID, _Reason]),
            Error
    end.

-spec lookup(binary()) -> {ok, atom(), any()} | {error, not_found}.
lookup(ID) ->
    case ets:lookup(?ETS, ID) of
        [] -> {error, not_found};
        [{ID, {Type, Info}}] -> {ok, Type, Info}
    end.

-spec insert(binary(), atom(), any()) -> ok.
insert(ID, Type, Info) ->
    true = ets:insert(?ETS, {ID, {Type, Info}}),
    ok.

-spec delete(binary()) -> ok.
delete(ID) ->
    true = ets:delete(?ETS, ID),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).


-endif.
