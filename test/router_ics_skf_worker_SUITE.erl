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
    reconcile_skf_test/1,
    reconcile_ignore_unfunded_orgs_test/1
]).

%% To test against a real config service...
%% SWARM_KEY :: absolute path to a key file.
%% ROUTE_ID  :: uuid of an existing route in the config service.
%% And update the grpcbox ics_channel entry in test.config.
-define(SWARM_KEY, undefined).
-define(ROUTE_ID, "test-route-id").

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
        reconcile_skf_test,
        reconcile_ignore_unfunded_orgs_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config0) ->
    ok = application:set_env(router, swarm_key, ?SWARM_KEY),
    ok = application:set_env(
        router,
        ics,
        #{
            skf_enabled => "true",
            route_id => ?ROUTE_ID,
            transport => http,
            host => "localhost",
            port => 8085
        },
        [{persistent, true}]
    ),
    ok = application:set_env(router, is_chain_dead, true),

    Config1 = test_utils:init_per_testcase(TestCase, [{is_chain_dead, true} | Config0]),
    Config2 = test_utils:add_oui(Config1),
    catch ok = meck:delete(router_device_devadddr, allocate, 2, false),
    Config2.

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

    One = #iot_config_skf_v1_pb{route_id = ?ROUTE_ID, devaddr = 0, session_key = "hex_key"},
    Two = #iot_config_skf_v1_pb{route_id = ?ROUTE_ID, devaddr = 1, session_key = "hex_key"},
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
        route_id = ?ROUTE_ID,
        devaddr = 0,
        session_key = [],
        max_copies = 42
    }),

    %% Trigger a reconcile
    Reconcile = router_ics_skf_worker:pre_reconcile(),
    ok = router_ics_skf_worker:reconcile(
        Reconcile,
        fun(Msg) -> ct:print("reconcile progress: ~p", [Msg]) end
    ),

    [D1, D2] = Devices,
    SKFs = [device_to_skf(?ROUTE_ID, D1), device_to_skf(?ROUTE_ID, D2)],
    {ok, Remote0} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(lists:sort(SKFs), lists:sort(Remote0)),

    %% Join a device to test device_worker code, we should see 1 add
    ct:print("joining 1"),
    #{stream := Stream1, pubkey_bin := PubKeyBin1} = test_utils:join_device(Config),
    {ok, JoinedDevice1} = router_device_cache:get(?CONSOLE_DEVICE_ID),
    JoinedSKF1 = device_to_skf(?ROUTE_ID, JoinedDevice1),

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
    JoinedSKF2 = device_to_skf(?ROUTE_ID, JoinedDevice2),

    ct:print("sending packet for devaddr lock in"),
    send_unconfirmed_uplink(Stream2, PubKeyBin2, JoinedDevice2),

    %% List to make sure old devaddr was removed, and new one was added
    {ok, Remote2} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(lists:sort([JoinedSKF2 | SKFs]), lists:sort(Remote2)),

    ok.

reconcile_multiple_updates_test(_Config) ->
    %% When more than 1 request needs to be made to the config service, we don't
    %% want to know until all have requests have succeeded or failed.
    ok = application:set_env(router, update_skf_batch_size, 10),

    %% Fill config service with filters to be removed.
    ok = router_test_ics_route_service:add_skf([
        #iot_config_skf_v1_pb{route_id = ?ROUTE_ID, devaddr = X, session_key = "key"}
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
    ok = meck:delete(router_device_devaddr, allocate, 2, false),
    ok = application:set_env(router, update_skf_batch_size, 100),

    %% Fill config service with filters to be removed.
    ok = router_test_ics_route_service:add_skf([
        #iot_config_skf_v1_pb{route_id = ?ROUTE_ID, devaddr = X, session_key = "key"}
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
    ok = meck:delete(router_device_devaddr, allocate, 2, false),
    ok = application:set_env(router, update_skf_batch_size, 100),

    %% Fill config service with filters to be removed.
    ok = router_test_ics_route_service:add_skf([
        #iot_config_skf_v1_pb{route_id = ?ROUTE_ID, devaddr = X, session_key = "key"}
     || X <- lists:seq(1, 100)
    ]),

    %% Fill the cache with devices that are not in the config service yet
    Devices = create_n_devices(50),

    meck:new(router_device_cache, [passthrough]),
    meck:expect(router_device_cache, get, fun() -> Devices end),

    Reconcile = router_ics_skf_worker:pre_reconcile(),
    ok = router_ics_skf_worker:reconcile(
        Reconcile,
        fun
            ({progress, {Curr, Total}, {error, {{Status, Message}, _Meta}}}) ->
                ct:print("~p/~p failed(~p): ~p", [
                    Curr, Total, Status, uri_string:percent_decode(Message)
                ]);
            ({progress, {Curr, Total}, {ok, _Resp}}) ->
                ct:print("~p/~p successful", [Curr, Total]);
            (Msg) ->
                ct:print("reconcile progress: ~p", [Msg])
        end
    ),

    Local = router_skf_reconcile:local(Reconcile),
    {ok, RemoteAfter} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(length(Local), length(RemoteAfter)),

    ok.

reconcile_ignore_unfunded_orgs_test(_Config) ->
    ok = meck:delete(router_device_devaddr, allocate, 2, false),

    Funded = create_n_devices(25, #{organization_id => <<"big balance org">>}),
    Unfunded = create_n_devices(25, #{organization_id => <<"no balance org">>}),

    meck:new(router_device_cache, [passthrough]),
    meck:expect(router_device_cache, get, fun() -> Funded ++ Unfunded end),

    ReconcileFun = fun
        ({progress, {Curr, Total}, {error, {{Status, Message}, _Meta}}}) ->
            ct:print("~p/~p failed(~p): ~p", [
                Curr, Total, Status, uri_string:percent_decode(Message)
            ]);
        ({progress, {Curr, Total}, {ok, _Resp}}) ->
            ct:print("~p/~p successful", [Curr, Total]);
        (Msg) ->
            ct:print("reconcile progress: ~p", [Msg])
    end,

    %% Websocket
    {ok, WSPid} = test_utils:ws_init(),

    %% First reconcile
    Reconcile0 = router_ics_skf_worker:pre_reconcile(),
    ok = router_ics_skf_worker:reconcile(Reconcile0, ReconcileFun),

    Local0 = router_skf_reconcile:local(Reconcile0),
    {ok, RemoteAfter0} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(length(Local0), length(RemoteAfter0)),

    ?assertEqual(50, length(Local0)),
    ?assertEqual(50, length(router_device_cache:get())),

    %% Reconcile after org has been marked unfunded
    WSPid ! {org_zero_dc, <<"no balance org">>},
    timer:sleep(10),

    Reconcile1 = router_ics_skf_worker:pre_reconcile(),
    ok = router_ics_skf_worker:reconcile(Reconcile1, ReconcileFun),

    Local1 = router_skf_reconcile:local(Reconcile1),
    {ok, RemoteAfter1} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(length(Local1), length(RemoteAfter1)),

    ?assertEqual(25, length(Local1)),
    ?assertEqual(50, length(router_device_cache:get())),

    %% And after being refunded
    WSPid ! {org_refill, <<"no balance org">>, 100},
    timer:sleep(10),

    Reconcile2 = router_ics_skf_worker:pre_reconcile(),
    ok = router_ics_skf_worker:reconcile(Reconcile2, ReconcileFun),

    Local2 = router_skf_reconcile:local(Reconcile2),
    {ok, RemoteAfter2} = router_ics_skf_worker:remote_skf(),
    ?assertEqual(length(Local2), length(RemoteAfter2)),

    ?assertEqual(50, length(Local2)),
    ?assertEqual(50, length(router_device_cache:get())),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

device_to_skf(RouteID, Device) ->
    #iot_config_skf_v1_pb{
        route_id = RouteID,
        devaddr = binary:decode_unsigned(router_device:devaddr(Device), little),
        session_key = erlang:binary_to_list(binary:encode_hex(router_device:nwk_s_key(Device))),
        max_copies = maps:get(multi_buy, router_device:metadata(Device), 999)
    }.

create_n_devices(N) ->
    create_n_devices(N, #{}).

create_n_devices(N, Metadata) ->
    lists:map(
        fun(Idx) ->
            ID = router_utils:uuid_v4(),
            {ok, Devaddr} = router_device_devaddr:allocate(no_device, undefined),
            router_device:update(
                [
                    {devaddrs, [Devaddr]},
                    {keys, [{crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(16)}]},
                    {metadata, Metadata#{multi_buy => Idx}}
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
