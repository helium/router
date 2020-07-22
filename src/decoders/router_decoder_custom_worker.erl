%%%-------------------------------------------------------------------
%% @doc
%% == Router v8 Context==
%% @end
%%%-------------------------------------------------------------------
-module(router_decoder_custom_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         decode/3]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(TIMER, timer:hours(48)).
-define(MAX_EXECUTION, 500).

-record(state, {id :: binary(),
                vm :: pid(),
                context :: pid(),
                function :: binary(),
                timer :: reference()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec decode(pid(), list(), integer()) -> {ok, any()} | {error, any()}.
decode(Pid, Payload, Port) ->
    gen_server:call(Pid, {decode, Payload, Port}, ?MAX_EXECUTION).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ID = maps:get(id, Args),
    VM = maps:get(vm, Args),
    Function = maps:get(function, Args),
    Context = init_context(VM, Function),
    TimerRef = erlang:send_after(?TIMER, self(), timeout),
    {ok, #state{id=ID, vm=VM, context=Context, function=Function, timer=TimerRef}}.

handle_call({decode, Payload, Port}, _From, #state{vm=VM, context=Context0, function=Function, timer=TimerRef0}=State) ->
    _ = erlang:cancel_timer(TimerRef0),
    TimerRef1 = erlang:send_after(?TIMER, self(), timeout),
    case erlang_v8:call(VM, Context0, <<"Decoder">>, [Payload, Port], ?MAX_EXECUTION) of
        {error, invalid_context} ->
            Reply = {error, function_crashed},
            Context1 = init_context(VM, Function),
            {reply, Reply, State#state{context=Context1, timer=TimerRef1}};
        Reply ->
            {reply, Reply, State#state{timer=TimerRef1}}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(timeout, #state{id=ID}=State) ->
    lager:info("context ~p has not been used for awhile, shutting down", [ID]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{id=ID, vm=VM, context=Context}=_State) ->
    catch erlang_v8:destroy_context(VM, Context),
    ok = router_decoder_custom_sup:delete(ID),
    lager:info("context ~p went down: ~p", [ID, _Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_context(pid(), binary()) -> any().
init_context(VM, Function) ->
    {ok, Context} = erlang_v8:create_context(VM),
    {ok, _} = erlang_v8:eval(VM, Context, Function),
    Context.