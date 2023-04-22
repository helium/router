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
    reconcile_dry_run_test/1,
    list_skf_test/1,
    diff_updates_test/1
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
        list_skf_test,
        main_test,
        reconcile_dry_run_test,
        diff_updates_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_skf_service, self()),
    ok = application:set_env(
        router,
        ics,
        #{
            skf_enabled => "true",
            route_id => "route_id",
            transport => http,
            host => "localhost",
            port => 8085
        },
        [{persistent, true}]
    ),
    ok = application:set_env(router, is_chain_dead, true),
    test_utils:init_per_testcase(TestCase, [{is_chain_dead, true} | Config]).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config),
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

list_skf_test(_Config) ->
    ?assertEqual({ok, []}, router_ics_skf_worker:list_skf()),

    One = #iot_config_skf_v1_pb{route_id = "route_id", devaddr = 0, session_key = "hex_key"},
    Two = #iot_config_skf_v1_pb{route_id = "route_id", devaddr = 1, session_key = "hex_key"},
    router_test_ics_route_service:add_skf([One, Two]),

    ?assertEqual({ok, [One, Two]}, router_ics_skf_worker:list_skf()),
    ok.

diff_updates_test(_Config) ->
    meck:new(router_device_cache, [passthrough]),

    %% Make sure there's nothing already in the config service
    ?assertEqual({ok, []}, router_ics_skf_worker:list_skf()),

    %% creating couple devices for testing
    Devices = create_n_devices(2),

    %% Add a device without any devaddr or session, it should be filtered out
    meck:expect(router_device_cache, get, fun() ->
        lager:notice("router_device_cache:get()"),
        BadDevice = router_device:new(<<"bad_device">>),
        [BadDevice | Devices]
    end),

    %% Fill the config service with devices we don't have to be removed during diff.
    Fake1 = #iot_config_skf_v1_pb{route_id = "route_id", devaddr = 0, session_key = "hex_key"},
    Fake2 = #iot_config_skf_v1_pb{route_id = "route_id", devaddr = 1, session_key = "hex_key"},
    router_test_ics_route_service:add_skf([Fake1, Fake2]),

    %% Start a diff
    {ok, Remote} = router_ics_skf_worker:list_skf(),
    ?assertEqual([Fake1, Fake2], Remote),
    {ToAdd, ToRemove} = router_ics_skf_worker:diff_skfs(Remote),

    %% Check list again, we should have the devices from above.
    %% Expecting 2 devices from above.
    %% Bad device from cache, and initially inserted devices should have been removed.
    [D1, D2] = Devices,
    D1_SKF = device_to_skf("route_id", D1),
    D2_SKF = device_to_skf("route_id", D2),

    ?assertEqual([D1_SKF, D2_SKF], lists:sort(ToAdd)),
    ?assertEqual([Fake1, Fake2], lists:sort(ToRemove)),

    meck:unload(router_device_cache),
    ok.

main_test(Config) ->
    meck:new(router_device_cache, [passthrough]),
    Devices = create_n_devices(2),

    %% Add a device withotu any devaddr or session, it should be filtered out
    meck:expect(router_device_cache, get, fun() ->
        lager:notice("router_device_cache:get()"),
        BadDevice = router_device:new(<<"bad_device">>),
        [BadDevice | Devices]
    end),

    %% Add a fake device to config service, as it is not in Router's cache, it should get removed
    ok = router_test_ics_route_service:add_skf(#iot_config_skf_v1_pb{
        route_id = "route_id",
        devaddr = 0,
        session_key = []
    }),

    %% Trigger a reconcile
    ok = router_ics_skf_worker:reconcile(commit),
    ok = test_utils:wait_until(fun() -> not router_ics_skf_worker:is_reconciling() end, 10, 1000),

    [D1, D2] = Devices,
    SKFs = [device_to_skf("route_id", D1), device_to_skf("route_id", D2)],
    {ok, Remote0} = router_ics_skf_worker:list_skf(),
    ?assertEqual(lists:sort(SKFs), lists:sort(Remote0)),

    %% Join a device to test device_worker code, we should see 1 add
    ct:print("joining 1"),
    #{stream := Stream1, pubkey_bin := PubKeyBin1} = test_utils:join_device(Config),
    {ok, JoinedDevice1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    JoinedSKF1 = device_to_skf("route_id", JoinedDevice1),

    %% List to make sure we have the new device
    {ok, Remote1} = router_ics_skf_worker:list_skf(),
    ?assertEqual(lists:sort([JoinedSKF1 | SKFs]), lists:sort(Remote1)),

    %% Send first so we can rejoin and get a new devaddr
    ct:print("sending packet for devaddr lock in"),
    send_unconfirmed_uplink(Stream1, PubKeyBin1, JoinedDevice1),


    %% Join device again
    ct:print("joining 2"),
    #{stream := Stream2, pubkey_bin := PubKeyBin2} = test_utils:join_device(Config),
    {ok, JoinedDevice2} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    JoinedSKF2 = device_to_skf("route_id", JoinedDevice2),

    ct:print("sending packet for devaddr lock in"),
    send_unconfirmed_uplink(Stream2, PubKeyBin2, JoinedDevice2),

    %% List to make sure old devaddr was removed, and new one was added
    {ok, Remote2} = router_ics_skf_worker:list_skf(),
    ?assertEqual(lists:sort([JoinedSKF2 | SKFs]), lists:sort(Remote2)),

    ok.

reconcile_dry_run_test(_Config) ->
    meck:new(router_device_cache, [passthrough]),
    Devices = create_n_devices(2),

    meck:expect(router_device_cache, get, fun() -> Devices end),

    ?assertEqual({ok, []}, router_ics_skf_worker:list_skf()),

    ok = router_ics_skf_worker:reconcile(dry_run),
    ok = test_utils:wait_until(fun() -> not router_ics_skf_worker:is_reconciling() end, 10, 1000),

    ?assertEqual({ok, []}, router_ics_skf_worker:list_skf()),

    ok =
        receive
            {router_ics_skf_worker, {ok, Added, Removed}} ->
                ?assertEqual(2, erlang:length(Added)),
                ?assertEqual(0, erlang:length(Removed)),
                ok
        after 1250 -> nothing_received
        end,

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

device_to_skf(RouteID, Device) ->
    #iot_config_skf_v1_pb{
        route_id = RouteID,
        devaddr = binary:decode_unsigned(router_device:devaddr(Device), little),
        session_key = erlang:binary_to_list(binary:encode_hex(router_device:nwk_s_key(Device)))
    }.

create_n_devices(N) ->
    lists:map(
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
        lists:seq(1, N)
    ).

send_unconfirmed_uplink(Stream, PubKeyBin, Device)->
    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device),
                router_device:app_s_key(Device),
                0
            )},
    ok = timer:sleep(router_utils:frame_timeout()).
