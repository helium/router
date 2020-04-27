-module(router_decoder_custom_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         add/1, delete/1,
         decode/3]).

%% Supervisor callbacks
-export([init/1]).

-define(WORKER(I), #{id => I,
                     start => {I, start_link, []},
                     restart => temporary,
                     shutdown => 1000,
                     type => worker,
                     modules => [I]}).
-define(FLAGS,  #{strategy => simple_one_for_one,
                  intensity => 3,
                  period => 60}).
-define(ETS, router_decoder_custom_sup_ets).
-define(MAX_V8_CONTEXT, 100).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec add(router_decoder:decoder()) -> {ok, pid()} | {error, any()}.
add(Decoder) ->
    ID = router_decoder:id(Decoder),
    Args = router_decoder:args(Decoder),
    Function = maps:get(function, Args),
    case binary:match(Function, <<"function Decoder(bytes, port)">>) of
        nomatch ->
            {error, no_decoder_fun_found};
        _ ->
            Hash = crypto:hash(sha256, Function),
            case lookup(ID) of
                {error, not_found} ->
                    ok = maybe_delete_old_context(),
                    start_worker(ID, Hash, Args);
                {ok, Hash, Pid, _Time} ->
                    lager:debug("context ~p already exists here: ~p", [ID, Pid]),
                    {ok, Pid};
                {ok, _Hash, Pid, _Time} ->
                    ok = stop_worker(ID, Pid),
                    start_worker(ID, Hash, Args)
            end
    end.

-spec delete(binary()) -> ok.
delete(ID) ->
    ok = router_decoder:delete(ID),
    true = ets:delete(?ETS, ID),
    ok.

-spec decode(binary(), list(), integer()) -> {ok, any()} | {error, any()}.
decode(ID, Payload, Port) ->
    case lookup(ID) of
        {error, _Reason}=Error ->
            Error;
        {ok, _Hash, Pid, _Time} ->
            router_decoder_custom_worker:decode(Pid, Payload, Port)
    end.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    ets:new(?ETS, [public, named_table, set]),
    {ok, {?FLAGS, [?WORKER(router_decoder_custom_worker)]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec start_worker(binary(), binary(), map()) -> {ok, pid()} | {error, any()}.
start_worker(ID, Hash, Args) ->
    {ok, VM} = router_v8:get(),
    Map = maps:merge(Args, #{id => ID, vm => VM}),
    case supervisor:start_child(?MODULE, [Map]) of
        {error, _Err}=Err ->
            Err;
        {ok, Pid}=OK ->
            ok = insert(ID, Hash, Pid),
            OK
    end.

-spec stop_worker(binary(), pid()) -> ok.
stop_worker(ID, Pid) ->
    ok = ?MODULE:delete(ID),
    ok = supervisor:terminate_child(?MODULE, Pid),
    ok.

-spec lookup(binary()) -> {ok, binary(), pid(), integer()} | {error, not_found}.
lookup(ID) ->
    case ets:lookup(?ETS, ID) of
        [] -> {error, not_found};
        [{ID, {Hash, Pid, Time}}] ->
            case erlang:is_process_alive(Pid) of
                true -> {ok, Hash, Pid, Time};
                false -> {error, not_found}
            end
    end.

-spec insert(binary(), binary(), pid()) -> ok.
insert(ID, Hash, Pid) ->
    true = ets:insert(?ETS, {ID, {Hash, Pid, erlang:system_time(seconds)}}),
    ok.

-spec maybe_delete_old_context() -> ok.
maybe_delete_old_context() ->
    Max = application:get_env(router, max_v8_context, ?MAX_V8_CONTEXT),
    case ets:info(?ETS, size) + 1 > Max of
        false ->
            ok;
        true ->
            Sorted = lists:sort(fun([{_, T1}], [{_, T2}]) -> T1 > T2 end,
                                ets:match(?ETS, '$1')),
            case Sorted of
                [] -> ok;
                [[{ID, {_Hash, Pid, _Time}}]|_] -> stop_worker(ID, Pid)
            end
    end.
