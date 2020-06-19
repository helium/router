-module(router_channel_aws_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-export([aws_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-include_lib("common_test/include/ct.hrl").

-include_lib("eunit/include/eunit.hrl").

-include("device_worker.hrl").

-include("lorawan_vars.hrl").

-include("utils/console_test.hrl").

-define(DECODE(A), jsx:decode(A, [return_maps])).

-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).

-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

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
    [].

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
%% TODO
%% - setup credential (aws_access_key, aws_secret_key)
%% - sub to helium/#
%% - Detach certificate for thing yolo_id (?CONSOLE_DEVICE_ID)
%% - Go to aws console and send message {"payload_raw":"bXF0dHBheWxvYWQ="} helium/devices/yolo_id/down
aws_test(Config) ->
    %% Set console to AWS channel mode
    Tab = proplists:get_value(
        ets,
        Config
    ),
    ets:insert(
        Tab,
        {channel_type,
            aws}
    ),

    AppKey =
        proplists:get_value(
            app_key,
            Config
        ),
    Swarm =
        proplists:get_value(
            swarm,
            Config
        ),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] =
        libp2p_swarm:listen_addrs(
            RouterSwarm
        ),
    {ok, Stream} =
        libp2p_swarm:dial_framed_stream(
            Swarm,
            Address,
            router_handler_test:version(),
            router_handler_test,
            [self()]
        ),
    PubKeyBin =
        libp2p_swarm:pubkey_bin(
            Swarm
        ),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(
        libp2p_crypto:bin_to_b58(PubKeyBin)
    ),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},
    timer:sleep(
        ?JOIN_DELAY
    ),

    %% Waiting for report device status on that join request
    test_utils:wait_report_device_status(#{
        <<"category">> => <<"activation">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => 0,
        <<"frame_down">> => 0,
        <<"payload_size">> => 0,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"hotspots">> => [#{
            <<"id">> => erlang:list_to_binary(
                libp2p_crypto:bin_to_b58(PubKeyBin)
            ),
            <<"name">> =>
                erlang:list_to_binary(HotspotName),
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"status">> => <<"success">>,
            <<"rssi">> => 0.0,
            <<"snr">> => 0.0,
            <<"spreading">> => <<"SF8BW125">>,
            <<"frequency">> => fun erlang:is_float/1,
            <<"channel">> => fun erlang:is_number/1
        }],
        <<"channels">> => []
    }),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID =
        router_devices_sup:id(
            ?CONSOLE_DEVICE_ID
        ),
    {ok, Device0} = router_device:get(
        DB,
        CF,
        WorkerID
    ),

    %% Send UNCONFIRMED_UP frame packet
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0
            )},

    %% Waiting for report channel status from AWS channel
    test_utils:wait_report_channel_status(#{
        <<"category">> => <<"up">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => fun erlang:is_integer/1,
        <<"frame_down">> => fun erlang:is_integer/1,
        <<"payload_size">> => 0,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"hotspots">> => [#{
            <<"id">> => erlang:list_to_binary(
                libp2p_crypto:bin_to_b58(PubKeyBin)
            ),
            <<"name">> =>
                erlang:list_to_binary(HotspotName),
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"status">> => <<"success">>,
            <<"rssi">> => 0.0,
            <<"snr">> => 0.0,
            <<"spreading">> => <<"SF8BW125">>,
            <<"frequency">> => fun erlang:is_float/1,
            <<"channel">> => fun erlang:is_number/1
        }],
        <<"channels">> => [#{
            <<"id">> => ?CONSOLE_AWS_CHANNEL_ID,
            <<"name">> => ?CONSOLE_AWS_CHANNEL_NAME,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"status">> => <<"success">>,
            <<"description">> => '_'
        }]
    }),

    %% We ignore the channel correction messages
    ok = test_utils:ignore_messages(),

    %% Go to aws console and send message {"payload_raw":"bXF0dHBheWxvYWQ="} helium/devices/yolo_id/down
    DownlinkPayload = <<"mqttpayload">>,
    timer:sleep(
        timer:seconds(45)
    ),

    %% Send UNCONFIRMED_UP frame packet
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                1
            )},

    %% Waiting for report channel status from AWS channel
    test_utils:wait_report_channel_status(#{
        <<"category">> => <<"up">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => fun erlang:is_integer/1,
        <<"frame_down">> => fun erlang:is_integer/1,
        <<"payload_size">> => 0,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"hotspots">> => [#{
            <<"id">> => erlang:list_to_binary(
                libp2p_crypto:bin_to_b58(PubKeyBin)
            ),
            <<"name">> =>
                erlang:list_to_binary(HotspotName),
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"status">> => <<"success">>,
            <<"rssi">> => 0.0,
            <<"snr">> => 0.0,
            <<"spreading">> => <<"SF8BW125">>,
            <<"frequency">> => fun erlang:is_float/1,
            <<"channel">> => fun erlang:is_number/1
        }],
        <<"channels">> => [#{
            <<"id">> => ?CONSOLE_AWS_CHANNEL_ID,
            <<"name">> => ?CONSOLE_AWS_CHANNEL_NAME,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"status">> => <<"success">>,
            <<"description">> => '_'
        }]
    }),

    %% Waiting for donwlink message on the hotspot
    Msg0 = {false, 1, DownlinkPayload},
    {ok, _} = test_utils:wait_state_channel_message(
        Msg0,
        Device0,
        erlang:element(3, Msg0),
        ?UNCONFIRMED_DOWN,
        0,
        0,
        1,
        1
    ),

    %% We ignore the report status down
    ok = test_utils:ignore_messages(),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
