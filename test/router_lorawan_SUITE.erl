-module(router_lorawan_SUITE).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([join_test/1]).

-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,0,0,0,0,0>>).
-define(DEVEUI, <<16#EF, 16#BE, 16#AD, 16#DE, 16#EF, 16#BE, 16#AD, 16#DE>>).
-define(ETS, suite_config).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() -> [join_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(router, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, router_device_api_module, router_device_api_console),
    ok = application:set_env(router, console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, console_secret, <<"secret">>),
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    Tab = ets:new(?ETS, [public, set]),
    AppKey = <<16#2B, 16#7E, 16#15, 16#16, 16#28, 16#AE, 16#D2, 16#A6, 16#AB, 16#F7, 16#15, 16#88, 16#09, 16#CF, 16#4F, 16#3C>>,
    ElliOpts = [
                {callback, console_callback},
                {callback_args, #{forward => self(), ets => Tab,
                                  app_key => AppKey, app_eui => ?APPEUI, dev_eui => ?DEVEUI}},
                {port, 3000}
               ],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),
    [{app_key, AppKey}, {ets, Tab}, {elli, Pid}, {base_dir, BaseDir}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(500),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    catch exit(whereis(libp2p_swarm_sup_join_test_swarm_0), kill),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

join_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    Swarm0 = test_utils:start_swarm(BaseDir, join_test_swarm_0, 3620),
    ct:pal("registered ~p", [registered()]),
    Swarm0 = whereis(libp2p_swarm_sup_join_test_swarm_0),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),
    {ok, Stream0} = libp2p_swarm:dial_framed_stream(Swarm0,
                                                    Address,
                                                    router_lorawan_handler_test:version(),
                                                    router_lorawan_handler_test,
                                                    [self(), PubKeyBin0]),
    receive
        {client_data, _,  _Data3} ->
            ct:fail("join didn't fail")
    after 0 ->
            ok
    end,

    %% Send join packet
    JoinNonce = <<5, 0>>,
    receive joining -> ok end,
    receive joined -> ok end,

    {ok, HotspotName0} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin0)),
    test_utils:wait_report_device_status(#{<<"category">> => <<"activation">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                           <<"fcnt_up">> => fun erlang:is_integer/1,
                                           <<"frame_down">> => fun erlang:is_integer/1,
                                           <<"payload_size">> => 0,
                                           <<"port">> => '_',
                                           <<"dev_addr">> => '_',
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName0),
                                                                <<"reported_at">> => fun erlang:is_integer/1,
                                                                <<"status">> => <<"success">>,
                                                                <<"rssi">> => '_',
                                                                <<"snr">> => '_',
                                                                <<"spreading">> => <<"SF7BW125">>,
                                                                <<"frequency">> => fun erlang:is_float/1}],
                                           <<"channels">> => []}),

    %% Waiting for reply resp form router
    {_NetID, _DevAddr, _DLSettings, _RxDelay, NwkSKey, AppSKey} = test_utils:wait_for_join_resp(PubKeyBin0, AppKey, JoinNonce),


    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    NwkSKey = router_device:nwk_s_key(Device0),
    AppSKey = router_device:app_s_key(Device0),
    JoinNonce = router_device:join_nonce(Device0),

    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Msg1 = {true, 2, <<"someotherpayload">>},
    router_device_worker:queue_message(WorkerPid, Msg1),
    Msg2 = {false, 55, <<"sharkfed">>},
    router_device_worker:queue_message(WorkerPid, Msg2),

    receive rx -> ok
    after 1000 -> ct:fail("nothing received from device")
    end,

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcnt">> => 1,
                                   <<"reported_at">> => fun erlang:is_integer/1,
                                   <<"payload">> => base64:encode(<<0>>),
                                   <<"port">> => 2,
                                   <<"dev_addr">> => '_',
                                   <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName0),
                                                        <<"reported_at">> => fun erlang:is_integer/1,
                                                        <<"status">> => <<"success">>,
                                                        <<"rssi">> => -35.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF7BW125">>,
                                                        <<"frequency">> => fun erlang:is_float/1}]}),

    %% Waiting for report channel status from HTTP channel
    test_utils:wait_report_channel_status(#{<<"category">> => <<"up">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                            <<"fcnt_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 1,
                                            <<"port">> => '_',
                                            <<"dev_addr">> => '_',
                                            <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                                                                 <<"name">> => erlang:list_to_binary(HotspotName0),
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"rssi">> => -35.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF7BW125">>,
                                                                 <<"frequency">> => fun erlang:is_float/1}],
                                            <<"channels">> => [#{<<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                                                 <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"description">> => '_'}]}),

    test_utils:wait_report_device_status(#{<<"category">> => <<"down">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                           <<"fcnt_up">> => fun erlang:is_integer/1,
                                           <<"frame_down">> => fun erlang:is_integer/1,
                                           <<"payload_size">> => 0,
                                           <<"port">> => '_',
                                           <<"dev_addr">> => '_',
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName0),
                                                                <<"reported_at">> => fun erlang:is_integer/1,
                                                                <<"status">> => <<"success">>,
                                                                <<"rssi">> => '_',
                                                                <<"snr">> => '_',
                                                                <<"spreading">> => '_',
                                                                <<"frequency">> => fun erlang:is_float/1}],
                                           <<"channels">> => []}),

    test_utils:wait_state_channel_message(?REPLY_DELAY + 250, PubKeyBin0),

    receive rx -> ok
    after 1000 -> ct:fail("nothing received from device")
    end,
    timer:sleep(2000),

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcnt">> => 2,
                                   <<"reported_at">> => fun erlang:is_integer/1,
                                   <<"payload">> => base64:encode(<<0>>),
                                   <<"port">> => 2,
                                   <<"dev_addr">> => '_',
                                   <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName0),
                                                        <<"reported_at">> => fun erlang:is_integer/1,
                                                        <<"status">> => <<"success">>,
                                                        <<"rssi">> => -35.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF7BW125">>,
                                                        <<"frequency">> => fun erlang:is_float/1}]}),

    %% Waiting for report channel status from HTTP channel
    test_utils:wait_report_channel_status(#{<<"category">> => <<"up">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                            <<"fcnt_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 1,
                                            <<"port">> => '_',
                                            <<"dev_addr">> => '_',
                                            <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                                                                 <<"name">> => erlang:list_to_binary(HotspotName0),
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"rssi">> => -35.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF7BW125">>,
                                                                 <<"frequency">> => fun erlang:is_float/1}],
                                            <<"channels">> => [#{<<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                                                 <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"description">> => '_'}]}),

    test_utils:wait_report_device_status(#{<<"category">> => <<"ack">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                           <<"fcnt_up">> => fun erlang:is_integer/1,
                                           <<"frame_down">> => fun erlang:is_integer/1,
                                           <<"payload_size">> => 0,
                                           <<"port">> => '_',
                                           <<"dev_addr">> => '_',
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin0)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName0),
                                                                <<"reported_at">> => fun erlang:is_integer/1,
                                                                <<"status">> => <<"success">>,
                                                                <<"rssi">> => '_',
                                                                <<"snr">> => '_',
                                                                <<"spreading">> => '_',
                                                                <<"frequency">> => fun erlang:is_float/1}],
                                           <<"channels">> => []}),

    test_utils:wait_state_channel_message(?REPLY_DELAY + 250, PubKeyBin0),

    Stream0 ! get_channel_mask,
    receive {channel_mask, Mask} ->
            ExpectedMask = lists:seq(48, 55),
            Mask = ExpectedMask
    after 100 ->
            ct:fail("channel mask not corrected")
    end,

    %% check the device got our downlink
    receive {tx, 2, true, <<"someotherpayload">>} -> ok
    after 5000 -> ct:fail("device did not see downlink 1")
    end,
    receive {tx, 55, false, <<"sharkfed">>} -> ok
    after 5000 -> ct:fail("device did not see downlink 2")
    end,

    libp2p_swarm:stop(Swarm0),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
