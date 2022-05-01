-module(router_data_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    data_test_1/1,
    data_test_2/1,
    data_test_3/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").

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
        data_test_1,
        data_test_2,
        data_test_3
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

data_test_1(Config) ->
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
    {ok, Device} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send UNCONFIRMED_UP frame packet
    DataRate = <<"SF8BW125">>,
    RSSI = -97.0,
    SNR = -12.100000381469727,
    Port = 2,
    Body = <<"body">>,
    Payload = <<Port:8/integer, Body/binary>>,
    SCPacket =
        test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            router_device:nwk_s_key(Device),
            router_device:app_s_key(Device),
            0,
            #{datarate => DataRate, rssi => RSSI, snr => SNR, body => Payload, dont_encode => true}
        ),
    Stream !
        {send,
            blockchain_state_channel_v1_pb:encode_msg(#blockchain_state_channel_message_v1_pb{
                msg = {packet, SCPacket}
            })},

    ReportedAtCheck = fun(ReportedAt) ->
        Now = erlang:system_time(millisecond),
        Now - ReportedAt < 250 andalso Now - ReportedAt > 0
    end,

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> =>
            <<?CONSOLE_URL/binary, "/api/v1/down/", ?CONSOLE_HTTP_CHANNEL_ID/binary, "/",
                ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN/binary, "/", ?CONSOLE_DEVICE_ID/binary>>,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => ReportedAtCheck,
        <<"payload">> => base64:encode(Body),
        <<"payload_size">> => erlang:byte_size(Body),
        <<"raw_packet">> => base64:encode(
            blockchain_helium_packet_v1:payload(blockchain_state_channel_packet_v1:packet(SCPacket))
        ),
        <<"port">> => Port,
        <<"devaddr">> => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => ReportedAtCheck,
                <<"hold_time">> => 100,
                <<"status">> => <<"success">>,
                <<"rssi">> => RSSI,
                <<"snr">> => SNR,
                <<"spreading">> => DataRate,
                <<"frequency">> => 923.2999877929688,
                <<"channel">> => 105,
                <<"lat">> => 36.999918858583605,
                <<"long">> => fun check_long/1
            }
        ],
        <<"dc">> => #{
            <<"balance">> => fun erlang:is_integer/1,
            <<"nonce">> => fun erlang:is_integer/1
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_unconfirmed">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_unconfirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => ReportedAtCheck,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => fun erlang:is_map/1,
            <<"fcnt">> => 0,
            <<"payload_size">> => erlang:byte_size(Body),
            <<"payload">> => base64:encode(Body),
            <<"raw_packet">> => base64:encode(
                blockchain_helium_packet_v1:payload(
                    blockchain_state_channel_packet_v1:packet(SCPacket)
                )
            ),
            <<"port">> => Port,
            <<"devaddr">> => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => RSSI,
                <<"snr">> => SNR,
                <<"spreading">> => DataRate,
                <<"frequency">> => 923.2999877929688,
                <<"channel">> => 105,
                <<"lat">> => 36.999918858583605,
                <<"long">> => fun check_long/1
            },
            <<"mac">> => [],
            <<"hold_time">> => 100
        }
    }),

    ok.

%%--------------------------------------------------------------------
%% data_test_2
%% Same as data_test_1 (except REGION = EU868)
%%--------------------------------------------------------------------

data_test_2(Config) ->
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send CONFIRMED_UP frame packet
    DataRate = <<"SF8BW125">>,
    RSSI = -35.0,
    SNR = -12.100000381469727,
    Port = 2,
    Body = <<"body">>,
    Payload = <<Port:8/integer, Body/binary>>,
    Region = 'EU868',
    SCPacket = test_utils:frame_packet(
        ?CONFIRMED_UP,
        PubKeyBin,
        router_device:nwk_s_key(Device),
        router_device:app_s_key(Device),
        0,
        #{
            region => Region,
            datarate => DataRate,
            rssi => RSSI,
            snr => SNR,
            body => Payload,
            dont_encode => true
        }
    ),
    Stream !
        {send,
            blockchain_state_channel_v1_pb:encode_msg(#blockchain_state_channel_message_v1_pb{
                msg = {packet, SCPacket}
            })},

    ReportedAtCheck = fun(ReportedAt) ->
        Now = erlang:system_time(millisecond),
        Now - ReportedAt < 250 andalso Now - ReportedAt > 0
    end,

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> =>
            <<?CONSOLE_URL/binary, "/api/v1/down/", ?CONSOLE_HTTP_CHANNEL_ID/binary, "/",
                ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN/binary, "/", ?CONSOLE_DEVICE_ID/binary>>,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => ReportedAtCheck,
        <<"payload">> => base64:encode(Body),
        <<"payload_size">> => erlang:byte_size(Body),
        <<"raw_packet">> => base64:encode(
            blockchain_helium_packet_v1:payload(blockchain_state_channel_packet_v1:packet(SCPacket))
        ),
        <<"port">> => Port,
        <<"devaddr">> => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => ReportedAtCheck,
                <<"hold_time">> => 100,
                <<"status">> => <<"success">>,
                <<"rssi">> => RSSI,
                <<"snr">> => SNR,
                <<"spreading">> => DataRate,
                <<"frequency">> => 923.2999877929688,
                <<"channel">> => 276,
                <<"lat">> => 36.999918858583605,
                <<"long">> => fun check_long/1
            }
        ],
        <<"dc">> => #{
            <<"balance">> => fun erlang:is_integer/1,
            <<"nonce">> => fun erlang:is_integer/1
        }
    }),

    %% ---------------------------------------------------------------
    %% Waiting for ack cause we sent a CONFIRMED_UP
    %% ---------------------------------------------------------------
    test_utils:wait_for_console_event_sub(<<"downlink_ack">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_ack">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 0,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => 0,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                %% RSSI act as power here we are and based on UPLINK RSSI > -80 we should power downlink at 14
                <<"rssi">> => 14,
                <<"snr">> => fun erlang:is_float/1,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),

    ok.

%%--------------------------------------------------------------------
%% data_test_3
%% Same as data_test_1
%%   (except REGION = EU868)
%%   (except RSSI = -135.0)
%%   (This is intended to test rx windows 2 preference)
%%--------------------------------------------------------------------

data_test_3(Config) ->
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device} = router_device:get_by_id(DB, CF, WorkerID),

    %% Send CONFIRMED_UP frame packet
    DataRate = <<"SF8BW125">>,
    RSSI = -135.0,
    SNR = -12.100000381469727,
    Port = 2,
    Body = <<"body">>,
    Payload = <<Port:8/integer, Body/binary>>,
    Region = 'EU868',
    SCPacket = test_utils:frame_packet(
        ?CONFIRMED_UP,
        PubKeyBin,
        router_device:nwk_s_key(Device),
        router_device:app_s_key(Device),
        0,
        #{
            region => Region,
            datarate => DataRate,
            rssi => RSSI,
            snr => SNR,
            body => Payload,
            dont_encode => true
        }
    ),
    Stream !
        {send,
            blockchain_state_channel_v1_pb:encode_msg(#blockchain_state_channel_message_v1_pb{
                msg = {packet, SCPacket}
            })},

    ReportedAtCheck = fun(ReportedAt) ->
        Now = erlang:system_time(millisecond),
        Now - ReportedAt < 250 andalso Now - ReportedAt > 0
    end,

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> =>
            <<?CONSOLE_URL/binary, "/api/v1/down/", ?CONSOLE_HTTP_CHANNEL_ID/binary, "/",
                ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN/binary, "/", ?CONSOLE_DEVICE_ID/binary>>,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => ReportedAtCheck,
        <<"payload">> => base64:encode(Body),
        <<"payload_size">> => erlang:byte_size(Body),
        <<"raw_packet">> => base64:encode(
            blockchain_helium_packet_v1:payload(blockchain_state_channel_packet_v1:packet(SCPacket))
        ),
        <<"port">> => Port,
        <<"devaddr">> => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => ReportedAtCheck,
                <<"hold_time">> => 100,
                <<"status">> => <<"success">>,
                <<"rssi">> => RSSI,
                <<"snr">> => SNR,
                <<"spreading">> => DataRate,
                <<"frequency">> => 923.2999877929688,
                <<"channel">> => 276,
                <<"lat">> => 36.999918858583605,
                <<"long">> => fun check_long/1
            }
        ],
        <<"dc">> => #{
            <<"balance">> => fun erlang:is_integer/1,
            <<"nonce">> => fun erlang:is_integer/1
        }
    }),

    %% ---------------------------------------------------------------
    %% Waiting for ack cause we sent a CONFIRMED_UP
    %% ---------------------------------------------------------------
    test_utils:wait_for_console_event_sub(<<"downlink_ack">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_ack">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 0,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => 0,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                %% RSSI act as power here we are and based on UPLINK RSSI < -80 we should power downlink at 27
                <<"rssi">> => 30,
                <<"snr">> => fun erlang:is_float/1,
                <<"spreading">> => <<"SF12BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

%% this is due to floating points...
-spec check_long(float()) -> boolean().
check_long(-120.80001353058655) -> true;
check_long(-120.80001353058657) -> true;
check_long(_) -> false.
