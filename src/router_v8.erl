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

-record(state, {vm :: pid(),
                contexts = #{} :: map()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec add_decoder(binary(), binary()) -> ok.
add_decoder(ID, Payload) ->
    gen_server:call(?SERVER, {add_decoder, ID, Payload}).

-spec decode(binary(), binary(), integer()) -> {ok, pid(), pid()}.
decode(ID, Payload, Port) ->
    gen_server:call(?SERVER, {decode, ID, erlang:binary_to_list(Payload), Port}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("~p init with ~p", [?SERVER, _Args]),
    {ok, VM} = erlang_v8:start_vm(),
    {ok, #state{vm=VM}}.

handle_call({add_decoder, ID, JS}, _From, #state{vm=VM, contexts=Contexts}=State) ->
    case binary:match(JS, <<"function Decoder(bytes, port)">>) of
        nomatch ->
            {reply, {error, no_decoder_fun_found}, State};
        _ ->
            case maps:get(ID, Contexts, undefined) of
                undefined ->
                    {ok, Context} = erlang_v8:create_context(VM),
                    case erlang_v8:eval(VM, Context, JS) of
                        {ok, _} ->
                            lager:info("context ~p created with ~p", [ID, JS]),
                            {reply, ok, State#state{contexts=maps:put(ID, Context, Contexts)}};
                        {error, _Reason}=Error ->
                            lager:warning("failed to create context ~p: ~p", [ID, _Reason]),
                            {reply, Error, State}
                    end;
                _Context ->
                    lager:debug("context ~p already exists", [ID]),
                    {reply, ok, State}
            end
    end;
handle_call({decode, ID, Payload, Port}, _From, #state{vm=VM, contexts=Contexts}=State) ->
    case maps:get(ID, Contexts, undefined) of
        undefined ->
            {reply, {error, unknown_decoder}, State};
        Context ->
            {ok, Res} = erlang_v8:call(VM, Context, <<"Decoder">>, [Payload, Port]),
            {reply, {ok, Res}, State}
    end;
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
