-module(router_grpc_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    join_grpc_test/1,
    join_from_unknown_device_grpc_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        join_grpc_test,
        join_from_unknown_device_grpc_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    %% setup test dirs
    Config0 = test_utils:init_per_testcase(TestCase, Config),
    LogDir = ?config(log_dir, Config0),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, LogDir}, debug),
    Config0.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%% send a packet from a known device
%% verify we get a response
join_grpc_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [_Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm0, _} = test_utils:start_swarm(BaseDir, swarm0, 0),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Packet = join_packet(PubKeyBin0, AppKey, JoinNonce, -40),

    %% submit the packet via grpc to router
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 8080),

    %% helium.router = service, route = RPC call, router_client_pb is the an auto generated PB file
    {ok, #{headers := Headers, result := #{msg := {response, ResponseMsg}} = Result}} = grpc_client:unary(
        Connection,
        Packet,
        'helium.router',
        'route',
        router_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg, ResponseMsg#{accepted := true}),

    libp2p_swarm:stop(Swarm0),
    ok.

%% send a packet from an unknown device
%% we will fail to get a response
join_from_unknown_device_grpc_test(Config) ->
    _AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [_Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm0, _} = test_utils:start_swarm(BaseDir, swarm1, 0),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    BadAppKey = crypto:strong_rand_bytes(16),
    Packet = join_packet(PubKeyBin0, BadAppKey, JoinNonce, -40),

    %% submit the packet via grpc to router
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 8080),

    %% helium.router = service, route = RPC call, router_client_pb is an auto generated PB file
    {error, #{headers := Headers, status_message := StatusMsg, result := Result}} = grpc_client:unary(
        Connection,
        Packet,
        'helium.router',
        'route',
        router_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(StatusMsg, <<"no response">>),
    ?assertEqual(Result, #{}),

    libp2p_swarm:stop(Swarm0),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

join_packet(PubKeyBin, AppKey, DevNonce, RSSI) ->
    RoutingInfo = {devaddr, 1},
    HeliumPacket = #{
        oui => 0,
        type => lorawan,
        payload => test_utils:join_payload(AppKey, DevNonce),
        timestamp => 1000,
        signal_strength => RSSI,
        frequency => 923.3,
        datarate => <<"SF8BW125">>,
        snr => 0.0,
        routing => #{data => RoutingInfo},
        rx2_window => undefined
    },
    Packet = #{
        packet => HeliumPacket,
        hotspot => PubKeyBin,
        region => 'US915'
    },
    #{msg => {packet, Packet}}.
