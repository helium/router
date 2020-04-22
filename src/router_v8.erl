%%%-------------------------------------------------------------------
%% @doc
%% == Router v8 ==
%% @end
%%%-------------------------------------------------------------------
-module(router_v8).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         get/0]).

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

-record(state, {vm :: pid()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec get() -> {ok, pid()}.
get() ->
    gen_server:call(?SERVER, vm).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("~p init with ~p", [?SERVER, _Args]),
    {ok, VM} = erlang_v8:start_vm(),
    {ok, #state{vm=VM}}.

handle_call(vm, _From, #state{vm=VM}=State) ->
    {reply, {ok, VM}, State};
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

terminate(_Reason, #state{vm=VM}=_State) ->
    _ = erlang_v8:stop_vm(VM),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------