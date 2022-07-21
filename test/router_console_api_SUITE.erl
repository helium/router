-module(router_console_api_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    update_test/1,
    pagination_test/1,
    ws_get_address_test/1,
    ws_request_address_test/1,
    fetch_queue_test/1,
    consume_queue_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("console_test.hrl").
-include("lorawan_vars.hrl").
-include("router_device_worker.hrl").

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
        update_test,
        pagination_test,
        ws_get_address_test,
        ws_request_address_test,
        fetch_queue_test,
        consume_queue_test
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

update_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    Devices = n_rand_devices(1),
    true = ets:insert(Tab, {devices, Devices}),
    {ok, [APIDevices]} = router_console_api:get_devices(),
    DeviceId = router_device:id(APIDevices),
    Key = libp2p_crypto:generate_keys(ecc_compact),

    _Result = router_console_api:update_device(DeviceId, #{ecc_compact => router_utils:encode_ecc(Key)}),

    {ok, [APIDevices2]} = router_console_api:get_devices(),

    Key = router_device:ecc_compact(APIDevices2),

    ok.

pagination_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    Max = 100,
    lists:foreach(
        fun(_) ->
            Devices = n_rand_devices(Max),
            true = ets:insert(Tab, {devices, Devices}),
            {ok, APIDevices} = router_console_api:get_devices(),
            ?assertEqual(Max, erlang:length(APIDevices)),

            Orgs = n_rand_orgs(Max),
            true = ets:insert(Tab, {organizations, Orgs}),
            {ok, APIOrgs} = router_console_api:get_orgs(),
            ?assertEqual(Max, erlang:length(APIOrgs))
        end,
        lists:seq(1, 3)
    ),
    ok.

ws_get_address_test(_Config) ->
    _WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    receive
        {websocket_msg, Map} ->
            PubKeyBin = blockchain_swarm:pubkey_bin(),
            B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
            ?assertEqual(
                #{
                    ref => <<"0">>,
                    topic => <<"organization:all">>,
                    event => <<"router:address">>,
                    jref => <<"0">>,
                    payload => #{<<"address">> => B58}
                },
                Map
            )
    after 2500 -> ct:fail(websocket_msg_timeout)
    end,
    ok.

ws_request_address_test(_Config) ->
    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    receive
        {websocket_msg, Map} ->
            PubKeyBin = blockchain_swarm:pubkey_bin(),
            B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
            ?assertEqual(
                #{
                    ref => <<"0">>,
                    topic => <<"organization:all">>,
                    event => <<"router:address">>,
                    jref => <<"0">>,
                    payload => #{<<"address">> => B58}
                },
                Map
            )
    after 2500 -> ct:fail(websocket_initial_router_address_msg)
    end,

    WSPid ! refetch_router_address,
    receive
        {websocket_msg, #{event := <<"router:address">>}} -> ok
    after 500 -> ct:fail(websocket_refetch_router_address_msg)
    end,

    ok.

consume_queue_test(Config) ->
    #{stream := Stream, pubkey_bin := PubKeyBin} = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Sending debug event from websocket
    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    WSPid ! device_fetch_queue,

    receive
        {websocket_msg, #{event := <<"router:address">>}} ->
            ignore
    after 500 -> ct:fail(websocket_router_address)
    end,

    receive
        {websocket_msg, #{event := <<"downlink:update_queue">>, payload := Payload1}} ->
            ?assertEqual(
                #{
                    <<"device">> => ?CONSOLE_DEVICE_ID,
                    <<"queue">> => []
                },
                Payload1
            )
    after 500 -> ct:fail(websocket_update_queue)
    end,

    {ok, Pid} = router_devices_sup:lookup_device_worker(?CONSOLE_DEVICE_ID),

    Channel = router_channel:new(
        <<"channel_id">>,
        random_handler,
        <<"channel_name">>,
        [],
        ?CONSOLE_DEVICE_ID,
        self()
    ),
    Downlink1 = #downlink{
        confirmed = false,
        port = 0,
        payload = <<"payload">>,
        channel = Channel
    },
    Downlink2 = #downlink{confirmed = false, port = 0, payload = <<"payload">>, channel = Channel},
    ok = router_device_worker:queue_downlink(Pid, Downlink1),
    ok = router_device_worker:queue_downlink(Pid, Downlink2),

    %% Message for 1st queued downlink
    receive
        {websocket_msg, #{
            event := <<"downlink:update_queue">>,
            payload := Payload2
        }} ->
            ?assertEqual(
                #{
                    <<"device">> => ?CONSOLE_DEVICE_ID,
                    <<"queue">> => [
                        #{
                            <<"channel">> => #{
                                <<"id">> => router_channel:id(Channel),
                                <<"name">> => router_channel:name(Channel)
                            },
                            <<"confirmed">> => Downlink1#downlink.confirmed,
                            <<"payload">> => base64:encode(Downlink1#downlink.payload),
                            <<"port">> => Downlink1#downlink.port
                        }
                    ]
                },
                Payload2
            )
    after 500 -> ct:fail(websocket_update_queue)
    end,

    %% Message for 2nd queued downlink
    receive
        {websocket_msg, #{
            event := <<"downlink:update_queue">>,
            payload := Payload3
        }} ->
            ?assertEqual(
                #{
                    <<"device">> => ?CONSOLE_DEVICE_ID,
                    <<"queue">> => [
                        #{
                            <<"channel">> => #{
                                <<"id">> => router_channel:id(Channel),
                                <<"name">> => router_channel:name(Channel)
                            },
                            <<"confirmed">> => Downlink1#downlink.confirmed,
                            <<"payload">> => base64:encode(Downlink1#downlink.payload),
                            <<"port">> => Downlink1#downlink.port
                        },
                        #{
                            <<"channel">> => #{
                                <<"id">> => router_channel:id(Channel),
                                <<"name">> => router_channel:name(Channel)
                            },
                            <<"confirmed">> => Downlink2#downlink.confirmed,
                            <<"payload">> => base64:encode(Downlink2#downlink.payload),
                            <<"port">> => Downlink2#downlink.port
                        }
                    ]
                },
                Payload3
            )
    after 500 -> ct:fail(websocket_update_queue)
    end,

    %% Send uplink to pull downlink from queue
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                _FCnt = 0
            )},
    test_utils:wait_until(fun() ->
        test_utils:get_device_last_seen_fcnt(?CONSOLE_DEVICE_ID) == 0
    end),

    %% Message for downlink being unqueued
    receive
        {websocket_msg, #{
            event := <<"downlink:update_queue">>,
            payload := Payload4
        }} ->
            ?assertEqual(
                #{
                    <<"device">> => ?CONSOLE_DEVICE_ID,
                    <<"queue">> => [
                        #{
                            <<"channel">> => #{
                                <<"id">> => router_channel:id(Channel),
                                <<"name">> => router_channel:name(Channel)
                            },
                            <<"confirmed">> => Downlink2#downlink.confirmed,
                            <<"payload">> => base64:encode(Downlink2#downlink.payload),
                            <<"port">> => Downlink2#downlink.port
                        }
                    ]
                },
                Payload4
            )
    after 500 -> ct:fail(websocket_update_queue)
    end,

    ok.

fetch_queue_test(Config) ->
    _ = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, _Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Sending debug event from websocket
    WSPid =
        receive
            {websocket_init, P} -> P
        after 2500 -> ct:fail(websocket_init_timeout)
        end,
    WSPid ! device_fetch_queue,

    receive
        {websocket_msg, #{event := <<"router:address">>}} ->
            ignore
    after 500 -> ct:fail(websocket_router_address)
    end,

    receive
        {websocket_msg, #{event := <<"downlink:update_queue">>, payload := Payload1}} ->
            ?assertEqual(
                #{
                    <<"device">> => ?CONSOLE_DEVICE_ID,
                    <<"queue">> => []
                },
                Payload1
            )
    after 500 -> ct:fail(websocket_update_queue)
    end,

    {ok, Pid} = router_devices_sup:lookup_device_worker(?CONSOLE_DEVICE_ID),

    Channel = router_channel:new(
        <<"channel_id">>,
        random_handler,
        <<"channel_name">>,
        [],
        ?CONSOLE_DEVICE_ID,
        self()
    ),
    Downlink1 = #downlink{
        confirmed = true,
        port = 0,
        payload = <<"payload">>,
        channel = Channel
    },
    ok = router_device_worker:queue_downlink(Pid, Downlink1),

    receive
        {websocket_msg, #{event := <<"downlink:update_queue">>, payload := Payload2}} ->
            ?assertEqual(
                #{
                    <<"device">> => ?CONSOLE_DEVICE_ID,
                    <<"queue">> => [
                        #{
                            <<"channel">> => #{
                                <<"id">> => router_channel:id(Channel),
                                <<"name">> => router_channel:name(Channel)
                            },
                            <<"confirmed">> => Downlink1#downlink.confirmed,
                            <<"payload">> => base64:encode(Downlink1#downlink.payload),
                            <<"port">> => Downlink1#downlink.port
                        }
                    ]
                },
                Payload2
            )
    after 500 -> ct:fail(websocket_update_queue)
    end,

    LabelID = <<"label_id">>,
    WSPid ! {label_fetch_queue, LabelID},

    receive
        {websocket_msg, #{event := <<"downlink:update_queue">>, payload := Payload3}} ->
            ?assertEqual(
                #{
                    <<"device">> => ?CONSOLE_DEVICE_ID,
                    <<"label">> => <<"label_id">>,
                    <<"queue">> => [
                        #{
                            <<"channel">> => #{
                                <<"id">> => router_channel:id(Channel),
                                <<"name">> => router_channel:name(Channel)
                            },
                            <<"confirmed">> => Downlink1#downlink.confirmed,
                            <<"payload">> => base64:encode(Downlink1#downlink.payload),
                            <<"port">> => Downlink1#downlink.port
                        }
                    ]
                },
                Payload3
            )
    after 500 -> ct:fail(websocket_update_queue)
    end,

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

n_rand_devices(N) ->
    lists:map(
        fun(Idx) ->
            ID = erlang:list_to_binary(io_lib:format("Device-~p", [Idx])),
            Updates = [
                {app_eui, crypto:strong_rand_bytes(8)},
                {dev_eui, crypto:strong_rand_bytes(8)},
                {name, ID},
                {ecc_compact, router_utils:encode_ecc(libp2p_crypto:generate_keys(ecc_compact))}
            ],
            Device = router_device:update(Updates, router_device:new(ID)),
            Device
        end,
        lists:seq(1, N)
    ).

n_rand_orgs(N) ->
    lists:map(
        fun(I) ->
            Name = erlang:list_to_binary(io_lib:format("Org-~p", [I])),
            #{
                id => router_utils:uuid_v4(),
                name => Name,
                balance => 100 * I,
                nonce => I
            }
        end,
        lists:seq(1, N)
    ).
