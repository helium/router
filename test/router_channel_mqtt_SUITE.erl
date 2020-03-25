-module(router_channel_mqtt_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([mqtt_test/1, mqtt_update_test/1]).

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
    [mqtt_test, mqtt_update_test].

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

mqtt_test(Config) ->
    ok = file:write_file("acl.conf", <<"{allow, all}.">>),
    application:set_env(emqx, acl_file, "acl.conf"),
    application:set_env(emqx, allow_anonymous, true),
    application:set_env(emqx, listeners, [{tcp, 1883, []}]),
    {ok, _} = application:ensure_all_started(emqx),

    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, mqtt}),
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

    MQTTChannel = ?CONSOLE_MQTT_CHANNEL(false),
    {ok, MQTTConn} = connect(kvc:path([<<"credentials">>, <<"endpoint">>], MQTTChannel), <<"mqtt_test">>, undefined),
    SubTopic = kvc:path([<<"credentials">>, <<"topic">>], MQTTChannel),
    {ok, _, _} = emqtt:subscribe(MQTTConn, <<SubTopic/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>, 0),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},

    timer:sleep(?JOIN_DELAY),

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
    receive
        {publish, #{payload := Payload0}=Data0} ->
            ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Data0]),
            self() ! {channel_data, Payload0}
    end,
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

    DownlinkPayload = <<"mqttpayload">>,
    emqtt:publish(MQTTConn, <<SubTopic/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/tx/channel">>,
                  jsx:encode(#{<<"payload_raw">> => base64:encode(DownlinkPayload)}), 0),


    Stream ! {send, test_utils:frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    receive
        {publish, #{payload := Payload1}=Data1} ->
            ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Data1]),
            self() ! {channel_data, Payload1}
    end,
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
    Msg0 = {false, 1, DownlinkPayload},
    {ok, _} = test_utils:wait_state_channel_message(Msg0, Device0, erlang:element(3, Msg0), ?UNCONFIRMED_DOWN, 0, 1, 1, 1),

    ok = emqtt:disconnect(MQTTConn),
    application:stop(emqx),
    ok.

mqtt_update_test(Config) ->
    ok = file:write_file("acl.conf", <<"{allow, all}.">>),
    application:set_env(emqx, acl_file, "acl.conf"),
    application:set_env(emqx, allow_anonymous, true),
    application:set_env(emqx, listeners, [{tcp, 1883, []}]),
    {ok, _} = application:ensure_all_started(emqx),

    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, mqtt}),
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

    MQTTChannel = ?CONSOLE_MQTT_CHANNEL(false),
    {ok, MQTTConn} = connect(kvc:path([<<"credentials">>, <<"endpoint">>], MQTTChannel), <<"mqtt_test">>, undefined),
    SubTopic0 = kvc:path([<<"credentials">>, <<"topic">>], MQTTChannel),
    {ok, _, _} = emqtt:subscribe(MQTTConn, <<SubTopic0/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>, 0),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},

    timer:sleep(?JOIN_DELAY),

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
    receive
        {publish, #{payload := Payload0, topic := <<SubTopic0:5/binary, _/binary>>}=Data0} ->
            ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Data0]),
            self() ! {channel_data, Payload0}
    after 1000 ->
            ct:fail("timeout Payload0")
    end,
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

    %% Switching topic channel should update but no restart
    Tab = proplists:get_value(ets, Config),
    SubTopic1 = <<"updated/">>,
    MQTTChannel0 = #{<<"type">> => <<"mqtt">>,
                     <<"credentials">> => #{<<"endpoint">> => <<"mqtt://127.0.0.1:1883">>,
                                            <<"topic">> => SubTopic1},
                     <<"show_dupes">> => false,
                     <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                     <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME},
    ets:insert(Tab, {channels, [MQTTChannel0]}),
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(WorkerID, #{}),
    {ok, _, _} = emqtt:unsubscribe(MQTTConn, <<SubTopic0/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>),
    {ok, _, _} = emqtt:subscribe(MQTTConn, <<SubTopic1/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>, 0),

    WorkerPid ! refresh_channels,
    timer:sleep(250),

    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => <<"Sending ACK and unconfirmed data in response to fcnt 0">>,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"ack">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),

    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    receive
        {publish, #{payload := Payload1, topic := <<SubTopic1:8/binary, _/binary>>}=Data1} ->
            ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Data1]),
            self() ! {channel_data, Payload1}
    after 1000 ->
            ct:fail("timeout Payload1")
    end,
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

    %% Switching endpoint channel should restart
    MQTTChannel1 = #{<<"type">> => <<"mqtt">>,
                     <<"credentials">> => #{<<"endpoint">> => <<"mqtt://localhost:1883">>,
                                            <<"topic">> => SubTopic0},
                     <<"show_dupes">> => false,
                     <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                     <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME},
    ets:insert(Tab, {channels, [MQTTChannel1]}),
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(WorkerID, #{}),
    {ok, _, _} = emqtt:unsubscribe(MQTTConn, <<SubTopic1/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>),
    {ok, _, _} = emqtt:subscribe(MQTTConn, <<SubTopic0/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>, 0),

    WorkerPid ! refresh_channels,
    timer:sleep(250),

    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => <<"Correcting channel mask in response to 1">>,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"down">>,
                                            <<"frame_up">> => 1,
                                            <<"frame_down">> => 2,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),

    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 2)},
    receive
        {publish, #{payload := Payload2, topic := <<SubTopic0:5/binary, _/binary>>}=Data2} ->
            ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Data2]),
            self() ! {channel_data, Payload2}
    after 1000 ->
            ct:fail("timeout Payload2")
    end,
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
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
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_MQTT_CHANNEL_NAME}),
    ok = emqtt:disconnect(MQTTConn),
    application:stop(emqx),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec connect(binary(), binary(), any()) -> {ok, pid()} | {error, term()}.
connect(URI, DeviceID, Name) ->
    Opts = [{scheme_defaults, [{mqtt, 1883}, {mqtts, 8883} | http_uri:scheme_defaults()]}, {fragment, false}],
    case http_uri:parse(URI, Opts) of
        {ok, {Scheme, UserInfo, Host, Port, _Path, _Query}} when Scheme == mqtt orelse
                                                                 Scheme == mqtts ->
            {Username, Password} = case binary:split(UserInfo, <<":">>) of
                                       [Un, <<>>] -> {Un, undefined};
                                       [Un, Pw] -> {Un, Pw};
                                       [<<>>] -> {undefined, undefined};
                                       [Un] -> {Un, undefined}
                                   end,
            EmqttOpts = [{host, erlang:binary_to_list(Host)},
                         {port, Port},
                         {clientid, DeviceID}] ++
                [{username, Username} || Username /= undefined] ++
                [{password, Password} || Password /= undefined] ++
                [{clean_start, false},
                 {keepalive, 30},
                 {ssl, Scheme == mqtts}],
            {ok, C} = emqtt:start_link(EmqttOpts),
            case emqtt:connect(C) of
                {ok, _Props} ->
                    lager:info("connect returned ~p", [_Props]),
                    {ok, C};
                {error, Reason} ->
                    lager:info("Failed to connect to ~p ~p : ~p", [Host, Port,
                                                                   Reason]),
                    {error, Reason}
            end;
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s ~p", [URI, Name]),
            {error, invalid_mqtt_uri}
    end.
