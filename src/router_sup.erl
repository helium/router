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
    _ = router_decoder:init_ets(),

    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(lager),

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
        {port, application:get_env(router, port, 0)},
        {base_dir, BaseDir},
        {update_dir, application:get_env(router, update_dir, undefined)}
    ],
    SCWorkerOpts = #{},
    DBOpts = [BaseDir],
    MetricsOpts = #{},

    %% set config for chatterbox
    %% if a new http2 handler is added, be sure to add its route/path and
    %% associated module to the fun below
    RouterHttp2HandlerRoutingFun = fun
        (<<"/v1/router/message">>) -> {ok, http2_handler_router_message_v1};
        (UnknownRequestType) -> {error, {handler_not_found, UnknownRequestType}}
    end,

    ok = application:set_env(
        chatterbox,
        stream_callback_opts,
        [
            {http2_handler_routing_fun, RouterHttp2HandlerRoutingFun},
            {http2_client_ref_header_name, <<"x-gateway-id">>}
        ]
    ),

    {ok,
        {?FLAGS, [
            ?WORKER(router_metrics, [MetricsOpts]),
            ?SUP(blockchain_sup, [BlockchainOpts]),
            ?WORKER(router_db, [DBOpts]),
            ?SUP(router_devices_sup, []),
            ?WORKER(router_sc_worker, [SCWorkerOpts]),
            ?SUP(router_console_sup, []),
            ?WORKER(router_v8, [#{}]),
            ?WORKER(router_device_devaddr, [#{}]),
            ?SUP(chatterbox_sup, []),
            ?SUP(router_decoder_custom_sup, [])
        ]}}.

%%====================================================================
%% Internal functions
%%====================================================================
