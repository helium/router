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
    RouterSwarm = proplists:get_value(swarm, Config),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(RouterSwarm),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Packet = join_packet(PubKeyBin0, AppKey, JoinNonce, -40),

    {ok, #{msg := {response, ResponseMsg}} = Result, #{headers := Headers, trailers := _Trailers}} = helium_router_client:route(
        Packet
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg, ResponseMsg#{accepted := true}),

    ok.

%% send a packet from an unknown device
%% we will fail to get a response
join_from_unknown_device_grpc_test(Config) ->
    RouterSwarm = proplists:get_value(swarm, Config),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(RouterSwarm),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    BadAppKey = crypto:strong_rand_bytes(16),
    Packet = join_packet(PubKeyBin0, BadAppKey, JoinNonce, -40),

    {error, {_ErrorCode, ResponseMsg}, #{headers := Headers, trailers := _Trailers}} = helium_router_client:route(
        Packet
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [ResponseMsg]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg, <<"no response">>),

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
        region => 'US915',
        hold_time => 100
    },
    #{msg => {packet, Packet}}.
