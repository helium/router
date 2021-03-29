-module(router_discovery_handler_test).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4,
    client/2
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3
]).

-record(state, {forward :: pid() | undefined}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    lager:info("starting server with ~p", [{Connection, Path, _TID, Args}]),
    libp2p_framed_stream:server(?MODULE, Connection, Args).

client(Connection, Args) ->
    lager:info("starting client with ~p", [{Connection, Args}]),
    libp2p_framed_stream:client(?MODULE, Connection, Args).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------

init(client, _Conn, _Args) ->
    lager:info("client started with ~p", [_Args]),
    {ok, #state{}};
init(server, _Conn, _Args) ->
    lager:info("server started with ~p", [_Args]),
    [Pid] = _Args,
    {ok, #state{forward = Pid}}.

handle_data(server, Data, #state{forward = Pid} = State) ->
    lager:info("server got data ~p", [Data]),
    Pid ! {?MODULE, Data},
    {noreply, State};
handle_data(_Type, _Data, State) ->
    lager:warning("~p got data ~p", [_Type, _Data]),
    {noreply, State}.

handle_info(_Type, _Msg, State) ->
    lager:warning("test ~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
