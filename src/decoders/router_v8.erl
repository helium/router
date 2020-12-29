%%%-------------------------------------------------------------------
%% @doc
%% == Router v8 ==
%% @end
%%%-------------------------------------------------------------------
-module(router_v8).

-behavior(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    get/0
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(REG_NAME, router_v8_vm).
-define(VM_CHECK_TICK, pull_data_timeout_tick).
-define(VM_CHECK_TIMER, timer:minutes(2)).
-define(VM_CHECK_FUN_NAME, <<"vm_check">>).
-define(VM_CHECK_FUN, <<"function ", ?VM_CHECK_FUN_NAME/binary, "() {return 0;}">>).

-record(state, {vm :: pid()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec get() -> {ok, pid()}.
get() ->
    {ok, erlang:whereis(?REG_NAME)}.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("~p init with ~p", [?SERVER, _Args]),
    {ok, VM} = erlang_v8:start_vm(),
    true = erlang:register(?REG_NAME, VM),
    ok = schedule_vm_check(),
    {ok, #state{vm = VM}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?VM_CHECK_TICK, #state{vm = VM} = State) ->
    case erlang_v8:create_context(VM) of
        {ok, Context} ->
            case erlang_v8:eval(VM, Context, ?VM_CHECK_FUN) of
                {ok, _} ->
                    case erlang_v8:call(VM, Context, ?VM_CHECK_FUN_NAME, [], 50) of
                        {ok, 0} ->
                            ok = erlang_v8:destroy_context(VM, Context),
                            {noreply, State};
                        {error, _Reason} ->
                            lager:error("failed to call function ~p", [_Reason]),
                            {stop, failed_call_fun, State}
                    end;
                {error, _Reason} ->
                    lager:error("failed to eval function ~p", [_Reason]),
                    {stop, failed_eval_fun, State}
            end;
        {error, _Reason} ->
            lager:error("failed to create context ~p", [_Reason]),
            {stop, failed_create_context, State}
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{vm = VM} = _State) ->
    _ = erlang:unregister(?REG_NAME),
    _ = erlang_v8:stop_vm(VM),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec schedule_vm_check() -> ok.
schedule_vm_check() ->
    _ = erlang:send_after(?VM_CHECK_TIMER, self(), ?VM_CHECK_TICK),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

vm_check_test() ->
    {ok, Pid} = ?MODULE:start_link(#{}),
    Pid ! ?VM_CHECK_TICK,
    timer:sleep(100),

    ?assert(erlang:is_process_alive(Pid)),

    gen_server:stop(Pid),
    ok.

-endif.
