-module(router_no_channel_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([no_channel_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).
-define(ETS, ?MODULE).

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
    [no_channel_test].

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
no_channel_test(Config) ->
    %% Set console to NO channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {no_channel, true}),

    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    {ok, RouterSwarm} = router_p2p:swarm(),
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
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    %% Send UNCONFIRMED_UP frame packet
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},

    %% Waiting for report channel status from No channel
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => <<"no channels configured">>,
                                            <<"channel_id">> => <<"no_channel">>,
                                            <<"channel_name">> => <<"no_channel">>,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                 <<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"timestamp">> => fun erlang:is_integer/1,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>}]}),

    %% We ignore the channel correction and down messages
    ok = test_utils:ignore_messages(),

    %% Checking that device worker has only no_channel 
    {ok, DeviceWorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    NoChannel = router_channel:new(<<"no_channel">>,
                                   router_no_channel,
                                   <<"no_channel">>,
                                   #{},
                                   ?CONSOLE_DEVICE_ID,
                                   DeviceWorkerPid),
    NoChannelID = router_channel:id(NoChannel),
    ?assertMatch({state, _, _, _, _, _, _, #{NoChannelID := NoChannel}, _, _}, sys:get_state(DeviceWorkerPid)),

    %% Console back to normal mode
    ets:insert(Tab, {no_channel, false}),

    %% Force to refresh channels list
    DeviceWorkerPid ! refresh_channels,
    timer:sleep(250),

    %% Checking that device worker has only HTTP channel now
    State0 = sys:get_state(DeviceWorkerPid),
    ?assertMatch({state, _, _, _, _, _, _, #{?CONSOLE_HTTP_CHANNEL_ID := _}, _, _}, State0),
    ?assertEqual(1, maps:size(erlang:element(8, State0))),

    %% Send UNCONFIRMED_UP frame packet to check http channel is working
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcount">> => 1,
                                   <<"timestamp">> => fun erlang:is_integer/1,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"timestamp">> => fun erlang:is_integer/1,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>}]}),

    %% Waiting for report channel status from HTTP channel
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => <<"success">>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                 <<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"timestamp">> => fun erlang:is_integer/1,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>}]}),

    %% Ignore down messages updates
    ok = test_utils:ignore_messages(),

    %% Console back to no_channel mode
    ets:insert(Tab, {no_channel, true}),

    %% Force to refresh channels list
    DeviceWorkerPid ! refresh_channels,
    timer:sleep(250),

    %% Checking that device worker has only no_channel 
    State1 = sys:get_state(DeviceWorkerPid),
    ?assertMatch({state, _, _, _, _, _, _, #{NoChannelID := NoChannel}, _, _}, State1),
    ?assertEqual(1, maps:size(erlang:element(8, State1))),

    ok.
