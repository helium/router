-module(router_ics_skf_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").
-include("console_test.hrl").
-include("lorawan_vars.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1,
    reconcile_test/1,
    diff_against_local_test/1,
    live_test/1
]).

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
        main_test,
        reconcile_test,
        diff_against_local_test,
        live_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(live_test, Config) ->
    ok = setup_live_test(),

    test_utils:init_per_testcase(live_test, Config);
init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_skf_service, self()),
    Port = 8085,
    ServerPid = start_server(Port),
    ok = application:set_env(
        router,
        ics,
        #{skf_enabled => "true", transport => "http", host => "localhost", port => Port},
        [{persistent, true}]
    ),
    test_utils:init_per_testcase(TestCase, [{ics_server, ServerPid} | Config]).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------

end_per_testcase(live_test, Config) ->
    test_utils:end_per_testcase(live_test, Config),
    ok;
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config),
    ServerPid = proplists:get_value(ics_server, Config),
    case erlang:is_process_alive(ServerPid) of
        true -> gen_server:stop(ServerPid);
        false -> ok
    end,
    _ = application:stop(grpcbox),
    ok = application:set_env(
        router,
        ics,
        #{},
        [{persistent, true}]
    ),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

setup_live_test() ->
    Transport = http,
    Host = "localhost",
    Port = 50051,
    SwarmKey = "absolute-path-to-keyfile",

    ok = application:set_env(
        grpcbox,
        client,
        #{channels => [{default_channel, [{Transport, Host, Port, []}], #{}}]}
    ),

    {PubKey0, SigFun, _} = load_keys(SwarmKey),

    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey0),
    ct:print("going forward with pubkey: ~p", [libp2p_crypto:pubkey_to_b58(PubKey0)]),
    ok = application:set_env(
        router,
        ics,
        #{
            skf_enabled => "true",
            transport => Transport,
            host => Host,
            port => Port,
            pubkey_bin => PubKeyBin,
            sig_fun => SigFun,
            reconcile_on_connect => false
        },
        [{persistent, true}]
    ),
    ok = application:set_env(router, config_service_batch_sleep_ms, 250),
    ok = application:set_env(router, config_service_batch_size, 250),
    ok = application:set_env(router, oui, 2, [{persistent, true}]).

live_test(_Config) ->
    %% 1. Gather the starting number to compare against at the end.
    {ok, Els0} = router_ics_skf_worker:list_skf(),
    StartingCount = erlang:length(Els0),
    ct:print("Starting: ~p", [length(Els0)]),

    %% 2. Fill the cache with devices
    Start = 1207960576,
    End = 1207961599,
    Size = End - Start,
    Create = fun(Prefix, X) ->
        router_device:update(
            [
                {devaddrs, [binary:encode_unsigned(rand:uniform(Size) + Start, little)]},
                {keys, [{crypto:strong_rand_bytes(16), <<>>}]}
            ],
            router_device:new(erlang:list_to_binary(io_lib:format("Device ~p ~p", [Prefix, X])))
        )
    end,

    DeviceCount = 7500,
    ct:print("making ~p devices", [DeviceCount]),
    Devices = lists:map(fun(Idx) -> Create(1, Idx) end, lists:seq(1, DeviceCount)),
    [router_device_cache:save(D) || D <- Devices],

    %% 3. Trigger a reconcile
    ok = router_ics_skf_worker:reconcile(self(), true),
    ok = test_utils:wait_until(fun() -> not router_ics_skf_worker:is_reconciling() end, 50, 1000),

    %% 4. We have that many more devices than we started with...
    ct:print("waiting 5 seconds before getting the list"),
    timer:sleep(timer:seconds(5)),
    {ok, Els1} = router_ics_skf_worker:list_skf(),
    AddingCount = erlang:length(Els1),
    ct:print("Starting: ~p~nAdding: ~p", [StartingCount, AddingCount]),

    %% 5. Empty the cache
    [router_device_cache:delete(router_device:id(D)) || D <- Devices],

    %% 6. Reconcile again
    ok = router_ics_skf_worker:reconcile(self(), true),
    ok = test_utils:wait_until(fun() -> not router_ics_skf_worker:is_reconciling() end, 50, 1000),

    %% 7. We have exactly the same number as we started with...
    ct:print("waiting 5 seconds before getting the list"),
    timer:sleep(timer:seconds(5)),
    {ok, Els2} = router_ics_skf_worker:list_skf(),
    EndingCount = erlang:length(Els2),

    %% 8. All the counts
    ct:print("Starting: ~p~nAdding: ~p~nRemoving: ~p", [StartingCount, AddingCount, EndingCount]),

    ok.

main_test(Config) ->
    meck:new(router_device_cache, [passthrough]),

    %% creating couple devices for testing
    Devices = lists:map(
        fun(X) ->
            ID = router_utils:uuid_v4(),
            router_device:update(
                [
                    %% Construct devaddrs with a prefix to text LE-BE conversion with config service.
                    {devaddrs, [<<X, 0, 0, 72>>]},
                    {keys, [{crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(16)}]}
                ],
                router_device:new(ID)
            )
        end,
        lists:seq(1, 2)
    ),

    %% Add a device without any devaddr or session, it should be filtered out
    meck:expect(router_device_cache, get, fun() ->
        lager:notice("router_device_cache:get()"),
        BadDevice = router_device:new(<<"bad_device">>),
        [BadDevice | Devices]
    end),

    %% Add a fake device to config service, as it is not in Router's cache it should get removed
    router_test_ics_skf_service:send_list(
        #iot_config_session_key_filter_v1_pb{
            oui = 0,
            devaddr = 0,
            session_key = []
        },
        true
    ),

    %% Check after reconcile, we should get the list and then 3 updates, (1 remove and 2 adds)
    [{Type3, Req3}, {Type2, Req2}, {Type1, Req1}, {Type0, _Req0}] = rcv_loop([]),
    [Device1, Device2] = Devices,

    ?assertEqual(list, Type0),
    ?assertEqual(update, Type1),
    ?assertEqual(remove, Req1#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = 0,
            devaddr = 0,
            %% Can be a binary, but empty string fields are lists
            session_key = []
        },
        Req1#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type2),
    ?assertEqual(add, Req2#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            %% Config service talks of devaddrs of BE
            devaddr = binary:decode_unsigned(binary:decode_hex(<<"48000001">>)),
            session_key = erlang:binary_to_list(binary:encode_hex(router_device:nwk_s_key(Device1)))
        },
        Req2#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type3),
    ?assertEqual(add, Req3#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            %% Config service talks of devaddrs of BE
            devaddr = binary:decode_unsigned(binary:decode_hex(<<"48000002">>)),
            session_key = erlang:binary_to_list(binary:encode_hex(router_device:nwk_s_key(Device2)))
        },
        Req3#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Join a device to test device_worker code, we should see 1 add
    #{
        stream := Stream1,
        pubkey_bin := PubKeyBin1
    } = test_utils:join_device(Config),

    [{Type4, Req4}] = rcv_loop([]),
    ?assertEqual(update, Type4),
    ?assertEqual(add, Req4#iot_config_session_key_filter_update_req_v1_pb.action),

    {ok, JoinedDevice1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    <<JoinedDevAddr1:32/integer-unsigned-big>> = lorawan_utils:reverse(
        router_device:devaddr(JoinedDevice1)
    ),

    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr1,
            session_key = erlang:binary_to_list(
                binary:encode_hex(router_device:nwk_s_key(JoinedDevice1))
            )
        },
        Req4#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Send first packet nothing should happen
    Stream1 !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin1,
                router_device:nwk_s_key(JoinedDevice1),
                router_device:app_s_key(JoinedDevice1),
                0
            )},

    [] = rcv_loop([]),

    %% Join device again
    #{
        stream := Stream2,
        pubkey_bin := PubKeyBin2
    } = test_utils:join_device(Config),

    [{Type6, Req6}] = rcv_loop([]),
    ?assertEqual(update, Type6),
    ?assertEqual(add, Req6#iot_config_session_key_filter_update_req_v1_pb.action),

    {ok, JoinedDevice2} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    <<JoinedDevAddr2:32/integer-unsigned-big>> = lorawan_utils:reverse(
        router_device:devaddr(JoinedDevice2)
    ),

    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr2,
            session_key = erlang:binary_to_list(
                binary:encode_hex(router_device:nwk_s_key(JoinedDevice2))
            )
        },
        Req6#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Send first packet again, we should see add and remove this time
    Stream2 !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin2,
                router_device:nwk_s_key(JoinedDevice1),
                router_device:app_s_key(JoinedDevice1),
                0
            )},

    [{Type7, Req7}, {Type8, Req8}] = rcv_loop([]),
    ?assertEqual(update, Type7),
    ?assertEqual(remove, Req7#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr2,
            session_key = erlang:binary_to_list(
                binary:encode_hex(router_device:nwk_s_key(JoinedDevice2))
            )
        },
        Req7#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type8),
    ?assertEqual(add, Req8#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = JoinedDevAddr1,
            session_key = erlang:binary_to_list(
                binary:encode_hex(router_device:nwk_s_key(JoinedDevice1))
            )
        },
        Req8#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Send packet 1 and nothing should happen
    Stream2 !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin2,
                router_device:nwk_s_key(JoinedDevice1),
                router_device:app_s_key(JoinedDevice1),
                1
            )},
    [] = rcv_loop([]),

    meck:unload(router_device_cache),
    ok.

reconcile_test(_Config) ->
    meck:new(router_device_cache, [passthrough]),

    %% Simulate server side processsing by telling the test service to wait
    %% before closing it's side of the stream after the client has signaled it
    %% is done sending updates.

    %% NOTE: Settting this value over the number of TimeoutAttempt will wait for
    %% a tream close will cause this test to fail, it will look like the worker
    %% has tried to reconcile again.
    ok = application:set_env(router, test_skf_update_eos_timeout, timer:seconds(2)),

    %% creating couple devices for testing
    Devices0 = lists:map(
        fun(X) ->
            ID = router_utils:uuid_v4(),
            router_device:update(
                [
                    %% Construct devaddrs with a prefix to text LE-BE conversion with config service.
                    {devaddrs, [<<X, 0, 0, 72>>]},
                    {keys, [{crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(16)}]}
                ],
                router_device:new(ID)
            )
        end,
        lists:seq(1, 2)
    ),

    %% Add a device without any devaddr or session, it should be filtered out
    meck:expect(router_device_cache, get, fun() ->
        lager:notice("router_device_cache:get()"),
        BadDevice = router_device:new(<<"bad_device">>),
        [BadDevice | Devices0]
    end),

    %% Add a fake device to config service, as it is not in Router's cache it should get removed
    router_test_ics_skf_service:send_list(
        #iot_config_session_key_filter_v1_pb{
            oui = 0,
            devaddr = 0,
            session_key = []
        },
        true
    ),

    %% Check after reconcile, we should get the list and then 3 updates, (1 remove and 2 adds)
    [{Type3, Req3}, {Type2, Req2}, {Type1, Req1}, {Type0, _Req0}] = rcv_loop([]),
    [Device1, Device2] = Devices0,

    ?assertEqual(list, Type0),
    ?assertEqual(update, Type1),
    ?assertEqual(remove, Req1#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = 0,
            devaddr = 0,
            %% Can be a binary, but empty string fields are lists
            session_key = []
        },
        Req1#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type2),
    ?assertEqual(add, Req2#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            %% Config service talks of devaddrs of BE
            devaddr = binary:decode_unsigned(binary:decode_hex(<<"48000001">>)),
            session_key = erlang:binary_to_list(binary:encode_hex(router_device:nwk_s_key(Device1)))
        },
        Req2#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type3),
    ?assertEqual(add, Req3#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            %% Config service talks of devaddrs of BE
            devaddr = binary:decode_unsigned(binary:decode_hex(<<"48000002">>)),
            session_key = erlang:binary_to_list(binary:encode_hex(router_device:nwk_s_key(Device2)))
        },
        Req3#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

    %% Add 20 more devices
    Devices1 = lists:map(
        fun(X) ->
            ID = router_utils:uuid_v4(),
            router_device:update(
                [
                    %% Construct devaddrs with a prefix to text LE-BE conversion with config service.
                    {devaddrs, [<<X, 0, 0, 72>>]},
                    {keys, [{crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(16)}]}
                ],
                router_device:new(ID)
            )
        end,
        lists:seq(1, 20)
    ),

    %% Add a device without any devaddr or session, it should be filtered out
    meck:expect(router_device_cache, get, fun() ->
        lager:notice("router_device_cache:get()"),
        BadDevice = router_device:new(<<"bad_device">>),
        [BadDevice | Devices1]
    end),

    ok = router_ics_skf_worker:reconcile(self(), true),

    router_test_ics_skf_service:send_list(
        #iot_config_session_key_filter_v1_pb{
            oui = 0,
            devaddr = 0,
            %% Can be a binary, but empty string fields are lists
            session_key = []
        },
        true
    ),

    ExpectedToAdd = lists:map(
        fun(Device) ->
            #iot_config_session_key_filter_v1_pb{
                oui = 1,
                %% Config service talks of devaddrs of BE
                devaddr = binary:decode_unsigned(
                    lorawan_utils:reverse(router_device:devaddr(Device))
                ),
                %% It is important that these are strings
                session_key = erlang:binary_to_list(
                    binary:encode_hex(router_device:nwk_s_key(Device))
                )
            }
        end,
        Devices1
    ),

    ExpectedToRemove = [
        #iot_config_session_key_filter_v1_pb{oui = 0, devaddr = 0, session_key = []}
    ],

    receive
        {router_ics_skf_worker, Result} ->
            %% We added 20 and removed 1

            ?assertEqual({ok, ExpectedToAdd, ExpectedToRemove}, Result)
    after 5000 ->
        ct:fail(timeout)
    end,

    meck:unload(router_device_cache),
    ok.

diff_against_local_test(_Config) ->
    %% if all devices in the cache are uploaded, the output of this function is nothing.
    ok = meck:new(router_device_cache, [passthrough]),

    AppKey = crypto:strong_rand_bytes(16),
    Devices = lists:map(
        fun(LtoI) ->
            router_device:update(
                [{devaddrs, [<<LtoI, 0, 0, 72>>]}, {keys, [{<<LtoI>>, AppKey}]}],
                router_device:new(<<LtoI>>)
            )
        end,
        lists:seq(1, 5)
    ),
    meck:expect(router_device_cache, get, fun() -> Devices end),

    SKFs = [
        #iot_config_session_key_filter_v1_pb{
            oui = 2,
            devaddr = erlang:list_to_integer("48000001", 16),
            session_key = "01"
        },
        #iot_config_session_key_filter_v1_pb{
            oui = 2,
            devaddr = erlang:list_to_integer("48000002", 16),
            session_key = "02"
        },
        #iot_config_session_key_filter_v1_pb{
            oui = 2,
            devaddr = erlang:list_to_integer("48000003", 16),
            session_key = "03"
        },
        #iot_config_session_key_filter_v1_pb{
            oui = 2,
            devaddr = erlang:list_to_integer("48000004", 16),
            session_key = "04"
        },
        #iot_config_session_key_filter_v1_pb{
            oui = 2,
            devaddr = erlang:list_to_integer("48000005", 16),
            session_key = "05"
        }
    ],

    ?assertEqual({[], []}, router_ics_skf_worker:local_skf_to_remote_diff(2, SKFs)),

    ok = meck:unload(router_device_cache),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

start_server(Port) ->
    _ = application:ensure_all_started(grpcbox),
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [iot_config_pb],
            services => #{
                'helium.iot_config.session_key_filter' => router_test_ics_skf_service
            }
        },
        listen_opts => #{port => Port, ip => {0, 0, 0, 0}}
    }),
    ServerPid.

rcv_loop(Acc) ->
    receive
        {router_test_ics_skf_service, Type, Req} ->
            lager:notice("got router_test_ics_skf_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.

load_keys(SwarmKey) ->
    case libp2p_crypto:load_keys(SwarmKey) of
        {ok, #{secret := PrivKey, public := PubKey}} ->
            {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)};
        {error, enoent} ->
            KeyMap =
                #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(
                    ecc_compact
                ),
            ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
            {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)}
    end.
