-module(router_device_channels_worker_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([refresh_channels_test/1,
         crashing_channel_test/1,
         late_packet_test/1]).

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
-define(BACKOFF_MIN, timer:seconds(15)).
-define(BACKOFF_MAX, timer:minutes(5)).
-define(BACKOFF_INIT,
        {backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
         erlang:make_ref()}).

-record(state, {chain=blockchain:blockchain(),
                event_mgr :: pid(),
                device_worker :: pid(),
                device :: router_device:device(),
                channels = #{} :: map(),
                channels_backoffs = #{} :: map(),
                data_cache = #{} :: map(),
                balance_cache = #{} :: map(),
                fcnt :: integer(),
                channels_resp_cache = #{} :: map()}).

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
    [refresh_channels_test,
     crashing_channel_test,
     late_packet_test].

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

refresh_channels_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {no_channel, true}),

    %% Starting worker with no channels
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, DeviceWorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),
    DeviceChannelsWorkerPid = test_utils:get_device_channels_worker(DeviceID),

    %% Waiting for worker to init properly
    timer:sleep(250),

    %% Checking worker's channels, should only be "no_channel"
    State0 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"no_channel">> => router_channel:new(<<"no_channel">>,
                                                          router_no_channel,
                                                          <<"no_channel">>,
                                                          #{},
                                                          DeviceID,
                                                          DeviceChannelsWorkerPid)},
                 State0#state.channels),

    %% Add 2 http channels and force a refresh
    HTTPChannel1 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://127.0.0.1:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"downlink_url">> => <<>>,
                     <<"id">> => <<"HTTP_1">>,
                     <<"name">> => <<"HTTP_NAME_1">>},
    HTTPChannel2 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://127.0.0.1:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"downlink_url">> => <<>>,
                     <<"id">> => <<"HTTP_2">>,
                     <<"name">> => <<"HTTP_NAME_2">>},
    ets:insert(Tab, {no_channel, false}),
    ets:insert(Tab, {channels, [HTTPChannel1, HTTPChannel2]}),
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),
    State1 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State1#state.device, DeviceChannelsWorkerPid, HTTPChannel1),
                   <<"HTTP_2">> => convert_channel(State1#state.device, DeviceChannelsWorkerPid, HTTPChannel2)},
                 State1#state.channels),

    %% Modify HTTP Channel 2
    HTTPChannel2_1 = #{<<"type">> => <<"http">>,
                       <<"credentials">> => #{<<"headers">> => #{},
                                              <<"endpoint">> => <<"http://127.0.0.1:3000/channel">>,
                                              <<"method">> => <<"PUT">>},
                       <<"id">> => <<"HTTP_2">>,
                       <<"name">> => <<"HTTP_NAME_2">>},
    ets:insert(Tab, {channels, [HTTPChannel1, HTTPChannel2_1]}),
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),
    State2 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(2, maps:size(State2#state.channels)),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State2#state.device, DeviceChannelsWorkerPid, HTTPChannel1),
                   <<"HTTP_2">> => convert_channel(State2#state.device, DeviceChannelsWorkerPid, HTTPChannel2_1)},
                 State2#state.channels),

    %% Remove HTTP Channel 1 and update 2 back to normal
    ets:insert(Tab, {channels, [HTTPChannel2]}),
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),
    State3 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_2">> => convert_channel(State3#state.device, DeviceChannelsWorkerPid, HTTPChannel2)},
                 State3#state.channels),

    gen_server:stop(DeviceWorkerPid),
    ok.

crashing_channel_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    HTTPChannel1 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://127.0.0.1:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"id">> => <<"HTTP_1">>,
                     <<"name">> => <<"HTTP_NAME_1">>},
    ets:insert(Tab, {no_channel, false}),
    ets:insert(Tab, {channels, [HTTPChannel1]}),

    meck:new(router_http_channel, [passthrough]),
    meck:expect(router_http_channel, handle_info, fun(Msg, _State) -> erlang:throw(Msg) end),

    %% Starting worker with 1 HTTP channel
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, DeviceWorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),
    DeviceChannelsWorkerPid = test_utils:get_device_channels_worker(DeviceID),

    %% Waiting for worker to init properly
    timer:sleep(250),

    %% Check that HTTP 1 is in there
    State0 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State0#state.device, DeviceChannelsWorkerPid, HTTPChannel1)},
                 State0#state.channels),
    {Backoff0, _} = maps:get(<<"HTTP_1">>, State0#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff0)),

    %% Crash channel
    EvtMgr = State0#state.event_mgr,
    ?assert(erlang:is_pid(EvtMgr)),
    EvtMgr ! crash_http_channel,
    timer:sleep(250),

    %% Check that HTTP 1 go restarted after crash
    State1 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State1#state.device, DeviceChannelsWorkerPid, HTTPChannel1)},
                 State1#state.channels),
    {Backoff1, _} = maps:get(<<"HTTP_1">>, State1#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff1)),

    test_utils:wait_report_channel_status(#{<<"category">> => <<"channel_crash">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => DeviceID,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => fun erlang:is_integer/1,
                                            <<"port">> => '_',
                                            <<"devaddr">> => '_',
                                            <<"dc">> => fun erlang:is_map/1,
                                            <<"hotspots">> => [],
                                            <<"channels">> => [#{<<"id">> => <<"HTTP_1">>,
                                                                 <<"name">> => <<"HTTP_NAME_1">>,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"error">>,
                                                                 <<"description">> => '_'}]}),

    %% Crash channel and crash on init
    meck:expect(router_http_channel, init, fun(_Args) -> {error, init_failed} end),
    timer:sleep(10),
    EvtMgr ! crash_http_channel,
    timer:sleep(250),

    %% Check that HTTP 1 is gone and that backoff increased
    State2 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{}, State2#state.channels),
    {Backoff2, _} = maps:get(<<"HTTP_1">>, State2#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN * 2, backoff:get(Backoff2)),
    test_utils:wait_report_channel_status(#{<<"category">> => <<"channel_crash">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => DeviceID,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => fun erlang:is_integer/1,
                                            <<"port">> => '_',
                                            <<"devaddr">> => '_',
                                            <<"dc">> => fun erlang:is_map/1,
                                            <<"hotspots">> => [],
                                            <<"channels">> => [#{<<"id">> => <<"HTTP_1">>,
                                                                 <<"name">> => <<"HTTP_NAME_1">>,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"error">>,
                                                                 <<"description">> => '_'}]}),
    test_utils:wait_report_channel_status(#{<<"category">> => <<"channel_start_error">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => DeviceID,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => fun erlang:is_integer/1,
                                            <<"port">> => '_',
                                            <<"devaddr">> => '_',
                                            <<"dc">> => fun erlang:is_map/1,
                                            <<"hotspots">> => [],
                                            <<"channels">> => [#{<<"id">> => <<"HTTP_1">>,
                                                                 <<"name">> => <<"HTTP_NAME_1">>,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"error">>,
                                                                 <<"description">> => '_'}]}),

    %% Fix crash and wait for HTTP channel to come back
    meck:unload(router_http_channel),
    timer:sleep(?BACKOFF_MIN * 2 + 250),
    State3 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State3#state.device, DeviceChannelsWorkerPid, HTTPChannel1)},
                 State1#state.channels),
    {Backoff3, _} = maps:get(<<"HTTP_1">>, State3#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff3)),

    gen_server:stop(DeviceWorkerPid),
    ok.

late_packet_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    RouterSwarm = blockchain_swarm:swarm(),
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
    Stream ! {send, test_utils:join_packet(PubKeyBin1, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for report device status on that join request
    test_utils:wait_report_device_status(#{<<"category">> => <<"activation">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"payload_size">> => fun erlang:is_integer/1,
                                           <<"port">> => '_',
                                           <<"devaddr">> => '_',
                                           <<"dc">> => fun erlang:is_map/1,
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName1),
                                                                <<"reported_at">> => fun erlang:is_integer/1,
                                                                <<"status">> => <<"success">>,
                                                                <<"selected">> => true,
                                                                <<"rssi">> => 0.0,
                                                                <<"snr">> => 0.0,
                                                                <<"spreading">> => <<"SF8BW125">>,
                                                                <<"frequency">> => fun erlang:is_float/1,
                                                                <<"channel">> => fun erlang:is_number/1,
                                                                <<"lat">> => fun erlang:is_float/1, 
                                                                <<"long">> => fun erlang:is_float/1}],
                                           <<"channels">> => []}),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Simulate multiple hotspot sending data, 2 will be late and should not be sent
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin1, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    {ok, HotspotName2} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin2)),
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},

    erlang:spawn_link(
      fun() ->
              timer:sleep(1050),
              #{public := PubKey3} = libp2p_crypto:generate_keys(ecc_compact),
              PubKeyBin3 = libp2p_crypto:pubkey_to_bin(PubKey3),
              Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin3, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)}
      end),

    erlang:spawn_link(
      fun() ->
              timer:sleep(timer:seconds(3)),
              #{public := PubKey4} = libp2p_crypto:generate_keys(ecc_compact),
              PubKeyBin4 = libp2p_crypto:pubkey_to_bin(PubKey4),
              Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin4, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)}
      end),

    %% Waiting for data from HTTP channel with 2 hotspots
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"downlink_url">> => fun erlang:is_binary/1,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS, <<"organization_id">> => ?CONSOLE_ORG_ID},
                                   <<"fcnt">> => 0,
                                   <<"reported_at">> => fun erlang:is_integer/1,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"devaddr">> => '_',
                                   <<"dc">> => fun erlang:is_map/1,
                                   <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName1),
                                                        <<"reported_at">> => fun erlang:is_integer/1,
                                                        <<"status">> => <<"success">>,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>,
                                                        <<"frequency">> => fun erlang:is_float/1,
                                                        <<"channel">> => fun erlang:is_number/1,
                                                        <<"lat">> => fun erlang:is_float/1, 
                                                        <<"long">> => fun erlang:is_float/1},
                                                      #{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin2)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName2),
                                                        <<"reported_at">> => fun erlang:is_integer/1,
                                                        <<"status">> => <<"success">>,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>,
                                                        <<"frequency">> => fun erlang:is_float/1,
                                                        <<"channel">> => fun erlang:is_number/1,
                                                        <<"lat">> => <<"unknown">>, 
                                                        <<"long">> => <<"unknown">>}]}),

    %% Waiting for report channel status from HTTP channel
    test_utils:wait_report_channel_status(#{<<"category">> => <<"up">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => ?CONSOLE_DEVICE_ID,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload_size">> => fun erlang:is_integer/1,
                                            <<"port">> => '_',
                                            <<"devaddr">> => '_',
                                            <<"dc">> => fun erlang:is_map/1,
                                            <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                                                                 <<"name">> => erlang:list_to_binary(HotspotName1),
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>,
                                                                 <<"frequency">> => fun erlang:is_float/1,
                                                                 <<"channel">> => fun erlang:is_number/1,
                                                                 <<"lat">> => fun erlang:is_float/1, 
                                                                 <<"long">> => fun erlang:is_float/1},
                                                               #{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin2)),
                                                                 <<"name">> => erlang:list_to_binary(HotspotName2),
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"rssi">> => 0.0,
                                                                 <<"snr">> => 0.0,
                                                                 <<"spreading">> => <<"SF8BW125">>,
                                                                 <<"frequency">> => fun erlang:is_float/1,
                                                                 <<"channel">> => fun erlang:is_number/1,
                                                                 <<"lat">> => <<"unknown">>, 
                                                                 <<"long">> => <<"unknown">>}],
                                            <<"channels">> => [#{<<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                                                 <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"success">>,
                                                                 <<"description">> => '_'}]}),

    %% Make sure we did not get a duplicate with that late message
    receive
        {report_channel_status, Got} ->
            ct:fail("wait_report_channel_status failed we got ~p", [Got]);
        {channel_data, Got} ->
            ct:fail("wait_channel_data failed we got ~p", [Got])
    after 10000 ->
            ok
    end,
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
-spec convert_channel(router_device:device(), pid(), map()) -> false | router_channel:channel().
convert_channel(Device, Pid, #{<<"type">> := <<"http">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_http_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{url =>  kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             headers => maps:to_list(kvc:path([<<"credentials">>, <<"headers">>], JSONChannel)),
             method => list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], JSONChannel))),
             downlink_token => to_bin(kvc:path([<<"downlink_token">>], JSONChannel))},
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder),
    Channel;
convert_channel(Device, Pid, #{<<"type">> := <<"mqtt">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_mqtt_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{endpoint => kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             uplink_topic => kvc:path([<<"credentials">>, <<"uplink">>, <<"topic">>], JSONChannel),
             downlink_topic => kvc:path([<<"credentials">>, <<"downlink">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder),
    Channel;
convert_channel(Device, Pid, #{<<"type">> := <<"aws">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_aws_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{aws_access_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_access_key">>], JSONChannel)),
             aws_secret_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_secret_key">>], JSONChannel)),
             aws_region => binary_to_list(kvc:path([<<"credentials">>, <<"aws_region">>], JSONChannel)),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder),
    Channel;
convert_channel(Device, Pid, #{<<"type">> := <<"console">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_console_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, #{}, DeviceID, Pid, Decoder),
    Channel;
convert_channel(_Device, _Pid, _Channel) ->
    false.

-spec convert_decoder(map()) -> undefined | router_decoder:decoder().
convert_decoder(JSONChannel) ->
    case kvc:path([<<"function">>], JSONChannel, undefined) of
        undefined ->
            undefined;
        JSONDecoder ->
            case kvc:path([<<"active">>], JSONDecoder, false) of
                false ->
                    undefined;
                true ->
                    case kvc:path([<<"format">>], JSONDecoder, undefined) of
                        <<"custom">> ->
                            router_decoder:new(kvc:path([<<"id">>], JSONDecoder),
                                               custom,
                                               #{function => kvc:path([<<"body">>], JSONDecoder)});
                        <<"cayenne">> ->
                            router_decoder:new(kvc:path([<<"id">>], JSONDecoder), cayenne, #{});
                        <<"browan_object_locator">> ->
                            router_decoder:new(kvc:path([<<"id">>], JSONDecoder), browan_object_locator, #{});
                        _ ->
                            undefined
                    end
            end
    end.

to_bin(Bin) when is_binary(Bin) ->
    Bin;
to_bin(List) when is_list(List) ->
    erlang:list_to_binary(List).
