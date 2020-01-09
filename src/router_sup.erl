%%%-------------------------------------------------------------------
%% @doc router top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(router_sup).

-behaviour(supervisor).

-include("router.hrl").

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
    {ok, _} = application:ensure_all_started(hackney),

    PoolOptions = [{max_connections, application:get_env(router, max_connections, 250)}],
    ok = hackney_pool:start_pool(?HTTP_POOL, PoolOptions),

    SeedNodes =
        case application:get_env(router, seed_nodes) of
            {ok, ""} -> [];
            {ok, Seeds} -> string:split(Seeds, ",", all);
            _ -> []
        end,
    BaseDir = application:get_env(router, base_dir, "data"),
    SwarmKey = filename:join([BaseDir, "router", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    Key =
        case libp2p_crypto:load_keys(SwarmKey) of
            {ok, #{secret := PrivKey, public := PubKey}} ->
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)};
            {error, enoent} ->
                KeyMap = #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
                ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)}
        end,
    BlockchainOpts = [
                      {key, Key},
                      {seed_nodes, SeedNodes},
                      {max_inbound_connections, 10},
                      {port, 0},
                      {base_dir, BaseDir},
                      {update_dir, application:get_env(router, update_dir, undefined)}
                     ],
    RouterServerOpts = #{},
    {ok, { ?FLAGS, [?SUP(blockchain_sup, [BlockchainOpts]), ?WORKER(router_server, [RouterServerOpts])]} }.

%%====================================================================
%% Internal functions
%%====================================================================
