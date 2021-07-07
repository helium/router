-module(router_data_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([data_test/1]).

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
    [data_test].

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

data_test(Config) ->
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

    %% Send UNCONFIRMED_UP frame packet
    DataRate = <<"SF8BW125">>,
    RSSI = -97.0,
    SNR = -12.100000381469727,
    Port = 2,
    Body = <<"body">>,
    Payload = <<Port:8/integer, Body/binary>>,
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device),
                router_device:app_s_key(Device),
                0,
                #{datarate => DataRate, rssi => RSSI, snr => SNR, body => Payload}
            )},

    ReportedAtCheck = fun(ReportedAt) ->
        Now = erlang:system_time(millisecond),
        Now - ReportedAt < 250 andalso Now - ReportedAt > 0
    end,

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
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
            <<"cf_list_enabled">> => true
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => ReportedAtCheck,
        <<"payload">> => base64:encode(Body),
        <<"payload_size">> => erlang:byte_size(Body),
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
                <<"long">> => -120.80001353058655
            }
        ]
    }),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
