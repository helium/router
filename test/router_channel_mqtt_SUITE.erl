-module(router_channel_mqtt_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([mqtt_test/1]).

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
    [mqtt_test].

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
    e2qc:teardown(console_cache),
    ok = application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

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
      fun(_Pid, _Props, _Topic, _QoS) ->
              ct:pal("emqtt:subscribe ~p~n", [{_Pid, _Props, _Topic, _QoS}]),
              Self ! {mqtt_worker, self()},
              {ok, _Props, undefined}
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
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},

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
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    %% Send CONFIRMED_UP frame packet needing an ack back
    Stream ! {send, test_utils:frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
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
                                            <<"channel_id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_MQTT_CHANNEL_NAME}),
    test_utils:wait_state_channel_message(?REPLY_DELAY + 250),

    %% Simulating the MQTT broker sending down a packet to transfer to device
    Payload = jsx:encode(#{<<"payload_raw">> => base64:encode(<<"mqttpayload">>)}),
    MQQTTWorkerPid ! {publish, #{payload => Payload, properties => #{channel_id => ?CONSOLE_MQTT_CHANNEL_ID}}},
    Stream ! {send, test_utils:frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
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
                                            <<"channel_id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_MQTT_CHANNEL_NAME}),
    Msg0 = {false, 1, <<"mqttpayload">>},
    {ok, _} = test_utils:wait_state_channel_message(Msg0, Device0, erlang:element(3, Msg0), ?UNCONFIRMED_DOWN, 0, 1, 1, 1),

    libp2p_swarm:stop(Swarm),
    ?assert(meck:validate(emqtt)),
    meck:unload(emqtt),
    ok.