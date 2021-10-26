%%%-------------------------------------------------------------------
%%% @doc
%%% == Custom Decoder Supervisor ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_decoder_custom_sup).

-behaviour(supervisor).

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([
    start_link/0,
    add/1,
    delete/1,
    decode/4
]).

%% ------------------------------------------------------------------
%% Supervisor Callback Exports
%% ------------------------------------------------------------------
-export([init/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(WORKER(I), #{
    id => I,
    start => {I, start_link, []},
    restart => temporary,
    shutdown => 1000,
    type => worker,
    modules => [I]
}).

-define(FLAGS, #{
    strategy => simple_one_for_one,
    intensity => 3,
    period => 60
}).

-define(ETS, router_decoder_custom_sup_ets).
-define(MAX_V8_CONTEXT, 100).

%% erlfmt-ignore
-define(DECODER_FUNCTION_REGEX, <<
    "function" % function
    "\\s+"     % one or more whitespace
    "Decoder"  % Decoder
    "\\s*?"    % zero or more whitespace
    "\\("      % open paren
    "\\w+?"    % argument of 1 or more characters
    ","        % comma
    "\\s*?"    % zero or more whitespace
    "\\w+?"    % argument of 1 or more characters
    "(,\\s*\\w+)*" % optional arg for object containing dev_eui, etc.
    "(,\\s*\\.\\.\\.\\w+)*" % optional variadic arg
    "\\)"      % close paren
>>).

%% Caveat with respect to the above JavaScript function signature:
%% Backwards compatibility requires newer args being optional, but
%% new feature (GitHub issue #439) benefits from an additional param.
%% Functions in JS may fetch unspecified parameters via `arguments`, and
%% although modern ECMAscript specs (ES6+?) recommend variadic signatures,
%% `arguments` maintains backwards compatibility with our older decoders.
%% Therefore, accommodate both styles within optional part of REGEX above:
%% e.g., function foo(bar, ...rest) can be called as foo(1,2,3,4,5,6)
%% https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Functions#rest_parameters
%% TODO there may be caveats that are unclear from reading spec such as
%% whether whitespace is legal within the variadic arg syntax or not:
%% https://tc39.es/ecma262/multipage/ecmascript-language-functions-and-classes.html

-record(custom_decoder, {
    id :: binary(),
    hash :: binary(),
    function :: binary(),
    pid :: pid(),
    last_used :: integer()
}).

-type custom_decoder() :: #custom_decoder{}.

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec add(router_decoder:decoder()) -> {ok, pid()} | {error, any()}.
add(Decoder) ->
    ID = router_decoder:id(Decoder),
    Args = router_decoder:args(Decoder),
    Function = maps:get(function, Args),
    add(ID, Function).

-spec delete(binary()) -> ok.
delete(ID) ->
    true = ets:delete(?ETS, ID),
    ok.

-spec decode(
    Decoder :: router_decoder:decoder(),
    Payload :: string(),
    Port :: integer(),
    UplinkDetails :: map()
) -> {ok, any()} | {error, any()}.
decode(Decoder, Payload, Port, UplinkDetails) ->
    ID = router_decoder:id(Decoder),
    case lookup(ID) of
        {error, _Reason} ->
            case ?MODULE:add(Decoder) of
                {error, _} = Error ->
                    Error;
                {ok, Pid} ->
                    router_decoder_custom_worker:decode(Pid, Payload, Port, UplinkDetails)
            end;
        {ok, #custom_decoder{pid = Pid} = CustomDecoder} ->
            ok = insert(CustomDecoder#custom_decoder{last_used = erlang:system_time(seconds)}),
            router_decoder_custom_worker:decode(Pid, Payload, Port, UplinkDetails)
    end.

%% ------------------------------------------------------------------
%% Supervisor callbacks
%% ------------------------------------------------------------------

init([]) ->
    ets:new(?ETS, [public, named_table, set]),
    {ok, {?FLAGS, [?WORKER(router_decoder_custom_worker)]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec add(DecoderID :: binary(), Function :: binary()) -> {ok, pid()} | {error, any()}.
add(ID, Function) ->
    case is_valid_decoder_function(Function) of
        false ->
            {error, no_decoder_fun_found};
        true ->
            Hash = crypto:hash(sha256, Function),
            case lookup(ID) of
                {error, not_found} ->
                    ok = maybe_delete_old_context(),
                    start_worker(ID, Hash, Function);
                {ok, #custom_decoder{id = ID, hash = Hash, pid = Pid}} ->
                    lager:debug("context ~p already exists here: ~p", [ID, Pid]),
                    {ok, Pid};
                {ok, #custom_decoder{id = ID, pid = Pid}} ->
                    ok = stop_worker(ID, Pid),
                    start_worker(ID, Hash, Function)
            end
    end.

-spec start_worker(DecoderID :: binary(), Hash :: binary(), Function :: binary()) ->
    {ok, pid()} | {error, any()}.
start_worker(ID, Hash, Function) ->
    {ok, VM} = router_v8:get(),
    Args = #{id => ID, vm => VM, function => Function},
    case supervisor:start_child(?MODULE, [Args]) of
        {error, _Err} = Err ->
            Err;
        {ok, Pid} = OK ->
            CustomDecoder = #custom_decoder{
                id = ID,
                hash = Hash,
                function = Function,
                pid = Pid,
                last_used = erlang:system_time(seconds)
            },
            ok = insert(CustomDecoder),
            OK
    end.

-spec stop_worker(binary(), pid()) -> ok.
stop_worker(ID, Pid) ->
    ok = ?MODULE:delete(ID),
    ok = gen_server:stop(Pid),
    ok.

-spec lookup(binary()) -> {ok, custom_decoder()} | {error, not_found}.
lookup(ID) ->
    case ets:lookup(?ETS, ID) of
        [] ->
            {error, not_found};
        [{ID, #custom_decoder{pid = Pid} = CustomDecoder}] ->
            case erlang:is_process_alive(Pid) of
                true -> {ok, CustomDecoder};
                false -> {error, not_found}
            end
    end.

-spec insert(custom_decoder()) -> ok.
insert(CustomDecoder) ->
    true = ets:insert(?ETS, {CustomDecoder#custom_decoder.id, CustomDecoder}),
    ok.

-spec maybe_delete_old_context() -> ok.
maybe_delete_old_context() ->
    case get_oldest_decoder() of
        undefined ->
            ok;
        #custom_decoder{id = ID, pid = Pid} ->
            stop_worker(ID, Pid)
    end.

-spec get_oldest_decoder() -> custom_decoder() | undefined.
get_oldest_decoder() ->
    Max = application:get_env(router, max_v8_context, ?MAX_V8_CONTEXT),
    case ets:info(?ETS, size) + 1 > Max of
        false ->
            undefined;
        true ->
            SortFun = fun(
                [{_, #custom_decoder{last_used = T1}}],
                [{_, #custom_decoder{last_used = T2}}]
            ) ->
                T1 < T2
            end,
            Sorted = lists:sort(SortFun, ets:match(?ETS, '$1')),
            case Sorted of
                [] -> undefined;
                [[{_ID, CustomDecoder}] | _] -> CustomDecoder
            end
    end.

-spec is_valid_decoder_function(binary()) -> boolean().
is_valid_decoder_function(Function) ->
    case re:run(Function, ?DECODER_FUNCTION_REGEX) of
        nomatch ->
            false;
        _ ->
            true
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

insert_lookup_delete_test() ->
    ets:new(?ETS, [public, named_table, set]),
    ID = <<"id">>,
    Fun = <<"function Decoder(bytes, port) {return 'ok'}">>,
    CustomDecoder = #custom_decoder{
        id = ID,
        hash = crypto:hash(sha256, Fun),
        function = Fun,
        pid = self(),
        last_used = erlang:system_time(seconds)
    },
    ok = insert(CustomDecoder),
    ?assertEqual({ok, CustomDecoder}, lookup(ID)),
    ok = delete(ID),
    ?assertEqual({error, not_found}, lookup(ID)),
    true = ets:delete(?ETS).

get_oldest_decoder_test() ->
    ets:new(?ETS, [public, named_table, set]),
    ok = application:set_env(router, max_v8_context, 1),
    Fun = <<"function Decoder(bytes, port) {return 'ok'}">>,
    ID0 = <<"id0">>,
    CustomDecoder0 = #custom_decoder{
        id = ID0,
        hash = crypto:hash(sha256, Fun),
        function = Fun,
        pid = self(),
        last_used = erlang:system_time(nanosecond)
    },
    ID1 = <<"id1">>,
    CustomDecoder1 = #custom_decoder{
        id = ID1,
        hash = crypto:hash(sha256, Fun),
        function = Fun,
        pid = self(),
        last_used = erlang:system_time(nanosecond)
    },
    ok = insert(CustomDecoder0),
    ok = insert(CustomDecoder1),

    ?assertEqual(CustomDecoder0, get_oldest_decoder()),
    true = ets:delete(?ETS).

is_valid_decoder_function_test_() ->
    [
        %%% VALID FUNCTIONS
        %% normal, original style
        ?_assertMatch(true, is_valid_decoder_function(<<"function Decoder(bytes, port) {}">>)),
        %% normal, with arg for #439
        ?_assertMatch(
            true,
            is_valid_decoder_function(<<"function Decoder(bytes, port, uplink_details) {}">>)
        ),
        %% normal with variadic/rest arg, with arg for #439
        ?_assertMatch(
            true,
            is_valid_decoder_function(<<"function Decoder(bytes, port, ...rest) {}">>)
        ),
        %% single spaces
        ?_assertMatch(true, is_valid_decoder_function(<<"function Decoder (bytes, port) {}">>)),
        %% multiple spaces right side
        ?_assertMatch(true, is_valid_decoder_function(<<"function Decoder    (bytes, port) {}">>)),
        %% tabs
        ?_assertMatch(true, is_valid_decoder_function(<<"function\tDecoder\t(bytes, port) {}">>)),
        %% newlines
        ?_assertMatch(true, is_valid_decoder_function(<<"function\nDecoder\n(bytes, port) {}">>)),
        %% multiple spaces both sides
        ?_assertMatch(
            true,
            is_valid_decoder_function(<<"function    Decoder    (bytes, port) {}">>)
        ),
        %% different argument names
        ?_assertMatch(true, is_valid_decoder_function(<<"function Decoder (one, two) {}">>)),
        %% single letter arguments
        ?_assertMatch(true, is_valid_decoder_function(<<"function Decoder (a,b) {}">>)),

        %%% INVALID FUNCTIONS
        %% lowercase function name
        ?_assertMatch(false, is_valid_decoder_function(<<"function decoder (bytes, port) {}">>)),
        %% single argument
        ?_assertMatch(false, is_valid_decoder_function(<<"function Decoder (bytes) {}">>)),
        %% no arguments
        ?_assertMatch(false, is_valid_decoder_function(<<"function Decoder () {}">>)),
        %% mispelled function name
        ?_assertMatch(false, is_valid_decoder_function(<<"function Decodre (bytes, port) {}">>)),
        %% missing space after function
        ?_assertMatch(false, is_valid_decoder_function(<<"functionDecoder (bytes, port) {}">>)),
        %% trailing command within arg list
        ?_assertMatch(false, is_valid_decoder_function(<<"function Decoder(bytes, port,) {}">>)),
        %% illegal space within variadic arg syntax
        ?_assertMatch(
            false,
            is_valid_decoder_function(<<"function Decoder(bytes, port, ... rest) {}">>)
        )
    ].

-endif.
