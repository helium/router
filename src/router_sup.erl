%%%-------------------------------------------------------------------
%% @doc router top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(router_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SUP(I, Args), 
        #{
          id => I,
          start => {I, start_link, Args},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [I]
         }).

-define(WORKER(I, Args), 
        #{
          id => I,
          start => {I, start_link, Args},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [I]
         }).

-define(WORKER(I, Mod, Args), 
        #{
          id => I,
          start => {Mod, start_link, Args},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [I]
         }).

-define(FLAGS, 
        #{
          strategy => one_for_all,
          intensity => 1,
          period => 5
         }).


-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(lager),
    SeedNodes = case application:get_env(router, seed_nodes) of
                    {ok, ""} -> [];
                    {ok, Seeds} -> string:split(Seeds, ",", all);
                    _ -> []
                end,
    P2PWorkerOpts = #{
                      port => application:get_env(router, port, "0"),
                      seed_nodes => SeedNodes,
                      base_dir => application:get_env(router, base_dir, "data")
                     },
    P2PWorker = ?WORKER(router_p2p, [P2PWorkerOpts]),
    {ok, { ?FLAGS, [P2PWorker]} }.

%%====================================================================
%% Internal functions
%%====================================================================
