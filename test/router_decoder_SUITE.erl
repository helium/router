-module(router_decoder_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    decode_test/1,
    template_test/1,
    timeout_test/1,
    too_many_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("console_test.hrl").
-include("lorawan_vars.hrl").

-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

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
        decode_test,
        template_test,
        timeout_test,
        too_many_test
    ].

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

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send UNCONFIRMED_UP frame packet 20 02 F8 00 => #{<<"vSys">> => -0.5}
    EncodedPayload = to_real_payload(<<"20 02 F8 00">>),
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{body => <<1:8, EncodedPayload/binary>>}
            )},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => fun erlang:is_binary/1,
        <<"payload_size">> => fun erlang:is_number/1,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"decoded">> => #{
            <<"status">> => <<"success">>,
            <<"payload">> => #{<<"vSys">> => -0.5}
        },
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ]
    }),
    ok.

template_test(Config) ->
    %% Set console to decoder channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, template}),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    EncodedPayload = base64:decode(<<"CP4+AAAAAAAAAAA=">>),
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{body => <<136:8, EncodedPayload/binary>>}
            )},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{<<"battery">> => 100.0, <<"lat">> => 0.0, <<"long">> => 0.0}),
    ok.

timeout_test(Config) ->
    %% Set console to decoder channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, decoder}),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send UNCONFIRMED_UP frame packet 20 02 F8 00 => #{<<"vSys">> => -0.5}
    EncodedPayload = to_real_payload(<<"20 02 F8 00">>),
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{body => <<1:8, EncodedPayload/binary>>}
            )},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => fun erlang:is_binary/1,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"decoded">> => #{
            <<"status">> => <<"success">>,
            <<"payload">> => #{<<"vSys">> => -0.5}
        },
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ]
    }),

    DecoderID = maps:get(<<"id">>, ?CONSOLE_DECODER),
    [{DecoderID, {custom_decoder, DecoderID, _Hash, _Fun, DecoderPid, _LastUsed}}] = ets:lookup(
        router_decoder_custom_sup_ets,
        DecoderID
    ),

    DecoderPid ! timeout,
    timer:sleep(1000),

    ?assertNot(erlang:is_process_alive(DecoderPid)),
    ?assertEqual([], ets:lookup(router_decoder_custom_sup_ets, DecoderID)),
    ok.

too_many_test(Config) ->
    MaxV8Context = application:get_env(router, max_v8_context, 10),
    ok = application:set_env(router, max_v8_context, 1),

    %% Set console to decoder channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, decoder}),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send UNCONFIRMED_UP frame packet 20 02 F8 00 => #{<<"vSys">> => -0.5}
    EncodedPayload = to_real_payload(<<"20 02 F8 00">>),
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{body => <<1:8, EncodedPayload/binary>>}
            )},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => fun erlang:is_binary/1,
        <<"payload_size">> => fun erlang:is_number/1,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"decoded">> => #{
            <<"status">> => <<"success">>,
            <<"payload">> => #{<<"vSys">> => -0.5}
        },
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ]
    }),

    DecoderID = maps:get(<<"id">>, ?CONSOLE_DECODER),
    [{DecoderID, {custom_decoder, DecoderID, _Hash, _Fun, DecoderPid, _LastUsed}}] = ets:lookup(
        router_decoder_custom_sup_ets,
        DecoderID
    ),

    NewDecoder = router_decoder:new(<<"new-decoder">>, custom, #{
        function => <<"function Decoder(bytes, port) {return 'ok'}">>
    }),
    ok = router_decoder:add(NewDecoder),

    %% This assumes max_v8_context = 1 within ../config/test.config or equivalent,
    %% so see application:set_env() above and original value restored below.
    ?assertNot(erlang:is_process_alive(DecoderPid)),

    NewDecoderID = router_decoder:id(NewDecoder),
    [{NewDecoderID, _}] = ets:lookup(router_decoder_custom_sup_ets, NewDecoderID),
    %% decoder gets auto restarted if removed
    ?assertEqual({ok, undefined}, router_decoder:decode(DecoderID, <<>>, 1, #{})),
    ?assertEqual({ok, <<"ok">>}, router_decoder:decode(NewDecoderID, <<>>, 1, #{})),
    ?assertEqual(1, ets:info(router_decoder_custom_sup_ets, size)),

    ok = application:set_env(router, max_v8_context, MaxV8Context).

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

to_real_payload(Bin) ->
    erlang:list_to_binary(
        lists:map(
            fun(X) -> erlang:binary_to_integer(X, 16) end,
            binary:split(Bin, <<" ">>, [global])
        )
    ).
