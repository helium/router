%%%-------------------------------------------------------------------
%% @doc
%% == Simple Packet Stream ==
%% @end
%%%-------------------------------------------------------------------
-module(simple_packet_stream_test).

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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(server, _Conn, _Args) ->
    {ok, #state{}};
init(client, _Conn, _Args) ->
    lager:info("init ~p with ~p", [?MODULE, _Args]),
    {ok, #state{}}.

handle_data(_Type, _Bin, State) ->
    lager:warning("~p got data ~p", [_Type, _Bin]),
    {noreply, State}.

handle_info(client, Msg, State) when is_binary(Msg) ->
    lager:info("got message ~p, sending", [Msg]),
    {noreply, State, Msg};
handle_info(_Type, _Msg, State) ->
    lager:warning("~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
