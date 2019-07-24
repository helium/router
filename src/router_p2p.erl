%%%-------------------------------------------------------------------
%% @doc
%% == Router P2P ==
%% @end
%%%-------------------------------------------------------------------
-module(router_p2p).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
         start_link/1,
         swarm/0
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

-record(state, {
                swarm :: pid(),
                args :: map()
               }).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec swarm() -> {ok, pid()}.
swarm() ->
    gen_server:call(?SERVER, swarm).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    Swarm = start_swarm(Args),
    lager:info("init with ~p", [Args]),
    {ok, #state{swarm=Swarm, args=Args}}.

handle_call(swarm, _From, #state{swarm=Swarm}=State) ->
    {reply, {ok, Swarm}, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({'EXIT', Swarm, Reason}, #state{swarm=Swarm,
                                            args=Args}=State) ->
    lager:error("swarm ~p went down: ~p, restarting", [Swarm, Reason]),
    NewSwarm = start_swarm(Args),
    {noreply, State#state{swarm=NewSwarm}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason,  #state{swarm=Swarm}) ->
    lager:error("~p terminated: ~p", [?MODULE, _Reason]),
    ok = libp2p_swarm:stop(Swarm).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec start_swarm(map()) -> pid().
start_swarm(Args) ->
    Port = maps:get(port, Args, "0"),
    SeeNodes = maps:get(seed_nodes, Args, []),
    Name = erlang:node(),
    SwarmOpts = [
                 {libp2p_group_gossip, [
                                        {seed_nodes, SeeNodes}
                                       ]}
                ],
    {ok, Swarm} = libp2p_swarm:start(Name, SwarmOpts),
    ok = libp2p_swarm:add_stream_handler(
           Swarm,
           simple_http_stream:version(),
           {libp2p_framed_stream, server, [simple_http_stream, self()]}
          ),
    libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/" ++ Port),
    libp2p_swarm:listen(Swarm, "/ip6/::/tcp/" ++ Port),
    lager:info("created swarm ~p @ ~p p2p address=~p", [Name, Swarm, libp2p_swarm:p2p_address(Swarm)]),
    Swarm.
