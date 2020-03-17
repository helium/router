-module(router_SUITE).

-export([
         all/0,
         init_per_testcase/2,
         end_per_testcase/2
        ]).

-export([
         http_test/1,
         dupes_test/1,
         join_test/1,
         mqtt_test/1,
         aws_test/1,
         no_channel_test/1
        ]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).
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
all() ->
    [
     http_test,
     dupes_test,
     join_test,
     mqtt_test,
     no_channel_test
    ].

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
    AppKey = crypto:strong_rand_bytes(16),
    ElliOpts = [
                {callback, console_callback},
                {callback_args, #{forward => self(), ets => Tab, app_key => AppKey}},
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
    e2qc:teardown(console_cache),
    ok = application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

http_test(Config) ->
    BaseDir = proplists:get_value(base_dir, Config),
    AppKey = proplists:get_value(app_key, Config),
    Swarm = test_utils:start_swarm(BaseDir, http_test_swarm, 3616),
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
    Stream ! {send, join_packet(PubKeyBin, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for console repor status sent
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    %% Waiting for reply resp form router
    test_utils:wait_state_channel_message(250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(<<"yolo_id">>),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),
    %% Send CONFIRMED_UP frame packet needing an ack back
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 0,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    test_utils:wait_state_channel_message(?REPLY_DELAY + 250),

    %% Adding a message to queue
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Msg = {false, 1, <<"somepayload">>},
    router_device_worker:queue_message(WorkerPid, Msg),
    timer:sleep(200),
    {ok, Device1} = router_device:get(DB, CF, WorkerID),
    ?assertEqual([Msg], router_device:queue(Device1)),

    %% Sending UNCONFIRMED_UP frame packet and then we should get back message that was in queue
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 1,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"ack">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 1,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    {ok, _} = test_utils:wait_state_channel_message(Msg, Device0, erlang:element(3, Msg), ?UNCONFIRMED_DOWN, 0, 0, 1, 1),

    {ok, Device2} = router_device:get(DB, CF, WorkerID),
    ?assertEqual([], router_device:queue(Device2)),

    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 2, #{body => <<1:8/integer, "reply">>})},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => base64:encode(<<"reply">>),
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 2,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"down">>,
                                           <<"frame_up">> => 1,
                                           <<"frame_down">> => 2,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 2,
                                            <<"frame_down">> => 2,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 5,
                                            <<"payload">> => base64:encode(<<"reply">>),
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),

    %%ok = wait_for_post_channel(PubKeyBin, base64:encode(<<"reply">>)),
    %%ok = wait_for_report_status(PubKeyBin),
    %% Message shoud come in fast as it is already in the queue no neeed to wait
    {ok, _Reply1} = test_utils:wait_state_channel_message({true, 1, <<"ack">>}, Device0, <<"ack">>, ?CONFIRMED_DOWN, 0, 0, 1, 2),


    %% Lets do some key checking
    ?assertEqual(undefined, router_device:key(Device2)),
    Key = router_device_worker:key(WorkerPid),
    ?assertEqual(Key, router_device_worker:key(WorkerPid)),
    {ok, Device3} = router_device:get(DB, CF, WorkerID),
    ?assertEqual(Key, router_device:key(Device3)),

    libp2p_swarm:stop(Swarm),
    ok.

dupes_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    AppKey = proplists:get_value(app_key, Config),
    ets:insert(Tab, {show_dupes, true}),
    BaseDir = proplists:get_value(base_dir, Config),
    Swarm = test_utils:start_swarm(BaseDir, dupes_test_swarm, 3617),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(Swarm,
                                                   Address,
                                                   router_handler_test:version(),
                                                   router_handler_test,
                                                   [self()]),
    PubKeyBin1 = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName1} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, join_packet(PubKeyBin1, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for console repor status sent
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName1)}),
    %% Waiting for reply resp form router
    test_utils:wait_state_channel_message(250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(<<"yolo_id">>),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Msg0 = {false, 1, <<"somepayload">>},
    router_device_worker:queue_message(WorkerPid, Msg0),
    Msg1 = {true, 2, <<"someotherpayload">>},
    router_device_worker:queue_message(WorkerPid, Msg1),

    %% Send 2 similar packet to make it look like it's coming from 2 diff hotspot
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin1, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey),
    {ok, HotspotName2} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin2)),
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName1),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 0,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName1),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 0,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    {ok, Reply1} = test_utils:wait_state_channel_message(Msg0, Device0, erlang:element(3, Msg0), ?UNCONFIRMED_DOWN, 1, 0, 1, 0),
    ct:pal("Reply ~p", [Reply1]),
    true = lists:keymember(link_adr_req, 1, Reply1#frame.fopts),

    %% We had message in the queue so we expect a device status down
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"down">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName1)}),

    %% Make sure we did not get a duplicate
    receive
        {client_data, _, _Data2} ->
            ct:fail("double_reply ~p", [blockchain_state_channel_v1_pb:decode_msg(_Data2, blockchain_state_channel_message_v1_pb)])
    after 0 ->
            ok
    end,

    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 1,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 1,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"ack">>,
                                           <<"frame_up">> => 1,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName2)}),
    {ok, Reply2} = test_utils:wait_state_channel_message(Msg1, Device0, erlang:element(3, Msg1), ?CONFIRMED_DOWN, 0, 1, 2, 1),
    %% check we're still getting ADR commands
    true = lists:keymember(link_adr_req, 1, Reply2#frame.fopts),

    %% check we get the second downlink again because we didn't ACK it
    %% also ack the ADR adjustments
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 2, #{fopts => [{link_adr_ans, 1, 1, 1}]})},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 2,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 2,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"down">>,
                                           <<"frame_up">> => 2,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName2)}),
    {ok, Reply3} = test_utils:wait_state_channel_message(Msg1, Device0, erlang:element(3, Msg1), ?CONFIRMED_DOWN, 0, 0, 2, 1),
    %% check NOT we're still getting ADR commands
    false = lists:keymember(link_adr_req, 1, Reply3#frame.fopts),

    %% ack the packet, we don't expect a reply here
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 2, #{should_ack => true})},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 2,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 2,
                                            <<"frame_down">> => 2,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    timer:sleep(1000),
    receive
        {client_data, _,  _Data3} ->
            ct:fail("unexpected_reply ~p", [blockchain_state_channel_v1_pb:decode_msg(_Data3, blockchain_state_channel_message_v1_pb)])
    after 0 ->
            ok
    end,

    %% send a confimed up to provoke a 'bare ack'
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 3)},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 3,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 3,
                                            <<"frame_down">> => 2,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"ack">>,
                                           <<"frame_up">> => 3,
                                           <<"frame_down">> => 3,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName2)}),
    {ok, Reply4} = test_utils:wait_state_channel_message(Msg1, Device0, <<>>, ?UNCONFIRMED_DOWN, 0, 1, undefined, 2),

    %% check NOT we're still getting ADR commands
    false = lists:keymember(link_adr_req, 1, Reply4#frame.fopts),

    libp2p_swarm:stop(Swarm),
    ok.

join_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    Swarm0 = test_utils:start_swarm(BaseDir, join_test_swarm_0, 3620),
    Swarm1 = test_utils:start_swarm(BaseDir, join_test_swarm_1, 3621),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),
    PubKeyBin1 = libp2p_swarm:pubkey_bin(Swarm1),
    {ok, Stream0} = libp2p_swarm:dial_framed_stream(Swarm0,
                                                    Address,
                                                    router_handler_test:version(),
                                                    router_handler_test,
                                                    [self(), PubKeyBin0]),
    {ok, Stream1} = libp2p_swarm:dial_framed_stream(Swarm1,
                                                    Address,
                                                    router_handler_test:version(),
                                                    router_handler_test,
                                                    [self(), PubKeyBin1]),


    Stream0 ! {send, join_packet(PubKeyBin0, crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(2), -100)},

    receive
        {client_data, _,  _Data3} ->
            ct:fail("join didn't fail")
    after 0 ->
            ok
    end,

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream0 ! {send, join_packet(PubKeyBin0, AppKey, JoinNonce, -100)},
    timer:sleep(500),
    Stream1 ! {send, join_packet(PubKeyBin1, AppKey, JoinNonce, -80)},
    timer:sleep(?JOIN_DELAY),

    {ok, HotspotName1} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    %% Waiting for console repor status sent (it should select PubKeyBin1 cause better rssi)
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName1)}),
    %% Waiting for reply resp form router
    {_NetID, _DevAddr, _DLSettings, _RxDelay, NwkSKey, AppSKey} = test_utils:wait_for_join_resp(PubKeyBin1, AppKey, JoinNonce),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(<<"yolo_id">>),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    ?assertEqual(router_device:nwk_s_key(Device0), NwkSKey),
    ?assertEqual(router_device:app_s_key(Device0), AppSKey),
    ?assertEqual(router_device:join_nonce(Device0), JoinNonce),

    libp2p_swarm:stop(Swarm0),
    libp2p_swarm:stop(Swarm1),
    ok.

mqtt_test(Config) ->
    Self = self(),
    meck:new(emqtt, [passthrough]),
    meck:expect(emqtt, start_link, fun(_Opts) -> {ok, self()} end),
    meck:expect(emqtt, connect, fun(_Pid) -> {ok, []} end),
    meck:expect(emqtt, ping, fun(_Pid) -> ok end),
    meck:expect(emqtt, disconnect, fun(_Pid) -> ok end),
    meck:expect(
      emqtt,
      subscribe,
      fun(_Pid, {_Topic, _QoS}) ->
              ct:pal("emqtt:subscribe ~p~n", [{_Topic, _QoS}]),
              Self ! {mqtt_worker, self()},
              ok
      end
     ),
    meck:expect(
      emqtt,
      publish,
      fun(_Pid, _Topic, Payload, _QoS) ->
              Self ! {channel_data, Payload},
              ct:pal("emqtt:publish ~p~n", [{_Topic, Payload, _QoS}]),
              ok
      end
     ),
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, mqtt}),
    BaseDir = proplists:get_value(base_dir, Config),
    AppKey = proplists:get_value(app_key, Config),
    Swarm = test_utils:start_swarm(BaseDir, http_test_swarm, 3616),
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
    Stream ! {send, join_packet(PubKeyBin, AppKey, JoinNonce)},

    timer:sleep(?JOIN_DELAY),

    MQQTTWorkerPid = 
        receive
            {mqtt_worker, Pid} -> Pid
        after 250 ->
                ct:fail("mqtt_worker timeout")
        end,

    %% Waiting for console report status sent
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    %% Waiting for reply resp form router
    test_utils:wait_state_channel_message(250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(<<"yolo_id">>),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    %% Send CONFIRMED_UP frame packet needing an ack back
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 0,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_mqtt">>}),
    test_utils:wait_state_channel_message(?REPLY_DELAY + 250),

    %% Simulating the MQTT broker sending down a packet to transfer to device
    Payload = jsx:encode(#{<<"payload_raw">> => base64:encode(<<"mqttpayload">>)}),
    MQQTTWorkerPid ! {publish, #{payload => Payload}},
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 1,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"ack">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 1,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_mqtt">>}),
    Msg0 = {false, 1, <<"mqttpayload">>},
    {ok, _} = test_utils:wait_state_channel_message(Msg0, Device0, erlang:element(3, Msg0), ?UNCONFIRMED_DOWN, 0, 1, 1, 1),

    libp2p_swarm:stop(Swarm),
    ?assert(meck:validate(emqtt)),
    meck:unload(emqtt),
    ok.

aws_test(_Config) ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    UUID = list_to_binary(io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                                        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E])),
    DeviceID = <<"TEST_", UUID/binary>>,
    AWSArgs = #{aws_access_key => os:getenv("aws_access_key"),
                aws_secret_key => os:getenv("aws_secret_key"),
                aws_region => "us-west-1",
                topic => <<"helium">>},
    Channel = router_channel:new(<<"channel_id">>, router_aws_channel, <<"aws">>, AWSArgs, DeviceID, self()),
    {ok, DeviceWorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),
    timer:sleep(250),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Channel]),
    {ok, EventMgrRef} = router_channel:start_link(),
    _ = router_channel:add(EventMgrRef, Channel),
    timer:sleep(5000),
    gen_event:stop(EventMgrRef),
    gen_server:stop(DeviceWorkerPid),
    ok.

no_channel_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {no_channel, true}),
    BaseDir = proplists:get_value(base_dir, Config),
    AppKey = proplists:get_value(app_key, Config),
    Swarm = test_utils:start_swarm(BaseDir, no_channel_swarm, 3616),
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
    Stream ! {send, join_packet(PubKeyBin, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for console repor status sent
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    %% Waiting for reply resp form router
    test_utils:wait_state_channel_message(250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(<<"yolo_id">>),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),
    %% Send CONFIRMED_UP frame packet needing an ack back
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => <<"no channels configured">>,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"no_channel">>}),

    {ok, DeviceWorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    NoChannel = router_channel:new(<<"no_channel">>,
                                   router_no_channel,
                                   <<"no_channel">>,
                                   #{},
                                   <<"yolo_id">>,
                                   DeviceWorkerPid),
    NoChannelID = router_channel:id(NoChannel),
    ?assertMatch({state, _, _, _, _, _, _, #{NoChannelID := NoChannel}, _}, sys:get_state(DeviceWorkerPid)),

    ets:insert(Tab, {no_channel, false}),
    DeviceWorkerPid ! refresh_channels,

    State0 = sys:get_state(DeviceWorkerPid),
    ?assertMatch({state, _, _, _, _, _, _, #{<<"12345">> := _}, _}, State0),
    ?assertEqual(1, maps:size(erlang:element(8, State0))),

    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    test_utils:wait_channel_data(#{<<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => <<"yolo_id">>,
                                   <<"name">> => <<"yolo_name">>,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 1,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 1,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => '_',
                                            <<"channel_name">> => <<"fake_http">>}),
    test_utils:wait_state_channel_message(?REPLY_DELAY + 250),

    ets:insert(Tab, {no_channel, true}),
    DeviceWorkerPid ! refresh_channels,

    State1 = sys:get_state(DeviceWorkerPid),
    ?assertMatch({state, _, _, _, _, _, _, #{NoChannelID := NoChannel}, _}, State1),
    ?assertEqual(1, maps:size(erlang:element(8, State1))),

    libp2p_swarm:stop(Swarm),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

join_packet(PubKeyBin, AppKey, DevNonce) ->
    join_packet(PubKeyBin, AppKey, DevNonce, 0).

join_packet(PubKeyBin, AppKey, DevNonce, RSSI) ->
    MType = ?JOIN_REQ,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = lorawan_utils:reverse(?APPEUI),
    DevEUI = lorawan_utils:reverse(?DEVEUI),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:cmac(aes_cbc128, AppKey, Payload0, 4),
    Payload1 = <<Payload0/binary, MIC:4/binary>>,
    HeliumPacket = #packet_pb{
                      type=lorawan,
                      oui=2,
                      payload=Payload1,
                      signal_strength=RSSI,
                      frequency=923.3,
                      datarate= <<"SF8BW125">>
                     },
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket, hotspot=PubKeyBin},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt) ->
    frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt, #{}).

frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt, Options) ->
    MHDRRFU = 0,
    Major = 0,
    <<OUI:32/integer-unsigned-big, _DID:32/integer-unsigned-big>> = ?APPEUI,
    DevAddr = <<OUI:32/integer-unsigned-big>>,
    ADR = 0,
    ADRACKReq = 0,
    ACK = case maps:get(should_ack, Options, false) of
              true -> 1;
              false -> 0
          end,
    RFU = 0,
    FOptsBin = lorawan_mac_commands:encode_fupopts(maps:get(fopts, Options, [])),
    FOptsLen = byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = maps:get(body, Options, <<1:8>>),
    Data = lorawan_utils:reverse(lorawan_utils:cipher(Body, AppSessionKey, MType band 1, lorawan_utils:reverse(DevAddr), FCnt)),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
                 FOptsLen:4, FCnt:16/little-unsigned-integer, FOptsBin:FOptsLen/binary, Port:8/integer, Data/binary>>,
    B0 = b0(MType band 1, lorawan_utils:reverse(DevAddr), FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:cmac(aes_cbc128, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    Payload1 = <<Payload0/binary, MIC:4/binary>>,
    HeliumPacket = #packet_pb{
                      type=lorawan,
                      oui=2,
                      payload=Payload1,
                      frequency=923.3,
                      datarate= <<"SF8BW125">>
                     },
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket, hotspot=PubKeyBin},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (lorawan_utils:reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

