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
         aws_test/1
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
     mqtt_test
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
    Swarm = start_swarm(BaseDir, http_test_swarm, 3616),
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
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), 0)},
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
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), 1)},
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
                                            <<"channel_name">> => <<"fake_http">>}),
    {ok, _} = test_utils:wait_state_channel_message(Msg, Device0, erlang:element(3, Msg), ?UNCONFIRMED_DOWN, 0, 0, 1, 1),

    {ok, Device2} = router_device:get(DB, CF, WorkerID),
    ?assertEqual([], router_device:queue(Device2)),

    libp2p_swarm:stop(Swarm),
    ok.

dupes_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    AppKey = proplists:get_value(app_key, Config),
    ets:insert(Tab, {show_dupes, true}),
    BaseDir = proplists:get_value(base_dir, Config),
    Swarm = start_swarm(BaseDir, dupes_test_swarm, 3617),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(Swarm,
                                                   Address,
                                                   router_handler_test:version(),
                                                   router_handler_test,
                                                   [self()]),
    PubKeyBin1 = libp2p_swarm:pubkey_bin(Swarm),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, join_packet(PubKeyBin1, AppKey, JoinNonce)},

    timer:sleep(?JOIN_DELAY),

    %% Waiting for console repor status sent
    ok = wait_for_report_status(PubKeyBin1),

    %% Waiting for reply resp form router
    ok = wait_for_reply(),

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
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin1, router_device:nwk_s_key(Device0), 0)},
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey),
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), 0)},
    ok = wait_for_post_channel(PubKeyBin1),
    ok = wait_for_report_status(PubKeyBin1),
    ok = wait_for_post_channel(PubKeyBin2),
    ok = wait_for_report_status(PubKeyBin2),
    {ok, Reply1} = wait_for_reply(Msg0, Device0, erlang:element(3, Msg0), ?UNCONFIRMED_DOWN, 1, 0, 1, 0),
    ct:pal("Reply ~p", [Reply1]),
    true = lists:keymember(link_adr_req, 1, Reply1#frame.fopts),

    %% Make sure we did not get a duplicate
    receive
        {client_data, _, _Data2} ->
            ct:fail("double_reply ~p", [blockchain_state_channel_v1_pb:decode_msg(_Data2, blockchain_state_channel_message_v1_pb)])
    after 0 ->
            ok
    end,

    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), 1)},
    ok = wait_for_post_channel(PubKeyBin2),
    ok = wait_for_report_status(PubKeyBin2),
    {ok, Reply2} = wait_for_reply(Msg1, Device0, erlang:element(3, Msg1), ?CONFIRMED_DOWN, 0, 1, 2, 1),

    %% check we're still getting ADR commands
    true = lists:keymember(link_adr_req, 1, Reply2#frame.fopts),

    %% check we get the second downlink again because we didn't ACK it
    %% also ack the ADR adjustments
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), 2, #{fopts => [{link_adr_ans, 1, 1, 1}]})},
    ok = wait_for_post_channel(PubKeyBin2),
    ok = wait_for_report_status(PubKeyBin2),
    {ok, Reply3} = wait_for_reply(Msg1, Device0, erlang:element(3, Msg1), ?CONFIRMED_DOWN, 0, 0, 2, 1),

    %% check NOT we're still getting ADR commands
    false = lists:keymember(link_adr_req, 1, Reply3#frame.fopts),

    %% ack the packet, we don't expect a reply here
    Stream ! {send, frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), 2, #{should_ack => true})},
    ok = wait_for_post_channel(PubKeyBin2),
    ok = wait_for_report_status(PubKeyBin2),
    timer:sleep(1000),
    receive
        {client_data, _,  _Data3} ->
            ct:fail("unexpected_reply ~p", [blockchain_state_channel_v1_pb:decode_msg(_Data3, blockchain_state_channel_message_v1_pb)])
    after 0 ->
            ok
    end,

    %% send a confimed up to provoke a 'bare ack'
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), 3)},
    ok = wait_for_post_channel(PubKeyBin2),
    ok = wait_for_report_status(PubKeyBin2),
    {ok, Reply4} = wait_for_reply(Msg1, Device0, <<>>, ?UNCONFIRMED_DOWN, 0, 1, undefined, 2),

    %% check NOT we're still getting ADR commands
    false = lists:keymember(link_adr_req, 1, Reply4#frame.fopts),

    libp2p_swarm:stop(Swarm),
    ok.

join_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    Swarm0 = start_swarm(BaseDir, join_test_swarm_0, 3620),
    Swarm1 = start_swarm(BaseDir, join_test_swarm_1, 3621),
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

    %% Waiting for console repor status sent
    ok = wait_for_report_status(PubKeyBin1, <<"success">>),

    %% Waiting for reply resp form router
    {_NetID, _DevAddr, _DLSettings, _RxDelay, NwkSKey, AppSKey} = wait_for_join_resp(PubKeyBin1, AppKey, JoinNonce),

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
    Swarm = start_swarm(BaseDir, http_test_swarm, 3616),
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
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), 0)},
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
                                            <<"channel_name">> => <<"fake_mqtt">>}),
    test_utils:wait_state_channel_message(?REPLY_DELAY + 250),

    %% Simulating the MQTT broker sending down a packet to transfer to device
    Payload = jsx:encode(#{<<"payload_raw">> => base64:encode(<<"mqttpayload">>)}),
    MQQTTWorkerPid ! {publish, #{payload => Payload}},
    Stream ! {send, frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), 1)},
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


%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

wait_for_report_status(PubKeyBin) ->
    wait_for_report_status(PubKeyBin, <<"success">>).

wait_for_report_status(PubKeyBin, Status) ->
    try
        {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
        BinName = erlang:list_to_binary(AName),
        receive
            {report_status, Body} ->
                Map = jsx:decode(Body, [return_maps]),
                case Map of
                    #{<<"status">> := Status,
                      <<"hotspot_name">> := BinName} ->
                        ok;
                    _ ->
                        wait_for_report_status(PubKeyBin),
                        self()  ! {report_status, Body},
                        ok
                end
        after 250 ->
                ct:fail("report_status timeout")
        end
    catch
        _Class:_Reason:Stacktrace ->
            ct:pal("report_status stacktrace ~p~n", [Stacktrace])
    end.

wait_for_post_channel(PubKeyBin) ->
    try
        {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
        BinName = erlang:list_to_binary(AName),
        receive
            {channel, Data} ->
                Map = jsx:decode(Data, [return_maps]),
                AppEUI = lorawan_utils:binary_to_hex(?APPEUI),
                DevEUI = lorawan_utils:binary_to_hex(?DEVEUI),
                ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Map]),
                #{
                  <<"app_eui">> := AppEUI,
                  <<"dev_eui">> := DevEUI,
                  <<"payload">> := <<>>,
                  <<"spreading">> := <<"SF8BW125">>,
                  <<"hotspot_name">> := BinName
                 } = Map,
                ok
        after 250 ->
                ct:fail("wait_for_post_channel timeout")
        end
    catch
        _Class:_Reason:Stacktrace ->
            ct:pal("wait_for_post_channel stacktrace ~p~n", [Stacktrace])
    end.

wait_for_reply() ->
    receive
        {client_data, undefined, Data} ->
            try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                    #blockchain_state_channel_response_v1_pb{accepted=true} = Resp,
                    ok;
                _Else ->
                    ct:fail("wrong reply message ~p ", [_Else])
            catch
                _E:_R ->
                    ct:fail("failed to decode reply ~p ~p", [Data, {_E, _R}])
            end
    after 250 ->
            ct:fail("reply timeout")
    end.

wait_for_reply(Msg, Device, FrameData, Type, FPending, Ack, Fport, FCnt) ->
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, {Msg, Device, Type, FPending, Ack, Fport, FCnt}]),
    receive
        {client_data, undefined, Data} ->
            try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                    #blockchain_state_channel_response_v1_pb{accepted=true, downlink=Packet} = Resp,
                    ct:pal("packet ~p", [Packet]),
                    Frame = deframe_packet(Packet, router_device:app_s_key(Device)),
                    ct:pal("~p", [lager:pr(Frame, ?MODULE)]),
                    ?assertEqual(FrameData, Frame#frame.data),
                    %% we queued an unconfirmed packet
                    ?assertEqual(Type, Frame#frame.mtype),
                    ?assertEqual(FPending, Frame#frame.fpending),
                    ?assertEqual(Ack, Frame#frame.ack),
                    ?assertEqual(Fport, Frame#frame.fport),
                    ?assertEqual(FCnt, Frame#frame.fcnt),
                    {ok, Frame}
            catch _:_ ->
                    ct:fail("invalid client data for ~p", [Msg])
            end
    after 1000 ->
            ct:fail("missing_reply for ~p", [Msg])
    end.

wait_for_join_resp(PubKeyBin, AppKey, JoinNonce) ->
    receive
        {client_data, PubKeyBin, Data} ->
            try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                    #blockchain_state_channel_response_v1_pb{accepted=true, downlink=Packet} = Resp,
                    ct:pal("packet ~p", [Packet]),
                    Frame = deframe_join_packet(Packet, JoinNonce, AppKey),
                    ct:pal("Join response ~p", [Frame]),
                    Frame
            catch _:_ ->
                    ct:fail("invalid join response")
            end
    after 1000 ->
            ct:fail("missing_join for")
    end.

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

frame_packet(MType, PubKeyBin, SessionKey, FCnt) ->
    frame_packet(MType, PubKeyBin, SessionKey, FCnt, #{}).

frame_packet(MType, PubKeyBin, SessionKey, FCnt, Options) ->
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
    Body = maps:get(body, Options, <<1:8>>),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
                 FOptsLen:4, FCnt:16/little-unsigned-integer, FOptsBin:FOptsLen/binary, Body/binary>>,
    B0 = b0(MType band 1, lorawan_utils:reverse(DevAddr), FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:cmac(aes_cbc128, SessionKey, <<B0/binary, Payload0/binary>>, 4),
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

deframe_join_packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, EncPayload/binary>>}, DevNonce, AppKey) when MType == ?JOIN_ACCEPT ->
    ct:pal("Enc join ~w", [EncPayload]),
    <<AppNonce:3/binary, NetID:3/binary, DevAddr:4/binary, DLSettings:8/integer-unsigned, RxDelay:8/integer-unsigned, MIC:4/binary>> = Payload = crypto:block_encrypt(aes_ecb, AppKey, EncPayload),
    ct:pal("Dec join ~w", [Payload]),
                                                %{?APPEUI, ?DEVEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload)-4}),
    MIC = crypto:cmac(aes_cbc128, AppKey, <<MType:3, _MHDRRFU:3, _Major:2, Msg/binary>>, 4),
    NetID = <<"He2">>,
    NwkSKey = crypto:block_encrypt(aes_ecb,
                                   AppKey,
                                   lorawan_utils:padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    AppSKey = crypto:block_encrypt(aes_ecb,
                                   AppKey,
                                   lorawan_utils:padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    {NetID, DevAddr, DLSettings, RxDelay, NwkSKey, AppSKey}.

deframe_packet(Packet, SessionKey) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddrReversed:4/binary, ADR:1, RFU:1, ACK:1, FPending:1,
      FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Packet#packet_pb.payload,
    DevAddr = lorawan_utils:reverse(DevAddrReversed),
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    Data = lorawan_utils:reverse(lorawan_utils:cipher(FRMPayload, SessionKey, MType band 1, DevAddr, FCnt)),
    ct:pal("FOpts ~p", [FOpts]),
    #frame{mtype=MType, devaddr=DevAddr, adr=ADR, rfu=RFU, ack=ACK, fpending=FPending,
           fcnt=FCnt, fopts=lorawan_mac_commands:parse_fdownopts(FOpts), fport=FPort, data=Data}.

b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (lorawan_utils:reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

start_swarm(BaseDir, Name, Port) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)},
    SwarmOpts = [
                 {base_dir, BaseDir ++ "/" ++ erlang:atom_to_list(Name) ++ "_data"},
                 {key, Key},
                 {libp2p_group_gossip, [{seed_nodes, []}]},
                 {libp2p_nat, [{enabled, false}]},
                 {libp2p_proxy, [{limit, 1}]}
                ],
    {ok, Swarm} = libp2p_swarm:start(Name, SwarmOpts),
    libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/" ++  erlang:integer_to_list(Port)),
    ct:pal("created swarm ~p @ ~p p2p address=~p", [Name, Swarm, libp2p_swarm:p2p_address(Swarm)]),
    Swarm.
