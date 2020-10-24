-module(router_decoder_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([decode_test/1,
         template_test/1,
         timeout_test/1,
         too_many_test/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("utils/console_test.hrl").
-include("lorawan_vars.hrl").

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
    [decode_test, template_test, timeout_test, too_many_test].

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

decode_test(Config) ->
    %% Set console to decoder channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, decoder}),

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
                                           <<"payload_size">> => fun erlang:is_integer/1,
                                           <<"port">> => '_',
                                           <<"devaddr">> => '_',
                                           <<"dc">> => fun erlang:is_map/1,
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName),
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

    %% Send UNCONFIRMED_UP frame packet 20 02 F8 00 => #{<<"vSys">> => -0.5}
    EncodedPayload = to_real_payload(<<"20 02 F8 00">>),
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0),
                                            router_device:app_s_key(Device0), 0, #{body => <<1:8, EncodedPayload/binary>>})},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"downlink_url">> => fun erlang:is_binary/1,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS, <<"organization_id">> => ?CONSOLE_ORG_ID},
                                   <<"fcnt">> => 0,
                                   <<"reported_at">> => fun erlang:is_integer/1,
                                   <<"payload">> => fun erlang:is_binary/1,
                                   <<"decoded">> => #{<<"status">> => <<"success">>,
                                                      <<"payload">> => #{<<"vSys">> => -0.5}},
                                   <<"port">> => 1,
                                   <<"devaddr">> => '_',
                                   <<"dc">> => fun erlang:is_map/1,
                                   <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"reported_at">> => fun erlang:is_integer/1,
                                                        <<"status">> => <<"success">>,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>,
                                                        <<"frequency">> => fun erlang:is_float/1,
                                                        <<"channel">> => fun erlang:is_number/1,
                                                        <<"lat">> => fun erlang:is_float/1, 
                                                        <<"long">> => fun erlang:is_float/1}]}),
    ok.

template_test(Config) ->
    %% Set console to decoder channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, template}),

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
                                           <<"payload_size">> => fun erlang:is_integer/1,
                                           <<"port">> => '_',
                                           <<"devaddr">> => '_',
                                           <<"dc">> => fun erlang:is_map/1,
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName),
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

    EncodedPayload = base64:decode(<<"CP4+AAAAAAAAAAA=">>),
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0),
                                            router_device:app_s_key(Device0), 0, #{body => <<136:8, EncodedPayload/binary>>})},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"battery">> => 100.0, <<"lat">> => 0.0,<<"long">> => 0.0}),
    ok.

timeout_test(Config) ->
    %% Set console to decoder channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, decoder}),

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
                                           <<"payload_size">> => fun erlang:is_integer/1,
                                           <<"port">> => '_',
                                           <<"devaddr">> => '_',
                                           <<"dc">> => fun erlang:is_map/1,
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName),
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

    %% Send UNCONFIRMED_UP frame packet 20 02 F8 00 => #{<<"vSys">> => -0.5}
    EncodedPayload = to_real_payload(<<"20 02 F8 00">>),
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0),
                                            router_device:app_s_key(Device0), 0, #{body => <<1:8, EncodedPayload/binary>>})},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"downlink_url">> => fun erlang:is_binary/1,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS, <<"organization_id">> => ?CONSOLE_ORG_ID},
                                   <<"fcnt">> => 0,
                                   <<"reported_at">> => fun erlang:is_integer/1,
                                   <<"payload">> => fun erlang:is_binary/1,
                                   <<"decoded">> => #{<<"status">> => <<"success">>,
                                                      <<"payload">> => #{<<"vSys">> => -0.5}},
                                   <<"port">> => 1,
                                   <<"devaddr">> => '_',
                                   <<"dc">> => fun erlang:is_map/1,
                                   <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"reported_at">> => fun erlang:is_integer/1,
                                                        <<"status">> => <<"success">>,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>,
                                                        <<"frequency">> => fun erlang:is_float/1,
                                                        <<"channel">> => fun erlang:is_number/1,
                                                        <<"lat">> => fun erlang:is_float/1, 
                                                        <<"long">> => fun erlang:is_float/1}]}),

    DecoderID = maps:get(<<"id">>, ?CONSOLE_DECODER),
    [{DecoderID, {custom_decoder, DecoderID, _Hash, _Fun, DecoderPid, _LastUsed}}] = ets:lookup(router_decoder_custom_sup_ets, DecoderID),

    DecoderPid ! timeout,
    timer:sleep(1000),

    ?assertNot(erlang:is_process_alive(DecoderPid)),
    ?assertEqual([], ets:lookup(router_decoder_custom_sup_ets, DecoderID)),
    ok.

too_many_test(Config) ->
    %% Set console to decoder channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, decoder}),

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
                                           <<"payload_size">> => fun erlang:is_integer/1,
                                           <<"port">> => '_',
                                           <<"devaddr">> => '_',
                                           <<"dc">> => fun erlang:is_map/1,
                                           <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                                <<"name">> => erlang:list_to_binary(HotspotName),
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

    %% Send UNCONFIRMED_UP frame packet 20 02 F8 00 => #{<<"vSys">> => -0.5}
    EncodedPayload = to_real_payload(<<"20 02 F8 00">>),
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0),
                                            router_device:app_s_key(Device0), 0, #{body => <<1:8, EncodedPayload/binary>>})},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"downlink_url">> => fun erlang:is_binary/1,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS, <<"organization_id">> => ?CONSOLE_ORG_ID},
                                   <<"fcnt">> => 0,
                                   <<"reported_at">> => fun erlang:is_integer/1,
                                   <<"payload">> => fun erlang:is_binary/1,
                                   <<"decoded">> => #{<<"status">> => <<"success">>,
                                                      <<"payload">> => #{<<"vSys">> => -0.5}},
                                   <<"port">> => 1,
                                   <<"devaddr">> => '_',
                                   <<"dc">> => fun erlang:is_map/1,
                                   <<"hotspots">> => [#{<<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                                                        <<"name">> => erlang:list_to_binary(HotspotName),
                                                        <<"reported_at">> => fun erlang:is_integer/1,
                                                        <<"status">> => <<"success">>,
                                                        <<"rssi">> => 0.0,
                                                        <<"snr">> => 0.0,
                                                        <<"spreading">> => <<"SF8BW125">>,
                                                        <<"frequency">> => fun erlang:is_float/1,
                                                        <<"channel">> => fun erlang:is_number/1,
                                                        <<"lat">> => fun erlang:is_float/1, 
                                                        <<"long">> => fun erlang:is_float/1}]}),

    DecoderID = maps:get(<<"id">>, ?CONSOLE_DECODER),
    [{DecoderID, {custom_decoder, DecoderID, _Hash, _Fun, DecoderPid, _LastUsed}}] = ets:lookup(router_decoder_custom_sup_ets, DecoderID),

    NewDecoder = router_decoder:new(<<"new-decoder">>, custom, #{function => <<"function Decoder(bytes, port) {return 'ok'}">>}),
    ok = router_decoder:add(NewDecoder),

    ?assertNot(erlang:is_process_alive(DecoderPid)),

    NewDecoderID = router_decoder:id(NewDecoder),
    [{NewDecoderID, _}] = ets:lookup(router_decoder_custom_sup_ets, NewDecoderID),
    %% decoder gets auto restarted if removed
    ?assertEqual({ok, undefined}, router_decoder:decode(DecoderID, <<>>, 1)),
    ?assertEqual({ok, <<"ok">>}, router_decoder:decode(NewDecoderID, <<>>, 1)),
    ?assertEqual(1, ets:info(router_decoder_custom_sup_ets, size)),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

to_real_payload(Bin) ->
    erlang:list_to_binary(lists:map(fun(X)-> erlang:binary_to_integer(X, 16) end, binary:split(Bin, <<" ">>, [global]))).
