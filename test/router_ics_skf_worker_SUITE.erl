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
    reconcile_multiple_updates_test/1,
    list_skf_test/1,
    remove_all_skf_test/1,
    reconcile_skf_test/1
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
        reconcile_multiple_updates_test,
        remove_all_skf_test,
        reconcile_skf_test
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
    ?assertEqual({ok, []}, router_ics_skf_worker:remote_skf()),

    One = #iot_config_skf_v1_pb{route_id = "route_id", devaddr = 0, session_key = "hex_key"},
    Two = #iot_config_skf_v1_pb{route_id = "route_id", devaddr = 1, session_key = "hex_key"},
    router_test_ics_route_service:add_skf([One, Two]),

    ?assertEqual({ok, [One, Two]}, router_ics_skf_worker:remote_skf()),
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
    Reconcile = router_ics_skf_worker:pre_reconcile(),
    ok = router_ics_skf_worker:reconcile(
        Reconcile,
        fun(Msg) -> ct:print("reconcile progress: ~p", [Msg]) end
    ),

    [D1, D2] = Devices,
    SKFs = [device_to_skf("route_id", D1), device_to_skf("route_id", D2)],
    {ok, Remote0} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(lists:sort(SKFs), lists:sort(Remote0)),

    %% Join a device to test device_worker code, we should see 1 add
    ct:print("joining 1"),
    #{stream := Stream1, pubkey_bin := PubKeyBin1} = test_utils:join_device(Config),
    {ok, JoinedDevice1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    JoinedSKF1 = device_to_skf("route_id", JoinedDevice1),

    %% List to make sure we have the new device
    {ok, Remote1} = router_ics_skf_worker:remote_skf(),
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
    {ok, Remote2} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(lists:sort([JoinedSKF2 | SKFs]), lists:sort(Remote2)),

    ok.

reconcile_multiple_updates_test(_Config) ->
    %% When more than 1 request needs to be made to the config service, we don't
    %% know want to know until all have requests have succeeded or failed.

    ok = application:set_env(router, test_udpate_skf_delay_ms, 500),
    ok = router_ics_skf_worker:set_update_batch_size(10),

    %% Fill config service with filters to be removed.
    ok = router_test_ics_route_service:add_skf([
        #iot_config_skf_v1_pb{route_id = "route_id", devaddr = X, session_key = "key"}
     || X <- lists:seq(1, 100)
    ]),

    meck:new(router_ics_skf_worker, [passthrough]),

    Reconcile = router_ics_skf_worker:pre_reconcile(),
    ok = router_ics_skf_worker:reconcile(Reconcile, fun(_) -> ok end),

    ?assertEqual({ok, []}, router_ics_skf_worker:remote_skf()),

    ?assert(meck:num_calls(router_ics_skf_worker, send_request, '_') > 1),
    meck:unload(router_ics_skf_worker),

    ok.

remove_all_skf_test(_Config) ->
    %% ok = application:set_env(router, test_udpate_skf_delay_ms, 500),
    ok = application:set_env(router, update_skf_batch_size, 10),

    %% Fill config service with filters to be removed.
    ok = router_test_ics_route_service:add_skf([
        #iot_config_skf_v1_pb{route_id = "route_id", devaddr = X, session_key = "key"}
     || X <- lists:seq(1, 100)
    ]),

    RemoveAll = router_ics_skf_worker:pre_remove_all(),
    ok = router_ics_skf_worker:remove_all(
        RemoveAll,
        fun(Msg) -> ct:print("remove all progress: ~p", [Msg]) end
    ),

    ?assertEqual({ok, []}, router_ics_skf_worker:remote_skf()),

    ok.

reconcile_skf_test(_Config) ->
    %% ok = application:set_env(router, test_udpate_skf_delay_ms, 500),
    ok = router_ics_skf_worker:set_update_batch_size(10),

    %% Fill config service with filters to be removed.
    ok = router_test_ics_route_service:add_skf([
        #iot_config_skf_v1_pb{route_id = "route_id", devaddr = X, session_key = "key"}
     || X <- lists:seq(1, 100)
    ]),

    %% Fill the cache with devices that are not in the config service yet
    meck:new(router_device_cache, [passthrough]),
    meck:expect(router_device_cache, get, fun() -> create_n_devices(25) end),

    %% Get Remote and Local
    {ok, Remote} = router_ics_skf_worker:remote_skf(),
    {ok, Local} = router_ics_skf_worker:local_skf(),
    %% Diff
    Diff = router_ics_skf_worker:diff(#{remote => Remote, local => Local}),
    %% Chunk into requests
    Requests = router_ics_skf_worker:chunk(Diff),
    Total = erlang:length(Requests),

    ct:print(
        "~p remote~n~p local~n~p updates~n~p requests",
        [erlang:length(Remote), erlang:length(Local), erlang:length(Diff), Total]
    ),

    lists:foreach(
        fun({Idx, Chunk}) ->
            Resp = router_ics_skf_worker:send_request(Chunk),
            ct:print("~p/~p :: ~p", [Idx, Total, Resp])
        end,
        router_utils:enumerate_1(Requests)
    ),

    {ok, RemoteAfter} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(lists:sort(Local), lists:sort(RemoteAfter)),

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

send_unconfirmed_uplink(Stream, PubKeyBin, Device) ->
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
