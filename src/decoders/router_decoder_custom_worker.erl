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

-record(state, {vm :: pid(),
                context :: pid()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec decode(pid(), list(), integer()) -> {ok, any()} | {error, any()}.
decode(Pid, Payload, Port) ->
    gen_server:call(Pid, {decode, Payload, Port}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, VM} = router_v8:get(),
    Function = maps:get(function, Args),
    {ok, Context} = erlang_v8:create_context(VM),
    {ok, _} = erlang_v8:eval(VM, Context, Function),
    {ok, #state{vm=VM, context=Context}}.

handle_call({decode, Payload, Port}, _From, #state{vm=VM, context=Context}=State) ->
    Reply = erlang_v8:call(VM, Context, <<"Decoder">>, [Payload, Port]),
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{vm=VM, context=Context}=_State) ->
    _ = erlang_v8:destroy_context(VM, Context),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
