-module(router_dc_tracking_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([dc_test/1]).

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
    [dc_test].

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

dc_test(Config) ->
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
                                           <<"payload_size">> => 0,
                                           <<"port">> => '_',
                                           <<"devaddr">> => '_',
                                           <<"dc">> => #{<<"balance">> => 100, <<"nonce">> => 1},
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
                                                                <<"long">> => fun erlang:is_float/1}],
                                           <<"channels">> => []}),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Simulate multiple hotspot sending data
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin1, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},

    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    {ok, HotspotName2} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin2)),
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},

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
                                   <<"dc">> => #{<<"balance">> => 98, <<"nonce">> => 1},
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
                                            <<"payload_size">> => 0,
                                            <<"port">> => '_',
                                            <<"devaddr">> => '_',
                                            <<"dc">> => #{<<"balance">> => 98, <<"nonce">> => 1},
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
    ok.
