-module(router_discovery_handler).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4,
    client/2,
    version/0,
    dial/1,
    send/2
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3
]).

-define(VERSION, "discovery/1.0.0").

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

-spec version() -> string().
version() ->
    ?VERSION.

-spec dial(PubKeyBin :: libp2p_crypto:pubkey_bin()) -> {ok, pid()} | {error, term()}.
dial(PubKeyBin) ->
    libp2p_swarm:dial_framed_stream(
        blockchain_swarm:swarm(),
        libp2p_crypto:pubkey_bin_to_p2p(PubKeyBin),
        ?VERSION,
        ?MODULE,
        []
    ).

-spec send(Pid :: pid(), Data :: binary()) -> ok.
send(Pid, Data) ->
    Pid ! {send, Data},
    ok.

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------

init(client, _Conn, _Args) ->
    lager:info("client started with ~p", [_Args]),
    {ok, #state{}};
init(server, _Conn, _Args) ->
    lager:info("server started with ~p", [_Args]),
    {ok, #state{}}.

handle_data(_Type, _Data, State) ->
    lager:warning("~p got data ~p", [_Type, _Data]),
    {noreply, State}.

handle_info(client, {send, Data}, State) ->
    {noreply, State, Data};
handle_info(_Type, _Msg, State) ->
    lager:warning("test ~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
