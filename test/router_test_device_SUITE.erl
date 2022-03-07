-module(router_test_device_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    data_test_1/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("router_test_console.hrl").

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
        data_test_1
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
    [{PrivKey, PubKey} | _] = proplists:get_value(hotspots, Config),
    {ok, TestDevicePid} = router_test_device:start(#{
        hotspot_keys => #{secret => PrivKey, public => PubKey}
    }),

    ok = test_utils:join_device(TestDevicePid),

    TestDevice = router_test_device:device(TestDevicePid),
    DeviceID = router_device:id(TestDevice),
    PubKeyBin = router_test_device:hotspot_pubkey_bin(TestDevicePid),
    HotspotName = blockchain_utils:addr2name(PubKeyBin),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    {ok, Device} = router_device:get_by_id(DB, CF, DeviceID),

    %% Send UNCONFIRMED_UP frame packet
    DataRate = <<"SF8BW125">>,
    Freq = 923.2999877929688,
    RSSI = -97.0,
    SNR = -12.100000381469727,
    Port = 2,
    Body = <<"body">>,
    Payload = <<Port:8/integer, Body/binary>>,
    HoldTime = rand:uniform(2000),
    {ok, SCPacket} = router_test_device:uplink(TestDevicePid, #{
        freq => Freq,
        dr => erlang:binary_to_list(DataRate),
        rssi => RSSI,
        snr => SNR,
        body => Payload,
        hold_time => HoldTime
    }),

    ReportedAtCheck = fun(ReportedAt) ->
        Now = erlang:system_time(millisecond),
        Now - ReportedAt < 250 andalso Now - ReportedAt > 0
    end,

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => DeviceID,
        <<"downlink_url">> =>
            <<?CONSOLE_URL/binary, "/api/v1/down/", ?CONSOLE_HTTP_CHANNEL_ID/binary, "/",
                ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN/binary, "/", DeviceID/binary>>,
        <<"name">> => router_device:name(TestDevice),
        <<"dev_eui">> => lorawan_utils:binary_to_hex(router_device:dev_eui(TestDevice)),
        <<"app_eui">> => lorawan_utils:binary_to_hex(router_device:app_eui(TestDevice)),
        <<"metadata">> => #{
            <<"labels">> => #{},
            <<"organization_id">> => maps:get(organization_id, router_device:metadata(TestDevice)),
            <<"multi_buy">> => 1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay">> => 1,
            <<"rx_delay_actual">> => 1,
            <<"rx_delay_state">> => <<"rx_delay_established">>
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
                <<"hold_time">> => HoldTime,
                <<"status">> => <<"success">>,
                <<"rssi">> => RSSI,
                <<"snr">> => SNR,
                <<"spreading">> => DataRate,
                <<"frequency">> => Freq,
                <<"channel">> => 105,
                <<"lat">> => fun check_lat/1,
                <<"long">> => fun check_long/1
            }
        ]
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_unconfirmed">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_unconfirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => ReportedAtCheck,
        <<"device_id">> => DeviceID,
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
                <<"frequency">> => Freq,
                <<"channel">> => 105,
                <<"lat">> => fun check_lat/1,
                <<"long">> => fun check_long/1
            },
            <<"mac">> => [],
            <<"hold_time">> => HoldTime
        }
    }),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

%% this is due to floating points...
-spec check_lat(float()) -> boolean().
check_lat(Lat) when Lat < 37.01 andalso Lat > 36.99 ->
    true;
check_lat(_) ->
    false.

%% this is due to floating points...
-spec check_long(float()) -> boolean().
check_long(Long) when Long < -120.0 andalso Long > -122.0 ->
    true;
check_long(_) ->
    false.
