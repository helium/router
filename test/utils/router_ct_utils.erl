-module(router_ct_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("console_test.hrl").
-include("router_ct_macros.hrl").

-export([
         init_per_testcase/3,
         end_per_testcase/2
        ]).

%% configures one router by default
init_per_testcase(Mod, TestCase, Config0) ->
    init_per_testcase(Mod, TestCase, Config0, 1).

init_per_testcase(Mod, TestCase, Config0, NumRouters) ->
    MinerConfig = miner_test:init_per_testcase(Mod, TestCase, Config0),
    RouterConfig = init_router_config(MinerConfig, NumRouters),

    MinerConfig ++ RouterConfig.

init_router_config(Config, NumRouters) ->
    BaseDir = ?config(base_dir, Config),
    LogDir = ?config(log_dir, Config),
    MinerListenAddrs = ?config(miner_listen_addrs, Config),
    Miners = ?config(miners, Config),

    %% Router configuration
    TotalRouters = os:getenv("R", NumRouters),
    Port = list_to_integer(os:getenv("PORT", "0")),
    RoutersAndPorts = miner_test:init_ports(Config, TotalRouters),
    RouterKeys = miner_test:init_keys(Config, RoutersAndPorts),
    SeedNodes = [],

    %% NOTE: elli must be running before router nodes start
    Tab = ets:new(router_ct_utils, [public, set]),
    ElliOpts = [{callback, console_callback},
                {callback_args, #{forward => self(), ets => Tab,
                                  app_key => ?APPKEY, app_eui => ?APPEUI, dev_eui => ?DEVEUI}},
                {port, 3000}
               ],
    {ok, ElliPid} = elli:start_link(ElliOpts),


    %% Get router config results
    RouterConfigResult = router_config_result(LogDir, BaseDir, Port, SeedNodes, RouterKeys),

    %% Gather router nodes
    Routers = [M || {M, _} <- RoutersAndPorts],

    %% check that the config loaded correctly on each router
    true = miner_test:check_config_result(RouterConfigResult),

    %% Gather router listen addrs
    RouterListenAddrs = miner_test:acc_listen_addrs(Routers),

    %% connect nodes
    true = miner_test:connect_addrs(Miners, RouterListenAddrs),
    true = miner_test:connect_addrs(Routers, MinerListenAddrs),

    %% make sure routers are also talking to the miners
    true = miner_test:check_gossip(Routers, MinerListenAddrs),
    true = miner_test:check_gossip(Miners, RouterListenAddrs),

    %% accumulate the pubkey_bins of each miner
    RouterPubkeyBins = miner_test:acc_pubkey_bins(Routers),

    %% add both miners and router to cover
    {ok, _} = ct_cover:add_nodes(Miners ++ Routers),

    %% wait until we get confirmation the miners are fully up
    %% which we are determining by the miner_consensus_mgr being registered
    ok = miner_test:wait_for_registration(Miners, miner_consensus_mgr),

    [
     {routers, Routers},
     {router_keys, RouterKeys},
     {router_pubkey_bins, RouterPubkeyBins},
     {elli, ElliPid}
    | Config
    ].

end_per_testcase(TestCase, Config) ->
    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),
    miner_test:pmap(fun(Miner) -> ct_slave:stop(Miner) end, Miners),
    miner_test:pmap(fun(Router) -> ct_slave:stop(Router) end, Routers),
    case ?config(tc_status, Config) of
        ok ->
            %% test passed, we can cleanup
            miner_test:cleanup_per_testcase(TestCase, Config);
        _ ->
            %% leave results alone for analysis
            ok
    end,
    {comment, done}.

router_config_result(LogDir, BaseDir, Port, SeedNodes, RouterKeys) ->
    miner_test:pmap(
      fun({Router, {_TCPPort1, _UDPPort1}, _ECDH, _PubKey, _Addr, _SigFun}) ->
              ct:pal("Router ~p", [Router]),
              ct_rpc:call(Router, cover, start, []),
              ct_rpc:call(Router, application, load, [lager]),
              ct_rpc:call(Router, application, load, [blockchain]),
              ct_rpc:call(Router, application, load, [libp2p]),
              ct_rpc:call(Router, application, load, [router]),
              %% give each node its own log directory
              LogRoot = LogDir ++ "_router_" ++ atom_to_list(Router),
              ct_rpc:call(Router, application, set_env, [lager, log_root, LogRoot]),
              ct_rpc:call(Router, lager, set_loglevel, [{lager_file_backend, "log/console.log"}, debug]),

              %% set blockchain configuration
              #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
              Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)},
              RouterBaseDir = BaseDir ++ "_router_" ++ atom_to_list(Router),
              ct_rpc:call(Router, application, set_env, [blockchain, base_dir, RouterBaseDir]),
              ct_rpc:call(Router, application, set_env, [blockchain, port, Port]),
              ct_rpc:call(Router, application, set_env, [blockchain, seed_nodes, SeedNodes]),
              ct_rpc:call(Router, application, set_env, [blockchain, key, Key]),
              ct_rpc:call(Router, application, set_env, [blockchain, sc_client_handler, router_sc_client_handler]),
              ct_rpc:call(Router, application, set_env, [blockchain, sc_packet_handler, router_device_routing]),

              %% Set router configuration
              ct_rpc:call(Router, application, set_env, [router, base_dir, RouterBaseDir]),
              ct_rpc:call(Router, application, set_env, [router, port, Port]),
              ct_rpc:call(Router, application, set_env, [router, seed_nodes, SeedNodes]),
              ct_rpc:call(Router, application, set_env, [router, oui, 1]),
              ct_rpc:call(Router, application, set_env, [router, router_device_api_module, router_console_device_api]),
              ct_rpc:call(Router, application, set_env, [router, router_console_device_api,
                                                         [{endpoint, ?CONSOLE_URL},
                                                          {ws_endpoint, ?CONSOLE_WS_URL},
                                                          {secret, <<"yolo">>}]]),
              ct_rpc:call(Router, application, set_env, [router, metrics_port, 0]),
              {ok, StartedApps} = ct_rpc:call(Router, application, ensure_all_started, [router]),
              ct:pal("Router: ~p, StartedApps: ~p", [Router, StartedApps])
      end,
      RouterKeys
     ).
