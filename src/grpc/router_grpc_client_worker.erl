%%%-------------------------------------------------------------------
%% @doc
%% @end
%%%-------------------------------------------------------------------
-module(router_grpc_client_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/0
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
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, #{}, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("~p init with ~p", [?SERVER, _Args]),
    case application:get_env(grpcbox, client) of
        {ok, #{channels := Channels}} ->
            lists:foreach(
                fun({Name, Endpoints, Options}) ->
                    R = grpcbox_channel_sup:start_child(Name, Endpoints, Options),
                    lager:info("started ~p ~p", [{Name, Endpoints, Options}, R])
                end,
                Channels
            );
        _ ->
            ok
    end,
    {ok, #state{}}.

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

terminate(_Reason, #state{}) ->
    ok.
