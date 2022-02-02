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

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [I]
}).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

-define(WORKER(I, Mod, Args), #{
    id => I,
    start => {Mod, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

-define(FLAGS, #{
    strategy => rest_for_one,
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
    ok = router_decoder:init_ets(),
    ok = libp2p_crypto:set_network(application:get_env(blockchain, network, mainnet)),

    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(lager),

    SeedNodes =
        case application:get_env(blockchain, seed_nodes) of
            {ok, ""} -> [];
            {ok, Seeds} -> string:split(Seeds, ",", all);
            _ -> []
        end,
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    SwarmKey = filename:join([BaseDir, "blockchain", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    Key =
        case libp2p_crypto:load_keys(SwarmKey) of
            {ok, #{secret := PrivKey, public := PubKey}} ->
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)};
            {error, enoent} ->
                KeyMap =
                    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(
                        ecc_compact
                    ),
                ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
                {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)}
        end,
    BlockchainOpts = [
        {key, Key},
        {seed_nodes, SeedNodes},
        {max_inbound_connections, 10},
        {port, application:get_env(blockchain, port, 0)},
        {base_dir, BaseDir},
        {update_dir, application:get_env(blockchain, update_dir, undefined)}
    ],
    SCWorkerOpts = #{},
    DBOpts = [BaseDir],
    MetricsOpts = #{},

    {ok,
        {?FLAGS, [
            ?SUP(blockchain_sup, [BlockchainOpts]),
            ?WORKER(router_metrics, [MetricsOpts]),
            ?WORKER(router_db, [DBOpts]),
            ?SUP(router_devices_sup, []),
            ?WORKER(router_sc_worker, [SCWorkerOpts]),
            ?SUP(router_console_sup, []),
            ?SUP(router_decoder_sup, []),
            ?WORKER(router_device_devaddr, [#{}]),
            ?WORKER(router_xor_filter_worker, [#{}])
        ]}}.

%%====================================================================
%% Internal functions
%%====================================================================
