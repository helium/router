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
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    ok = router_decoder:init_ets(),
    ok = router_console_dc_tracker:init_ets(),
    ok = router_console_api:init_ets(),
    ok = router_device_stats:init(),
    ok = ru_denylist:init(BaseDir),
    ok = libp2p_crypto:set_network(application:get_env(blockchain, network, mainnet)),
    ok = router_ics_gateway_location_worker:init_ets(),

    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(lager),

    ok = start_location_worker_connection(),

    SeedNodes =
        case application:get_env(blockchain, seed_nodes) of
            {ok, ""} -> [];
            {ok, Seeds} -> string:split(Seeds, ",", all);
            _ -> []
        end,

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
    ok = router_blockchain:save_key(Key),

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
    POCDenyListArgs =
        case
            {
                application:get_env(router, denylist_keys, undefined),
                application:get_env(router, denylist_url, undefined)
            }
        of
            {undefined, _} ->
                #{};
            {_, undefined} ->
                #{};
            {DenyListKeys, DenyListUrl} ->
                #{
                    denylist_keys => DenyListKeys,
                    denylist_url => DenyListUrl,
                    denylist_base_dir => BaseDir,
                    denylist_check_timer => {immediate, timer:hours(12)}
                }
        end,

    {PubKey0, SigFun, _} = Key,
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey0),
    ICSOptsDefault = application:get_env(router, ics, #{}),
    ICSOpts = ICSOptsDefault#{pubkey_bin => PubKeyBin, sig_fun => SigFun},

    {ok, HLC} =
        cream:new(
            200_000,
            [
                {initial_capacity, 20_000},
                {seconds_to_live, 600}
            ]
        ),
    ok = persistent_term:put(hotspot_location_cache, HLC),
    {ok, DevaddrCache} = cream:new(1, [{seconds_to_live, 10}]),
    ok = persistent_term:put(devaddr_subnets_cache, DevaddrCache),

    ChainWorkers =
        case router_blockchain:is_chain_dead() of
            true ->
                [];
            false ->
                [
                    ?SUP(blockchain_sup, [BlockchainOpts]),
                    ?WORKER(router_sc_worker, [SCWorkerOpts]),
                    ?WORKER(router_xor_filter_worker, [#{}])
                ]
        end,

    {ok,
        {?FLAGS,
            [
                ?WORKER(router_ics_devaddr_worker, [ICSOpts]),
                ?WORKER(router_ics_eui_worker, [ICSOpts]),
                ?WORKER(router_ics_skf_worker, [ICSOpts]),
                ?WORKER(router_ics_gateway_location_worker, [ICSOpts]),
                ?WORKER(ru_poc_denylist, [POCDenyListArgs]),
                ?WORKER(router_metrics, [MetricsOpts]),
                ?WORKER(router_db, [DBOpts]),
                ?SUP(router_devices_sup, [])
            ] ++ ChainWorkers ++
                [
                    ?SUP(router_console_sup, []),
                    ?SUP(router_decoder_sup, []),
                    ?WORKER(router_device_devaddr, [#{}])
                ]}}.

%%====================================================================
%% Internal functions
%%====================================================================

start_location_worker_connection() ->
    {ok, #{transport := Transport, host := Host, port := Port}} = application:get_env(router, ics),
    Endpoints = [{Transport, Host, Port, [X]} || X <- lists:seq(1, 5)],
    {ok, _ChannelA} = grpcbox_client:connect(
        router_ics_utils:location_channel(), Endpoints, #{
            sync_start => true
        }
    ),
    ok.
