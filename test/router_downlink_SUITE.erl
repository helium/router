-module(router_downlink_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([http_downlink_test/1, console_tool_downlink_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
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
    [http_downlink_test, console_tool_downlink_test].

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

http_downlink_test(Config) ->
    Payload = <<"httpdownlink">>,
    Message = jsx:encode(#{payload_raw => base64:encode(Payload)}),
    test_downlink_message_for_channel(Config, Payload, Message, ?CONSOLE_HTTP_CHANNEL_NAME).

console_tool_downlink_test(Config) ->
    %% Downlinks queued from the downlink tool will come with a 'from' key in
    %% their payload. The channel name will not be reported as the Channel the
    %% message was queued against to help with debugging for users.
    Payload = <<"console_tool_downlink">>,
    Message = jsx:encode(#{
        payload_raw => base64:encode(Payload),
        from => <<"console_downlink_queue">>
    }),
    test_downlink_message_for_channel(Config, Payload, Message, <<"Console downlink tool">>).

test_downlink_message_for_channel(Config, DownlinkPayload, DownlinkMessage, ExpectedChannelName) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for report device status on that join request
    test_utils:wait_for_console_event(<<"activation">>, #{
        <<"category">> => <<"activation">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => 0,
        <<"frame_down">> => 0,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
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
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => []
    }),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Sending debug event from websocket
    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    WSPid ! {downlink, DownlinkMessage},

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

    %% Waiting for websocket downlink with channel
    test_utils:wait_for_console_event(<<"down">>, #{
        <<"category">> => <<"down">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => fun erlang:is_integer/1,
        <<"frame_down">> => fun erlang:is_integer/1,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => 27,
                <<"snr">> => fun erlang:is_float/1,
                <<"spreading">> => fun erlang:is_binary/1,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => [
            #{
                <<"id">> => <<"console_websocket">>,
                <<"name">> => ExpectedChannelName,
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"description">> => '_'
            }
        ]
    }),

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> => fun erlang:is_binary/1,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => 1
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => 1,
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
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

    %% Waiting for report channel status from HTTP channel
    test_utils:wait_for_console_event(<<"up">>, #{
        <<"category">> => <<"up">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => fun erlang:is_integer/1,
        <<"frame_down">> => fun erlang:is_integer/1,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => fun erlang:is_number/1,
                <<"snr">> => fun erlang:is_float/1,
                <<"spreading">> => fun erlang:is_binary/1,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => [
            #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"description">> => '_'
            }
        ]
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
        0
    ),

    %% We ignore the channel correction  and down messages
    ok = test_utils:ignore_messages(),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
