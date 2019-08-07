
%%%-------------------------------------------------------------------
%% @doc
%% == Router HTTP oWrker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_http_worker).

-behavior(gen_server).


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
         start_link/1,
         send/2
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
-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec send(string(), binary()) -> ok.
send(Endpoint, Data) ->
    gen_server:cast(?SERVER, {send, Endpoint, Data}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    MaxConn = maps:get(max_connections, Args, 250),
    PoolOptions = [{max_connections, MaxConn}],
    ok = hackney_pool:start_pool(?SERVER, PoolOptions),
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({send, Endpoint, Data}, State) ->
    Headers = [{<<"Content-Type">>, <<"application/octet-stream">>}],
    try hackney:post(Endpoint, Headers, Data, []) of
        {ok, 200, _RespHeaders, _ClientRef}->
            lager:info("got: ok");
        {ok, StatusCode, _RespHeaders, ClientRef} ->
            {ok, _Body} = hackney:body(ClientRef),
            lager:error("got: non 200 from server ~p ~p ~p", [StatusCode, _RespHeaders, _Body]);
        {error, _Reason} ->
            lager:error("failed to post to ~p got error ~p", [Endpoint, _Reason])
    catch
        E:R ->
            lager:error("failed to post to ~p got error ~p", [Endpoint, {E, R}])
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    hackney_pool:stop_pool(?SERVER),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
