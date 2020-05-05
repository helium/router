-module(router_channel_no_channel_SUITE).

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
    test_utils:wait_report_device_status(#{<<"category">> => <<"activation">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                           <<"fcnt_up">> => 0,
                                           <<"fcnt_down">> => 0,
                                           <<"frm_payload_size">> => 0,
                                           <<"fport">> => '_',
                                           <<"dev_addr">> => '_',
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
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    %% Send UNCONFIRMED_UP frame packet
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},

    %% Waiting for report channel status from No channel
    test_utils:wait_report_channel_status(#{<<"category">> => <<"up">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                            <<"fcnt_up">> => fun erlang:is_integer/1,
                                            <<"fcnt_down">> => fun erlang:is_integer/1,
                                            <<"frm_payload_size">> => 0,
                                            <<"fport">> => '_',
                                            <<"dev_addr">> => '_',
                                            <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                 <<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>,
                                                                 <<"frequency">> => fun erlang:is_float/1}],
                                            <<"channels">> => [#{<<"id">> => <<"no_channel">>,
                                                                 <<"name">> => <<"no_channel">>,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"no_channel">>,
                                                                 <<"description">> => <<"no channels configured">>}]}),

    %% We ignore the channel correction and down messages
    ok = test_utils:ignore_messages(),

    %% Checking that device channels worker has only no_channel 
    DeviceChannelsWorkerPid = test_utils:get_device_channels_worker(?CONSOLE_DEVICE_ID),
    NoChannel = router_channel:new(<<"no_channel">>,
                                   router_no_channel,
                                   <<"no_channel">>,
                                   #{},
                                   ?CONSOLE_DEVICE_ID,
                                   DeviceChannelsWorkerPid),
    NoChannelID = router_channel:id(NoChannel),
    ?assertMatch({state, _, _, _, #{NoChannelID := NoChannel}, _, _, _, _}, sys:get_state(DeviceChannelsWorkerPid)),

    %% Console back to normal mode
    ets:insert(Tab, {no_channel, false}),

    %% Force to refresh channels list
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),

    %% Checking that device worker has only HTTP channel now
    State0 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertMatch({state, _, _, _, #{?CONSOLE_HTTP_CHANNEL_ID := _}, _, _, _, _}, State0),
    ?assertEqual(1, maps:size(erlang:element(5, State0))),

    %% Send UNCONFIRMED_UP frame packet to check http channel is working
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcnt_up">> => 1,
                                   <<"reported_at">> => fun erlang:is_integer/1,
                                   <<"frm_payload">> => <<>>,
                                   <<"fport">> => 1,
                                   <<"dev_addr">> => '_',
                                   <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"reported_at">> => fun erlang:is_integer/1,
                                                        <<"status">> => <<"success">>,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>,
                                                        <<"frequency">> => fun erlang:is_float/1}]}),

    %% Waiting for report channel status from HTTP channel
    test_utils:wait_report_channel_status(#{<<"category">> => <<"up">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                            <<"fcnt_up">> => fun erlang:is_integer/1,
                                            <<"fcnt_down">> => fun erlang:is_integer/1,
                                            <<"frm_payload_size">> => 0,
                                            <<"fport">> => '_',
                                            <<"dev_addr">> => '_',
                                            <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                 <<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>,
                                                                 <<"frequency">> => fun erlang:is_float/1}],
                                            <<"channels">> => [#{<<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                                                 <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"description">> => '_'}]}),

    %% Ignore down messages updates
    ok = test_utils:ignore_messages(),

    %% Console back to no_channel mode
    ets:insert(Tab, {no_channel, true}),

    %% Force to refresh channels list
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),

    %% Checking that device worker has only no_channel 
    State1 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertMatch({state, _, _, _, #{NoChannelID := NoChannel}, _, _, _, _}, State1),
    ?assertEqual(1, maps:size(erlang:element(5, State1))),

    ok.
