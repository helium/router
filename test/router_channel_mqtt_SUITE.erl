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
-define(MQTT_TIMEOUT, timer:seconds(2)).

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
    ok = file:write_file("acl.conf", <<"{allow, all}.">>),
    application:set_env(emqx, acl_file, "acl.conf"),
    application:set_env(emqx, allow_anonymous, true),
    application:set_env(emqx, listeners, [{tcp, 1883, []}]),
    {ok, _} = application:ensure_all_started(emqx),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    application:stop(emqx),
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

mqtt_test(Config) ->
    %% Set console to MQTT channel mode
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

    %% Connect and subscribe to MQTT Server
    MQTTChannel = ?CONSOLE_MQTT_CHANNEL,
    {ok, MQTTConn} = connect(kvc:path([<<"credentials">>, <<"endpoint">>], MQTTChannel), <<"mqtt_test">>, undefined),
    SubTopic = kvc:path([<<"credentials">>, <<"topic">>], MQTTChannel),
    {ok, _, _} = emqtt:subscribe(MQTTConn, <<SubTopic/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>, 0),

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

    %% We should receive the channel data via the MQTT server here
    receive
        {publish, #{payload := Payload0}} ->
            self() ! {channel_data, jsx:decode(Payload0, [return_maps])}
    after ?MQTT_TIMEOUT ->
            ct:fail("Payload0 timeout")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcount">> => 0,
                                   <<"timestamp">> => fun erlang:is_integer/1,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"timestamp">> => fun erlang:is_integer/1,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>}]}),

    %% Waiting for report channel status from MQTT channel
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"channel_id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"timestamp">> => fun erlang:is_integer/1,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>}]}),

    %% We ignore the channel correction messages
    ok = test_utils:ignore_messages(),

    %% Publish a downlink packet via MQTT server
    DownlinkPayload = <<"mqttpayload">>,
    emqtt:publish(MQTTConn, <<SubTopic/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/tx/channel">>,
                  jsx:encode(#{<<"payload_raw">> => base64:encode(DownlinkPayload)}), 0),

    %% Send UNCONFIRMED_UP frame packet
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},

    %% We should receive the channel data via the MQTT server here
    receive
        {publish, #{payload := Payload1}} ->
            self() ! {channel_data, jsx:decode(Payload1, [return_maps])}
    after ?MQTT_TIMEOUT ->
            ct:fail("Payload1 timeout")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcount">> => 1,
                                   <<"timestamp">> => fun erlang:is_integer/1,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"timestamp">> => fun erlang:is_integer/1,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>}]}),

    %% Waiting for report channel status from MQTT channel
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"channel_id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"timestamp">> => fun erlang:is_integer/1,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>}]}),

    %% Waiting for donwlink message on the hotspot
    Msg0 = {false, 1, DownlinkPayload},
    {ok, _} = test_utils:wait_state_channel_message(Msg0, Device0, erlang:element(3, Msg0), ?UNCONFIRMED_DOWN, 0, 0, 1, 1),

    %% We ignore the report status down
    ok = test_utils:ignore_messages(),

    ok = emqtt:disconnect(MQTTConn),
    ok.

mqtt_update_test(Config) ->
    %% Set console to MQTT channel mode
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

    %% Connect and subscribe to MQTT Server
    MQTTChannel = ?CONSOLE_MQTT_CHANNEL,
    {ok, MQTTConn} = connect(kvc:path([<<"credentials">>, <<"endpoint">>], MQTTChannel), <<"mqtt_test">>, undefined),
    SubTopic0 = kvc:path([<<"credentials">>, <<"topic">>], MQTTChannel),
    {ok, _, _} = emqtt:subscribe(MQTTConn, <<SubTopic0/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>, 0),

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

    %% We should receive the channel data via the MQTT server here
    receive
        {publish, #{payload := Payload0, topic := <<SubTopic0:5/binary, _/binary>>}} ->
            self() ! {channel_data, jsx:decode(Payload0, [return_maps])}
    after ?MQTT_TIMEOUT ->
            ct:fail("timeout Payload0")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcount">> => 0,
                                   <<"timestamp">> => fun erlang:is_integer/1,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"timestamp">> => fun erlang:is_integer/1,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>}]}),

    %% Waiting for report channel status from MQTT channel
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"channel_id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"timestamp">> => fun erlang:is_integer/1,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>}]}),

    %% We ignore the channel correction messages
    ok = test_utils:ignore_messages(),

    %% Switching topic channel should update but no restart
    Tab = proplists:get_value(ets, Config),
    SubTopic1 = <<"updated/">>,
    MQTTChannel0 = #{<<"type">> => <<"mqtt">>,
                     <<"credentials">> => #{<<"endpoint">> => <<"mqtt://127.0.0.1:1883">>,
                                            <<"topic">> => SubTopic1},
                     <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                     <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME},
    ets:insert(Tab, {channels, [MQTTChannel0]}),
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(WorkerID, #{}),
    {ok, _, _} = emqtt:unsubscribe(MQTTConn, <<SubTopic0/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>),
    {ok, _, _} = emqtt:subscribe(MQTTConn, <<SubTopic1/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>, 0),

    %% Force device_worker refresh channels
    WorkerPid ! refresh_channels,
    timer:sleep(250),

    %% Send UNCONFIRMED_UP frame packet
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},

    %% We should receive the channel data via the MQTT server here with NEW SUB TOPIC (SubTopic1)
    receive
        {publish, #{payload := Payload1, topic := <<SubTopic1:8/binary, _/binary>>}} ->
            self() ! {channel_data, jsx:decode(Payload1, [return_maps])}
    after ?MQTT_TIMEOUT ->
            ct:fail("timeout Payload1")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcount">> => 1,
                                   <<"timestamp">> => fun erlang:is_integer/1,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"timestamp">> => fun erlang:is_integer/1,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>}]}),

    %% Waiting for report channel status from MQTT channel
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"channel_id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"timestamp">> => fun erlang:is_integer/1,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>}]}),

    %% Ignore down messages updates
    ok = test_utils:ignore_messages(),

    %% Switching endpoint channel should restart (back to sub topic 0)
    MQTTChannel1 = #{<<"type">> => <<"mqtt">>,
                     <<"credentials">> => #{<<"endpoint">> => <<"mqtt://localhost:1883">>,
                                            <<"topic">> => SubTopic0},
                     <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                     <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME},
    ets:insert(Tab, {channels, [MQTTChannel1]}),
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(WorkerID, #{}),
    {ok, _, _} = emqtt:unsubscribe(MQTTConn, <<SubTopic1/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>),
    {ok, _, _} = emqtt:subscribe(MQTTConn, <<SubTopic0/binary, "helium/", ?CONSOLE_DEVICE_ID/binary, "/rx">>, 0),

    %% Force device_worker refresh channels
    WorkerPid ! refresh_channels,
    timer:sleep(250),

    %% Send UNCONFIRMED_UP frame packet
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 2)},

    %% We should receive the channel data via the MQTT server here with OLD SUB TOPIC (SubTopic0)
    receive
        {publish, #{payload := Payload2, topic := <<SubTopic0:5/binary, _/binary>>}} ->
            self() ! {channel_data, jsx:decode(Payload2, [return_maps])}
    after ?MQTT_TIMEOUT ->
            ct:fail("timeout Payload2")
    end,

    %% Waiting for data from MQTT channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"fcount">> => 2,
                                   <<"timestamp">> => fun erlang:is_integer/1,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"timestamp">> => fun erlang:is_integer/1,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>}]}),

    %% Waiting for report channel status from MQTT channel
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"channel_id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_MQTT_CHANNEL_NAME,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"hotspots">> => [#{<<"name">> => erlang:list_to_binary(HotspotName),
                                                                 <<"timestamp">> => fun erlang:is_integer/1,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>}]}),

    %% Ignore down messages updates
    ok = test_utils:ignore_messages(),

    ok = emqtt:disconnect(MQTTConn),
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
