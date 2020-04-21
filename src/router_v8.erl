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
         add_decoder/2,
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

-record(state, {vm :: pid()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec add_decoder(binary(), binary()) -> ok.
add_decoder(ID, Function) ->
    case binary:match(Function, <<"function Decoder(bytes, port)">>) of
        nomatch ->
            {error, no_decoder_fun_found};
        _ ->
            {ok, VM} = gen_server:call(?SERVER, vm),
            Hash = crypto:hash(sha256, Function),
            case ets:lookup(?SERVER, ID) of
                [] ->
                    create_context(VM, ID, Function);
                [{ID, {Hash, _VM, _Context}}] ->
                    lager:debug("context ~p already exists", [ID]),
                    ok;
                [{ID, _}] ->
                    _ = ets:delete(?SERVER, ID),
                    create_context(VM, ID, Function)
            end
    end.

-spec decode(binary(), binary(), integer()) -> {ok, any()} | {error, any()}.
decode(ID, Payload, Port) ->
    case ets:lookup(?SERVER, ID) of
        [] ->
            {error, unknown_decoder};
        [{ID, {_Hash, VM, Context}}] ->
            erlang_v8:call(VM, Context, <<"Decoder">>, [erlang:binary_to_list(Payload), Port])
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    ets:new(?SERVER, [public, named_table, set]),
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

-spec create_context(pid(), binary(), binary()) -> ok | {error, any()}.
create_context(VM, ID, Function) ->
    {ok, Context} = erlang_v8:create_context(VM),
    case erlang_v8:eval(VM, Context, Function) of
        {ok, _} ->
            lager:info("context ~p created with ~p", [ID, Function]),
            Hash = crypto:hash(sha256, Function),
            ets:insert(?SERVER, {ID, {Hash, VM, Context}}),
            ok;
        {error, _Reason}=Error ->
            lager:warning("failed to create context ~p: ~p", [ID, _Reason]),
            Error
    end.