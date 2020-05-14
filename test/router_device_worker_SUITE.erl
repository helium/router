-module(router_device_worker_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([not_found_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).

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
    [not_found_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

not_found_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(Swarm,
                                                   Address,
                                                   router_handler_test:version(),
                                                   router_handler_test,
                                                   [self()]),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for report device status on that join request
    test_utils:wait_report_device_status(#{<<"category">> => <<"activation">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"payload_size">> => 0,
                                           <<"port">> => '_',
                                           <<"devaddr">> => '_',
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName),
                                                                <<"reported_at">> => fun erlang:is_integer/1,
                                                                <<"status">> => <<"success">>,
                                                                <<"rssi">> => 0.0,
                                                                <<"snr">> => 0.0,
                                                                <<"spreading">> => <<"SF8BW125">>,
                                                                <<"frequency">> => fun erlang:is_float/1}],
                                           <<"channels">> => []}),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    DeviceID = ?CONSOLE_DEVICE_ID,
    ?assertMatch({ok, _}, router_device:get(DB, CF, DeviceID)),

    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {device_not_found, true}),
    {ok, DeviceWorkerID} = router_devices_sup:lookup_device_worker(DeviceID),
    DeviceWorkerID ! refresh_device_metadata,

    timer:sleep(500),
    ?assertNot(erlang:is_process_alive(DeviceWorkerID)),
    ?assertMatch({error, not_found}, router_device:get(DB, CF, DeviceID)),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
