-module(router_console_api_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([ws_get_address_test/1, fetch_queue_test/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("utils/console_test.hrl").
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
    [ws_get_address_test, fetch_queue_test].

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

fetch_queue_test(Config) ->
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
    DevNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, DevNonce)},
    timer:sleep(router_device_utils:join_timeout()),

    %% Waiting for report device status on that join request
    test_utils:wait_for_console_event(<<"join_req">>, #{
        <<"category">> => <<"join_req">>,
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
        {websocket_msg, #{event := <<"device:all:downlink:update_queue">>, payload := Payload1}} ->
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
        confirmed = 1,
        port = 0,
        payload = <<"payload">>,
        channel = Channel
    },
    ok = router_device_worker:queue_message(Pid, Downlink1),

    receive
        {websocket_msg, #{event := <<"device:all:downlink:update_queue">>, payload := Payload2}} ->
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
                            <<"payload">> => Downlink1#downlink.payload,
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
        {websocket_msg, #{event := <<"label:all:downlink:update_queue">>, payload := Payload3}} ->
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
                            <<"payload">> => Downlink1#downlink.payload,
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
