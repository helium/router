-module(router_downlink_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    http_downlink_test/1,
    console_tool_downlink_test/1,
    console_tool_downlink_order_test/1,
    console_tool_clear_queue_test/1
]).

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
    [
        http_downlink_test,
        console_tool_downlink_test,
        console_tool_downlink_order_test,
        console_tool_clear_queue_test
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

http_downlink_test(Config) ->
    Payload = <<"httpdownlink">>,
    Message = #{payload_raw => base64:encode(Payload)},
    test_downlink_message_for_channel(Config, Payload, Message, ?CONSOLE_HTTP_CHANNEL_NAME).

console_tool_downlink_test(Config) ->
    %% Downlinks queued from the downlink tool will come with a 'from' key in
    %% their payload. The channel name will not be reported as the Channel the
    %% message was queued against to help with debugging for users.
    Payload = <<"console_tool_downlink">>,
    Message = #{
        payload_raw => base64:encode(Payload),
        from => <<"console_downlink_queue">>
    },
    test_downlink_message_for_channel(Config, Payload, Message, <<"Console downlink tool">>).

console_tool_downlink_order_test(Config) ->
    #{
        pubkey_bin := PubKeyBin,
        stream := Stream
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Grab the websocket
    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,

    %% Send packet to trigger downlink
    SendPacketAndExpectFun = fun(Options) ->
        #{downlink := Downlink, payload := Payload, pending := Pending, fcnt := FCnt} = Options,

        Stream !
            {send,
                test_utils:frame_packet(
                    ?UNCONFIRMED_UP,
                    PubKeyBin,
                    router_device:nwk_s_key(Device0),
                    router_device:app_s_key(Device0),
                    FCnt
                )},

        {ok, _} = test_utils:wait_state_channel_message(
            {false, 1, Downlink},
            Device0,
            Payload,
            ?UNCONFIRMED_DOWN,
            Pending,
            _Ack = 0,
            _FPort = 1,
            FCnt
        )
    end,

    ExpectDownlinkQueuedMessageFun = fun(Position) ->
        test_utils:wait_for_console_event_sub(<<"downlink_queued">>, #{
            <<"id">> => fun erlang:is_binary/1,
            <<"category">> => <<"downlink">>,
            <<"sub_category">> => <<"downlink_queued">>,
            <<"description">> => <<"Downlink queued in ", Position/binary, " place">>,
            <<"reported_at">> => fun erlang:is_integer/1,
            <<"device_id">> => ?CONSOLE_DEVICE_ID,
            <<"data">> => #{
                <<"integration">> => #{
                    <<"id">> => <<"console_websocket">>,
                    <<"name">> => <<"fake_http">>,
                    <<"status">> => <<"success">>
                }
            }
        })
    end,

    %% Prepare Data
    Payload0 = <<"one">>,
    Payload1 = <<"two">>,
    Payload2 = <<"three">>,

    Downlink0 = #{payload_raw => base64:encode(Payload0)},
    Downlink1 = #{payload_raw => base64:encode(Payload1)},
    Downlink2 = #{payload_raw => base64:encode(Payload2)},

    %% Queue Downlinks in order
    WSPid ! {downlink, Downlink0},
    WSPid ! {downlink, Downlink1},
    WSPid ! {downlink, Downlink2},
    ExpectDownlinkQueuedMessageFun(<<"last">>),
    ExpectDownlinkQueuedMessageFun(<<"last">>),
    ExpectDownlinkQueuedMessageFun(<<"last">>),

    %% Expect Downlinks in order they were queued
    SendPacketAndExpectFun(#{downlink => Downlink0, payload => Payload0, pending => 1, fcnt => 0}),
    SendPacketAndExpectFun(#{downlink => Downlink1, payload => Payload1, pending => 1, fcnt => 1}),
    SendPacketAndExpectFun(#{downlink => Downlink2, payload => Payload2, pending => 0, fcnt => 2}),

    %% Eat messages so we can try again
    ok = test_utils:ignore_messages(),

    %% Queue Downlinks with last message asking for priority
    WSPid ! {downlink, Downlink0},
    WSPid ! {downlink, Downlink1},
    WSPid ! {downlink, maps:merge(Downlink2, #{position => <<"first">>})},
    ExpectDownlinkQueuedMessageFun(<<"last">>),
    ExpectDownlinkQueuedMessageFun(<<"last">>),
    ExpectDownlinkQueuedMessageFun(<<"first">>),

    %% Expect last Downlink first, then in order
    SendPacketAndExpectFun(#{downlink => Downlink2, payload => Payload2, pending => 1, fcnt => 3}),
    SendPacketAndExpectFun(#{downlink => Downlink0, payload => Payload0, pending => 1, fcnt => 4}),
    SendPacketAndExpectFun(#{downlink => Downlink1, payload => Payload1, pending => 0, fcnt => 5}),

    ok = test_utils:ignore_messages(),

    ok.

test_downlink_message_for_channel(Config, DownlinkPayload, DownlinkMessage, ExpectedChannelName) ->
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
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Sending debug event from websocket
    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    WSPid ! {downlink, DownlinkMessage},

    test_utils:wait_for_console_event_sub(<<"downlink_queued">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_queued">>,
        <<"description">> => <<"Downlink queued in last place">>,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"integration">> => #{
                <<"id">> => <<"console_websocket">>,
                <<"name">> => ExpectedChannelName,
                <<"status">> => <<"success">>
            }
        }
    }),

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
    test_utils:wait_for_console_event_sub(<<"downlink_unconfirmed">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"downlink">>,
        <<"sub_category">> => <<"downlink_unconfirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => fun erlang:is_integer/1,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
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
            <<"adr_allowed">> => false
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => 1,
        <<"devaddr">> => '_',
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
    test_utils:wait_for_console_event(<<"uplink">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_unconfirmed">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => #{<<"balance">> => 98, <<"nonce">> => 1, <<"used">> => 1},
            <<"fcnt">> => fun erlang:is_integer/1,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_req">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_req">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Request sent to ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"req">> => #{
                <<"method">> => <<"POST">>,
                <<"url">> => <<?CONSOLE_URL/binary, "/channel">>,
                <<"body">> => fun erlang:is_binary/1,
                <<"headers">> => fun erlang:is_map/1
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
    }),

    test_utils:wait_for_console_event_sub(<<"uplink_integration_res">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"uplink">>,
        <<"sub_category">> => <<"uplink_integration_res">>,
        <<"description">> => erlang:list_to_binary(
            io_lib:format("Response received from ~p", [?CONSOLE_HTTP_CHANNEL_NAME])
        ),
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"res">> => #{
                <<"body">> => <<"success">>,
                <<"headers">> => fun erlang:is_map/1,
                <<"code">> => 200
            },
            <<"integration">> => #{
                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME,
                <<"status">> => <<"success">>
            }
        }
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

console_tool_clear_queue_test(Config) ->
    #{} = test_utils:join_device(Config),

    %% Grab the websocket
    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,

    %% Helper
    GetDeviceQueueLengthFn = fun() ->
        Device = test_utils:get_device_worker_device(?CONSOLE_DEVICE_ID),
        Q = router_device:queue(Device),
        erlang:length(Q)
    end,

    %% Queue Downlinks in order
    WSPid ! {downlink, #{payload_raw => base64:encode(<<"one">>)}},
    WSPid ! {downlink, #{payload_raw => base64:encode(<<"two">>)}},
    WSPid ! {downlink, #{payload_raw => base64:encode(<<"three">>)}},

    %% Wait for downlinks to be queued
    ok = test_utils:wait_until(fun() -> GetDeviceQueueLengthFn() == 3 end),

    %% Clear Queue
    WSPid ! clear_queue,

    %% Wait for downlinks to be cleared
    ok = test_utils:wait_until(fun() -> GetDeviceQueueLengthFn() == 0 end),

    ok = test_utils:ignore_messages(),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
