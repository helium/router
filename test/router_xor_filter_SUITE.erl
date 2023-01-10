-module(router_xor_filter_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    publish_xor_test/1,
    max_filters_devices_test/1,
    ignore_largest_filter_test/1,
    migrate_filter_test/1,
    move_to_front_test/1,
    evenly_rebalance_filter_test/1,
    oddly_rebalance_filter_test/1,
    remove_devices_filter_test/1,
    remove_devices_filter_after_restart_test/1,
    report_device_status_test/1,
    remove_devices_single_txn_db_test/1,
    remove_devices_multiple_txn_db_test/1,
    send_updates_to_console_test/1,
    between_worker_device_add_remove_send_updates_to_console_test/1,
    device_add_multiple_send_updates_to_console_test/1,
    device_add_unique_and_matching_send_updates_to_console_test/1,
    device_removed_send_updates_to_console_test/1,
    estimate_cost_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").

-define(HASH_FUN, fun xxhash:hash64/1).
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
        publish_xor_test,
        max_filters_devices_test,
        ignore_largest_filter_test,
        migrate_filter_test,
        move_to_front_test,
        evenly_rebalance_filter_test,
        oddly_rebalance_filter_test,
        remove_devices_filter_test,
        remove_devices_filter_after_restart_test,
        report_device_status_test,
        remove_devices_single_txn_db_test,
        remove_devices_multiple_txn_db_test,
        send_updates_to_console_test,
        between_worker_device_add_remove_send_updates_to_console_test,
        device_add_multiple_send_updates_to_console_test,
        device_add_unique_and_matching_send_updates_to_console_test,
        device_removed_send_updates_to_console_test,
        estimate_cost_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config0) ->
    application:set_env(router, router_xor_filter_worker, false),
    Config = test_utils:init_per_testcase(TestCase, Config0),
    ConsensusMembers = proplists:get_value(consensus_member, Config),

    meck:new(blockchain_worker, [passthrough, no_history]),
    meck:expect(blockchain_worker, submit_txn, fun(Txn, Callback) ->
        case blockchain_test_utils:create_block(ConsensusMembers, [Txn]) of
            {error, _Reason} = Error ->
                Callback(Error);
            {ok, Block} ->
                _ = blockchain_test_utils:add_block(
                    Block,
                    self(),
                    blockchain_swarm:tid()
                ),
                Callback(ok)
        end,
        ok
    end),

    Config2 = test_utils:add_oui(Config),

    Config2.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
publish_xor_test(Config) ->
    %% Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),

    %% init worker processing first filter
    application:set_env(router, router_xor_filter_worker, true),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% OUI with blank filter should be pushed a new filter to the chain
    ok = expect_block(3),

    DeviceUpdates = [
        {dev_eui, ?DEVEUI},
        {app_eui, ?APPEUI}
    ],
    Device = router_device:update(DeviceUpdates, router_device:new(<<"ID2">>)),
    DeviceDevEuiAppEui = router_xor_filter_worker:deveui_appeui(Device),

    BaseEmpty = maps:from_list([{X, []} || X <- lists:seq(0, 4)]),

    ?assertEqual(#{}, get_pending_txns()),
    ?assertEqual(
        maps:merge(BaseEmpty, #{
            1 => [
                #{
                    eui => DeviceDevEuiAppEui,
                    filter_index => 1,
                    device_id => ?CONSOLE_DEVICE_ID
                }
            ]
        }),
        get_filter_to_devices()
    ),

    Filters = get_filters(OUI1),
    ?assertEqual(2, erlang:length(Filters)),

    [Filter1, Filter2] = Filters,
    ?assertNot(xor16:contain({Filter1, ?HASH_FUN}, DeviceDevEuiAppEui)),
    ?assert(xor16:contain({Filter2, ?HASH_FUN}, DeviceDevEuiAppEui)),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

max_filters_devices_test(Config) ->
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    Round1Devices = n_rand_devices(10),
    Round2Devices = n_rand_devices(10) ++ Round1Devices,
    Round3Devices = n_rand_devices(10) ++ Round2Devices,
    Round4Devices = n_rand_devices(10) ++ Round3Devices,
    Round5Devices = n_rand_devices(10) ++ Round4Devices,

    %% Init worker without processing first filter automatically
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            %% We should not craft filters above 5
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

ignore_largest_filter_test(Config) ->
    %% If we have one really big filter, we should not update it when more
    %% devices come through
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker without processing first filter automatically
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------

    Round1Devices = n_rand_devices(10),
    Round2Devices = n_rand_devices(200) ++ Round1Devices,
    Round3Devices = n_rand_devices(14) ++ Round2Devices,
    Round4Devices = n_rand_devices(16) ++ Round3Devices,
    Round5Devices = n_rand_devices(18) ++ Round4Devices,

    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            %% largest filter
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    [One, Two, Three, Four, Five] = Filters = get_filters(OUI1),
    ExpectedOrder = [Two, Four, Five, One, Three],

    %% ct:print("Sizes: ~n~p~n", [router_xor_filter_worker:report_filter_sizes()]),
    %% Order: One   - 18 device
    %%        Two   - 10 devices
    %%        Three - 200 devices
    %%        Four  - 14 devices
    %%        Five  - 16 devices
    ?assertEqual(
        sort_binaries_by_size(Filters),
        ExpectedOrder,
        lists:flatten(
            io_lib:format("Expected ~w got ~w", [
                bin_sizes(ExpectedOrder),
                bin_sizes(sort_binaries_by_size(Filters))
            ])
        )
    ),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

migrate_filter_test(Config) ->
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(5),
    Round2Devices = Round1Devices ++ n_rand_devices(5),
    Round3Devices = Round2Devices ++ n_rand_devices(5),
    Round4Devices = Round3Devices ++ n_rand_devices(5),
    Round5Devices = Round4Devices ++ n_rand_devices(5),

    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    %% Order: Zero  - 0 device
    %%        One   - 5 devices
    %%        Two   - 5 devices
    %%        Three - 5 devices
    %%        Four  - 10 devices
    FilterToDevices0 = get_filter_to_devices(),
    ?assertEqual(5, erlang:length(maps:get(0, FilterToDevices0))),
    ?assertEqual(5, erlang:length(maps:get(1, FilterToDevices0))),
    ?assertEqual(5, erlang:length(maps:get(2, FilterToDevices0))),
    ?assertEqual(5, erlang:length(maps:get(3, FilterToDevices0))),
    ?assertEqual(5, erlang:length(maps:get(4, FilterToDevices0))),

    %% Migrate Four to Zero
    %% Order: Zero  - 10 devices
    %%        One   - 5 devices
    %%        Two   - 5 devices
    %%        Three - 5 devices
    %%        Four  - 0 devices
    {ok, _, _, _} = router_xor_filter_worker:migrate_filter(_From0 = 4, _To0 = 0, _Commit0 = true),
    %% migration should be two blocks, 1 (block 8) for new big filter, 1 (block 9) for empty filter
    ok = expect_block(9),
    FilterToDevices1 = get_filter_to_devices(),
    ?assertEqual(10, erlang:length(maps:get(0, FilterToDevices1))),
    ?assertEqual(5, erlang:length(maps:get(1, FilterToDevices1))),
    ?assertEqual(5, erlang:length(maps:get(2, FilterToDevices1))),
    ?assertEqual(5, erlang:length(maps:get(3, FilterToDevices1))),
    ?assertEqual(0, erlang:length(maps:get(4, FilterToDevices1))),

    %% Migrate Three to Zero
    %% Order: Zero  - 15 devices
    %%        One   - 5 devices
    %%        Two   - 5 devices
    %%        Three - 0 devices
    %%        Four  - 0 devices
    {ok, _, _, _} = router_xor_filter_worker:migrate_filter(_From1 = 3, _To1 = 0, _Commit1 = true),
    %% migration should be two blocks, 1 (block 10) for new big filter, 1 (block 11) for empty filter
    ok = expect_block(11),

    FilterToDevices2 = get_filter_to_devices(),
    ?assertEqual(15, erlang:length(maps:get(0, FilterToDevices2))),
    ?assertEqual(5, erlang:length(maps:get(1, FilterToDevices2))),
    ?assertEqual(5, erlang:length(maps:get(2, FilterToDevices2))),
    ?assertEqual(0, erlang:length(maps:get(3, FilterToDevices2))),
    ?assertEqual(0, erlang:length(maps:get(4, FilterToDevices2))),

    %% Make sure migrated filters are empty
    AllDevices = Round5Devices,
    [_Zero, _One, _Two, Three, Four] = get_filters(OUI1),
    ?assertEqual(
        [false],
        lists:usort([
            xor16:contain(
                {Three, fun xxhash:hash64/1},
                router_xor_filter_worker:deveui_appeui(Device)
            )
         || Device <- AllDevices
        ]),
        "No devices in filter Three"
    ),
    ?assertEqual(
        [false],
        lists:usort([
            xor16:contain(
                {Four, fun xxhash:hash64/1},
                router_xor_filter_worker:deveui_appeui(Device)
            )
         || Device <- AllDevices
        ]),
        "No devices in filter Four"
    ),

    %% Next round of devices should go into the empty filters
    Round6Devices = Round5Devices ++ n_rand_devices(3),
    true = ets:insert(Tab, {devices, Round6Devices}),
    ok = router_xor_filter_worker:check_filters(),
    ok = expect_block(12),

    FilterToDevices3 = get_filter_to_devices(),
    ?assertEqual(15, erlang:length(maps:get(0, FilterToDevices3))),
    ?assertEqual(5, erlang:length(maps:get(1, FilterToDevices3))),
    ?assertEqual(5, erlang:length(maps:get(2, FilterToDevices3))),
    ?assertEqual(0, erlang:length(maps:get(3, FilterToDevices3))),
    ?assertEqual(3, erlang:length(maps:get(4, FilterToDevices3))),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

move_to_front_test(Config) ->
    %% When filters get large, they are expensive to add single devices to,
    %% instead of manually creating migrations, we can say across what number of
    %% filters we want to distribute the devices we know about.
    %% -------
    %% > router_xor_filter_worker:move_to_front(_NumGroups = 2, _Commit = true).
    %% 0 - long term storage
    %% 1 - long term storage
    %% 2 - cheap adding devices
    %% 3 - cheap adding devices
    %% 4 - cheap adding devices
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    Round2Devices = Round1Devices ++ n_rand_devices(200),
    Round3Devices = Round2Devices ++ n_rand_devices(30),
    Round4Devices = Round3Devices ++ n_rand_devices(6),
    Round5Devices = Round4Devices ++ n_rand_devices(50),

    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            %% largest filter
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            %% We should not craft filters above 5
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    %% ct:print("~nBefore Sizes: ~n~w~n", [router_xor_filter_worker:report_filter_sizes()]),
    %% Order: One   - 50 device
    %%        Two   - 10 devices
    %%        Three - 200 devices
    %%        Four  - 30 devices
    %%        Five  - 6 devices
    [One, Two, Three, Four, Five] = Filters1 = get_filters(OUI1),
    ?assertEqual(sort_binaries_by_size(Filters1), [Five, Two, Four, One, Three]),

    {ok, _Old, _New, _Costs} = router_xor_filter_worker:move_to_front(
        _NumGroups = 2,
        _Commit = true
    ),

    %% Wait until filters are committed
    %% Next filter would be 8
    %% Plus updating other filters (+4)
    %% Expecting 8 + 4 == 12
    ok = expect_block(12),

    %% ct:print("~nAfter Sizes: ~n~w~n", [router_xor_filter_worker:report_filter_sizes()]),
    %% Order: One   - 148 devices
    %%        Two   - 148 devices
    %%        Three - 0 devices
    %%        Four  - 0 devices
    %%        Five  - 0 devices

    FilterToDevices = get_filter_to_devices(),
    ?assertEqual(148, erlang:length(maps:get(0, FilterToDevices))),
    ?assertEqual(148, erlang:length(maps:get(1, FilterToDevices))),
    ?assertEqual(0, erlang:length(maps:get(2, FilterToDevices))),
    ?assertEqual(0, erlang:length(maps:get(3, FilterToDevices))),
    ?assertEqual(0, erlang:length(maps:get(4, FilterToDevices))),

    Filters2 = get_filters(OUI1),
    [OneSize, TwoSize, ThreeSize, FourSize, FiveSize] = bin_sizes(Filters2),
    ?assertEqual(OneSize, TwoSize),
    ?assertEqual(ThreeSize, FourSize),
    ?assertEqual(ThreeSize, FiveSize),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

evenly_rebalance_filter_test(Config) ->
    %% If we have one really big filter, we should not update it when more
    %% devices come through
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    Round2Devices = Round1Devices ++ n_rand_devices(200),
    Round3Devices = Round2Devices ++ n_rand_devices(30),
    Round4Devices = Round3Devices ++ n_rand_devices(5),
    Round5Devices = Round4Devices ++ n_rand_devices(50),

    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            %% largest filter
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            %% We should not craft filters above 5
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    %% ct:print("~nBefore Sizes: ~n~w~n", [router_xor_filter_worker:report_filter_sizes()]),
    %% Order: One   - 50 device
    %%        Two   - 10 devices
    %%        Three - 200 devices
    %%        Four  - 30 devices
    %%        Five  - 5 devices
    [One, Two, Three, Four, Five] = Filters1 = get_filters(OUI1),
    ?assertEqual(sort_binaries_by_size(Filters1), [Five, Two, Four, One, Three]),

    ok = router_xor_filter_worker:rebalance_filters(),

    %% Wait until filters are committed
    %% Next filter would be 8
    %% Plus updating other filters (+4)
    %% Expecting 8 + 4 == 12
    ok = expect_block(12),

    %% ct:print("~nAfter Sizes: ~n~w~n", [router_xor_filter_worker:report_filter_sizes()]),
    %% Order: One   - 59 devices
    %%        Two   - 59 devices
    %%        Three - 59 devices
    %%        Four  - 59 devices
    %%        Five  - 59 devices
    Filters2 = get_filters(OUI1),
    Sizes = bin_sizes(Filters2),
    Diff = lists:max(Sizes) - lists:min(Sizes),
    ?assertEqual(0, Diff, "Devices should be disbtributed evenly"),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

oddly_rebalance_filter_test(Config) ->
    %% If we have one really big filter, we should not update it when more
    %% devices come through
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(15),
    Round2Devices = Round1Devices ++ n_rand_devices(211),
    Round3Devices = Round2Devices ++ n_rand_devices(37),
    Round4Devices = Round3Devices ++ n_rand_devices(47),
    Round5Devices = Round4Devices ++ n_rand_devices(59),

    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            %% largest filter
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            %% We should not craft filters above 5
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    Allowance = 10,

    %% Order: One   - 59 device
    %%        Two   - 15 devices
    %%        Three - 211 devices
    %%        Four  - 37 devices
    %%        Five  - 47 devices
    %% Total: 15 + 211 + 37 + 47 + 59 == 369
    Filters1 = get_filters(OUI1),
    Sizes1 = bin_sizes(Filters1),
    %% ct:print("~nBefore Sizes: ~n~p~n", [router_xor_filter_worker:report_filter_sizes()]),
    Diff1 = lists:max(Sizes1) - lists:min(Sizes1),
    ?assert(
        Diff1 > Allowance,
        lists:flatten(
            io_lib:format("vastly uneven filters [diff: ~p] > [allowance: ~p]", [
                Diff1,
                Allowance
            ])
        )
    ),

    ok = router_xor_filter_worker:rebalance_filters(),

    %% Wait until filters are committed
    %% Next filter would be 8
    %% Plus updating other filters (+4)
    %% Expecting 8 + 4 == 12
    ok = expect_block(12),

    %% Total: 0 + 15 + 211 + 37 + 47 + 59 == 369
    %% Distributed: 369/5 == 73.8
    %% Order: One   - 73 devices
    %%        Two   - 74 devices
    %%        Three - 74 devices
    %%        Four  - 74 devices
    %%        Five  - 74 devices
    Filters2 = get_filters(OUI1),
    Sizes2 = bin_sizes(Filters2),
    %% ct:print("~nAfter Sizes: ~n~p~n", [router_xor_filter_worker:report_filter_sizes()]),
    Diff2 = lists:max(Sizes2) - lists:min(Sizes2),
    ?assert(Diff2 =< Allowance, "Devices should be disbtributed closely"),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

remove_devices_filter_test(Config) ->
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    %% Filters are 0-indexed
    %% Filter 0 is empty and mostly ignored until rebalancing
    % filter 1
    Round1Devices = n_rand_devices(10),
    % filter 2
    Round2Devices = n_rand_devices(20) ++ Round1Devices,
    % filter 3
    Round3Devices = n_rand_devices(3) ++ Round2Devices,
    % filter 4
    Round4Devices = n_rand_devices(4) ++ Round3Devices,
    % filter 3(?)
    Round5Devices = n_rand_devices(5) ++ Round4Devices,

    Fitlers0 = get_filters(OUI1),
    ?assertEqual(1, erlang:length(Fitlers0)),

    %% Add devices
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            %% Ensure we aren't starting farther ahead than we expect
            ok = expect_block(ExpectedBlock - 1),

            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            %% largest filter
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            %% We should not craft filters above 5
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    %% Choose devices to be removed
    %% Not random devices so we can know how many filters should be updated
    Removed = lists:sublist(Round4Devices, 2),
    LeftoverDevices = Round5Devices -- Removed,

    %% Check filters with devices that continue to exist
    true = ets:insert(Tab, {devices, LeftoverDevices}),
    ok = router_xor_filter_worker:check_filters(),

    %% make sure no txns are about to go through.
    ?assertEqual(0, maps:size(get_pending_txns())),

    %% NOTE: not submitting txns for filters when only removing
    %% %% Should commit filter for removed devices
    %% ok = expect_block(8, Chain),
    %% %% Make sure removed devices are not in those filters
    %% Filters = get_filters(Chain, OUI1),
    %% Containment = [
    %%     xor16:contain({Filter, fun xxhash:hash64/1}, router_xor_filter_worker:deveui_appeui(Device))
    %%     || Filter <- Filters, Device <- Removed
    %% ],
    %% ?assertEqual(
    %%     false,
    %%     lists:member(true, Containment),
    %%     "Removed devices are _NOT_ in filters"
    %% ),
    Devices = lists:flatten(maps:values(get_filter_to_devices())),
    ?assertEqual(
        [false, false],
        [lists:member(RemovedDevice, Devices) || RemovedDevice <- Removed],
        "Removed devices are _NOT_ in worker cache"
    ),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

remove_devices_filter_after_restart_test(Config) ->
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    Round2Devices = n_rand_devices(200) ++ Round1Devices,
    Round3Devices = n_rand_devices(35) ++ Round2Devices,
    Round4Devices = n_rand_devices(45) ++ Round3Devices,
    Round5Devices = n_rand_devices(50) ++ Round4Devices,

    %% Add devices
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            %% largest filter
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            %% We should not craft filters above 5
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    %% Choose devices to be removed
    %% Not random devices so we can know how many filters should be updated
    Removed = lists:sublist(Round4Devices, 10),
    LeftoverDevices = Round5Devices -- Removed,

    %% Make sure removed devices are not in those filters
    Filters1 = get_filters(OUI1),
    Containment1 = [
        xor16:contain(
            {Filter, fun xxhash:hash64/1},
            router_xor_filter_worker:deveui_appeui(Device)
        )
     || Filter <- Filters1, Device <- Removed
    ],
    ?assertEqual(
        true,
        lists:member(true, Containment1),
        "Removed devices _ARE_ in filters"
    ),

    %% Restart the xor filter worker
    exit(whereis(router_xor_filter_worker), kill),

    %% make sure worker died
    ok = test_utils:wait_until(fun() ->
        case whereis(router_xor_filter_worker) of
            undefined -> true;
            Pid -> not erlang:is_process_alive(Pid)
        end
    end),

    %% wait for worker to raise from the dead
    timer:sleep(timer:seconds(1)),
    ok = test_utils:wait_until(fun() ->
        case whereis(router_xor_filter_worker) of
            undefined -> false;
            P -> erlang:is_process_alive(P)
        end
    end),

    %% Check filters with devices that continue to exist
    true = ets:insert(Tab, {devices, LeftoverDevices}),
    ok = router_xor_filter_worker:check_filters(),

    %% %% Should commit filter for removed devices
    %% ok = expect_block(8, Chain),

    %% %% Make sure removed devices are not in those filters
    %% Filters2 = get_filters(Chain, OUI1),
    %% Containment2 = [
    %%     xor16:contain(
    %%         {Filter, fun xxhash:hash64/1},
    %%         router_xor_filter_worker:deveui_appeui(Device)
    %%     )
    %%     || Filter <- Filters2, Device <- Removed
    %% ],
    %% ?assertEqual(
    %%     false,
    %%     lists:member(true, Containment2),
    %%     "Removed devices are _NOT_ in filters"
    %% ),
    Devices1 = lists:flatten(maps:values(get_filter_to_devices())),
    ?assertEqual(
        [false],
        lists:usort([lists:member(RemovedDevice, Devices1) || RemovedDevice <- Removed]),
        "Removed devices are _NOT_ in worker cache"
    ),

    %% Refresh the cache to make sure we don't have anything lying around
    ok = router_xor_filter_worker:refresh_cache(),

    Devices2 = lists:flatten(maps:values(get_filter_to_devices())),
    ?assertEqual(
        length(LeftoverDevices),
        length(Devices2),
        "Known devices are same amount as cache devices"
    ),
    ?assertNotEqual(Devices1, Devices2),
    ?assertEqual(
        [false],
        lists:usort([lists:member(RemovedDevice, Devices2) || RemovedDevice <- Removed]),
        "Removed devices are _NOT_ in worker cache after another restart"
    ),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

report_device_status_test(Config) ->
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    Round2Devices = n_rand_devices(20) ++ Round1Devices,
    Round3Devices = n_rand_devices(30) ++ Round2Devices,
    Round4Devices = n_rand_devices(40) ++ Round3Devices,
    Round5Devices = n_rand_devices(50) ++ Round4Devices,

    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            #{devices => Round5Devices, block => 7, filter_count => 5}
        ]
    ),

    One = erlang:hd(Round1Devices),
    Two = erlang:hd(Round2Devices),
    Three = erlang:hd(Round3Devices),
    Four = erlang:hd(Round4Devices),
    Five = erlang:hd(Round5Devices),

    %% NOTE: You would think the first device would be in the 0th filter, but
    %% because of the way we want to have as many filters as possible, we ignore
    %% the first filter until we come around with more devices after creating
    %% all we can create.
    %% Because of that, all devices are pushed 1 more filter than we expect.
    OneExpectedReport = [{0, false}, {1, true}, {2, false}, {3, false}, {4, false}],
    TwoExpectedReport = [{0, false}, {1, false}, {2, true}, {3, false}, {4, false}],
    ThreeExpectedReport = [{0, false}, {1, false}, {2, false}, {3, true}, {4, false}],
    FourExpectedReport = [{0, false}, {1, false}, {2, false}, {3, false}, {4, true}],
    %% All filters are considered after room is taken
    FiveExpectedReport = [{0, true}, {1, false}, {2, false}, {3, false}, {4, false}],

    %% NOTE: Remember filters are 0-indexed
    ?assertEqual(
        [{routing, OneExpectedReport}, {in_memory, OneExpectedReport}],
        router_xor_filter_worker:report_device_status(One),
        "First device should be written to filter 1"
    ),
    ?assertEqual(
        [{routing, TwoExpectedReport}, {in_memory, TwoExpectedReport}],
        router_xor_filter_worker:report_device_status(Two),
        "Second device should be written to filter 2"
    ),
    ?assertEqual(
        [{routing, ThreeExpectedReport}, {in_memory, ThreeExpectedReport}],
        router_xor_filter_worker:report_device_status(Three),
        "Third device should be written to filter 3"
    ),
    ?assertEqual(
        [{routing, FourExpectedReport}, {in_memory, FourExpectedReport}],
        router_xor_filter_worker:report_device_status(Four),
        "Fourth device should be written to filter 4"
    ),
    ?assertEqual(
        [{routing, FiveExpectedReport}, {in_memory, FiveExpectedReport}],
        router_xor_filter_worker:report_device_status(Five),
        "Fifth device should be written to filter 0 (smallest filter)"
    ),

    %% NOTE: If filter selection is rewritten to consider filter size rather
    %% than known occupation, this test will need update

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

remove_devices_single_txn_db_test(Config) ->
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    Round1DevicesEUI = [router_xor_filter_worker:deveui_appeui(Device) || Device <- Round1Devices],

    Fitlers0 = get_filters(OUI1),
    ?assertEqual(1, erlang:length(Fitlers0)),

    %% Add devices
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            %% Removing all devices
            %% Don't inc expected block, not writing to chain for removals.
            #{devices => [], block => 3, filter_count => 2}
        ]
    ),

    %% Make sure removed devices are not in those filters
    %% Filters = get_filters(Chain, OUI1),
    %% Containment = [
    %%     xor16:contain({Filter, fun xxhash:hash64/1}, Device)
    %%     || Filter <- Filters, Device <- Round1DevicesEUI
    %% ],
    %% ?assertEqual(
    %%     [false],
    %%     lists:usort(Containment),
    %%     "Removed devices are _NOT_ in filters"
    %% ),
    Devices0 = lists:flatten(maps:values(get_filter_to_devices())),
    ?assertEqual(
        [false],
        lists:usort([lists:member(RemovedDevice, Devices0) || RemovedDevice <- Round1DevicesEUI]),
        "Removed devices are _NOT_ in worker cache"
    ),
    %% Refresh to make sure they don't load from the db
    router_xor_filter_worker:refresh_cache(),
    Devices1 = lists:flatten(maps:values(get_filter_to_devices())),
    Membership = [lists:member(RemovedDevice, Devices1) || RemovedDevice <- Round1DevicesEUI],
    ?assertEqual(
        [false],
        lists:usort(Membership),
        "Removed devices are _NOT_ in worker cache after refresh"
    ),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

remove_devices_multiple_txn_db_test(Config) ->
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    Round2Devices = n_rand_devices(20) ++ Round1Devices,
    Round3Devices = n_rand_devices(30) ++ Round2Devices,
    Round4Devices = n_rand_devices(40) ++ Round3Devices,
    Round5Devices = n_rand_devices(50) ++ Round4Devices,
    DeviceEUIs = [router_xor_filter_worker:deveui_appeui(Device) || Device <- Round5Devices],

    Fitlers0 = get_filters(OUI1),
    ?assertEqual(1, erlang:length(Fitlers0)),

    %% Add devices
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock),

            Filters1 = get_filters(OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            #{devices => Round5Devices, block => 7, filter_count => 5},
            %% Removing all devices
            %% (Current block 7) + (Updating 4 filters) == 11
            %% Filter 0 has no devices, no changes
            %% No block change, not updating the chain for removals.
            #{devices => [], block => 7, filter_count => 5}
        ]
    ),

    %% Make sure removed devices are not in those filters
    %% Filters = get_filters(Chain, OUI1),
    %% Containment = [
    %%     xor16:contain({Filter, fun xxhash:hash64/1}, Device)
    %%     || Filter <- Filters, Device <- DeviceEUIs
    %% ],
    %% ?assertEqual(
    %%     [false],
    %%     lists:usort(Containment),
    %%     "Removed devices are _NOT_ in filters"
    %% ),
    Devices0 = lists:flatten(maps:values(get_filter_to_devices())),
    ?assertEqual(
        [false],
        lists:usort([lists:member(RemovedDevice, Devices0) || RemovedDevice <- DeviceEUIs]),
        "Removed devices are _NOT_ in worker cache"
    ),
    %% Refresh to make sure they don't load from the db
    router_xor_filter_worker:refresh_cache(),

    Devices1 = lists:flatten(maps:values(get_filter_to_devices())),
    Membership = [lists:member(RemovedDevice, Devices1) || RemovedDevice <- DeviceEUIs],
    ?assertEqual(
        [false],
        lists:usort(Membership),
        "Removed devices are _NOT_ in worker cache after refresh"
    ),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

send_updates_to_console_test(Config) ->
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    _Round1DevicesEUI = [router_xor_filter_worker:deveui_appeui(Device) || Device <- Round1Devices],

    true = ets:insert(Tab, {devices, Round1Devices}),
    ok = router_xor_filter_worker:check_filters(),

    %% should have pushed a new filter to the chain
    ok = expect_block(3),

    _ShouldBeRemovedNext =
        receive
            {console_filter_update, Added, []} ->
                %% ct:print("Console knows we Added:~n~p~n", [Added]),
                Added
        after 2150 -> ct:fail("No console message about adding devices to filters")
        end,

    ok = test_utils:ignore_messages(),

    %% Remove all Devices
    true = ets:insert(Tab, {devices, []}),
    ok = router_xor_filter_worker:check_filters(),

    %% should _NOT_ have pushed a new filter to the chain
    ok = expect_block(3),

    %% NOTE: Nothing is being removed from filters because there are no adds
    %% receive
    %%     {console_filter_update, [], []} ->
    %%         %% ct:print("Console knows we removed : ~n~p", [Removed]),
    %%        %% ?assertEqual(lists:sort(Removed), lists:sort(ShouldBeRemovedNext)),
    %%         ok
    %% after 2150 -> ct:fail("No console message about removing devices from filters")
    %% end,

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

between_worker_device_add_remove_send_updates_to_console_test(Config) ->
    %% A device is removed and added with the same EUI pair, but different
    %% device IDs. Console should be notified about the devices, but we should
    %% not change any of the filters.
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    %% Two devices with the same eui pair, but different ids
    Updates = [{app_eui, crypto:strong_rand_bytes(8)}, {dev_eui, crypto:strong_rand_bytes(8)}],
    Device1ID = <<"device-1">>,
    Device1 = router_device:update(Updates, router_device:new(Device1ID)),
    Device2ID = <<"device-2">>,
    Device2 = router_device:update(Updates, router_device:new(Device2ID)),

    %% Queue up device-1
    true = ets:insert(Tab, {devices, [Device1]}),
    ok = router_xor_filter_worker:check_filters(),
    ok = expect_block(3),

    %% Console knows about device 1
    receive
        {console_filter_update, [Device1ID], []} ->
            ok
    after 2150 -> ct:fail("No console message about device-1")
    end,

    ok = test_utils:ignore_messages(),

    %% Replace device-1 with device-2, same eui, different ids
    true = ets:insert(Tab, {devices, [Device2]}),
    ok = router_xor_filter_worker:check_filters(),
    timer:sleep(timer:seconds(1)),
    ok = expect_block(3),

    %% Console knows they are different devices
    receive
        {console_filter_update, [Device2ID], [Device1ID]} ->
            ok
    after 2150 -> ct:fail("No console message about device-2")
    end,

    %% ------------------------------------------------------------

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

device_add_multiple_send_updates_to_console_test(Config) ->
    %% A device is added, then more devices with the same EUI pair but different
    %% device IDs. Console should be notified about the devices, but we should
    %% not change any of the filters.
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    %% Two devices with the same eui pair, but different ids
    Updates = [{app_eui, crypto:strong_rand_bytes(8)}, {dev_eui, crypto:strong_rand_bytes(8)}],
    Device1ID = <<"device-1">>,
    Device1 = router_device:update(Updates, router_device:new(Device1ID)),
    Device2ID = <<"device-2">>,
    Device2 = router_device:update(Updates, router_device:new(Device2ID)),
    Device3ID = <<"device-3">>,
    Device3 = router_device:update(Updates, router_device:new(Device3ID)),

    %% Queue up device-1
    true = ets:insert(Tab, {devices, [Device1]}),
    ok = router_xor_filter_worker:check_filters(),
    ok = expect_block(3),

    %% Console knows about device 1
    receive
        {console_filter_update, [Device1ID], []} ->
            ok
    after 2150 -> ct:fail("No console message about device-1")
    end,

    ok = test_utils:ignore_messages(),

    %% Queue up all devices
    true = ets:insert(Tab, {devices, [Device1, Device2, Device3]}),
    ok = router_xor_filter_worker:check_filters(),
    timer:sleep(timer:seconds(1)),
    ok = expect_block(3),

    %% Console knows they are different devices
    receive
        {console_filter_update, [Device2ID, Device3ID], []} ->
            ok
    after 2150 -> ct:fail("No console message about device-2")
    end,

    %% ------------------------------------------------------------

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

device_add_unique_and_matching_send_updates_to_console_test(Config) ->
    %% A device is added, then more devices with the same EUI pair but different
    %% device IDs. Console should be notified about the devices, but we should
    %% not change any of the filters.
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    %% Two devices with the same eui pair, but different ids
    Updates1 = [{app_eui, crypto:strong_rand_bytes(8)}, {dev_eui, crypto:strong_rand_bytes(8)}],
    Device1ID = <<"device-1">>,
    Device1 = router_device:update(Updates1, router_device:new(Device1ID)),
    Device1IDCopy = <<"device-1-copy">>,
    Device1Copy = router_device:update(Updates1, router_device:new(Device1IDCopy)),

    Updates2 = [{app_eui, crypto:strong_rand_bytes(8)}, {dev_eui, crypto:strong_rand_bytes(8)}],
    Device2ID = <<"device-3">>,
    Device2 = router_device:update(Updates2, router_device:new(Device2ID)),

    %% Queue up device-1
    true = ets:insert(Tab, {devices, [Device1]}),
    ok = router_xor_filter_worker:check_filters(),
    ok = expect_block(3),

    %% Console knows about device 1
    receive
        {console_filter_update, [Device1ID], []} ->
            ok
    after 2150 -> ct:fail("No console message about device-1")
    end,

    ok = test_utils:ignore_messages(),

    %% Queue up all devices
    true = ets:insert(Tab, {devices, [Device1, Device1Copy, Device2]}),
    ok = router_xor_filter_worker:check_filters(),
    timer:sleep(timer:seconds(1)),
    ok = expect_block(4),

    %% Console knows they are different devices without needing a txn.
    receive
        {console_filter_update, [Device1IDCopy], []} ->
            ok
    after 2150 -> ct:fail("No console message about device-1-copy")
    end,

    %% Txn for new device goes through
    receive
        {console_filter_update, [Device2ID], []} ->
            ok
    after 2150 -> ct:fail("No console message about device-2")
    end,

    %% ------------------------------------------------------------

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

device_removed_send_updates_to_console_test(Config) ->
    %% A device is removed, but other devices with the same EUI pair still
    %% exist. Console should be notified about the devices, but we should not
    %% change any of the filters.
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    %% Two devices with the same eui pair, but different ids
    Updates = [{app_eui, crypto:strong_rand_bytes(8)}, {dev_eui, crypto:strong_rand_bytes(8)}],
    Device1ID = <<"device-1">>,
    Device1 = router_device:update(Updates, router_device:new(Device1ID)),
    Device2ID = <<"device-2">>,
    Device2 = router_device:update(Updates, router_device:new(Device2ID)),
    Device3ID = <<"device-3">>,
    Device3 = router_device:update(Updates, router_device:new(Device3ID)),

    %% Queue up all devices
    true = ets:insert(Tab, {devices, [Device1, Device2, Device3]}),
    ok = router_xor_filter_worker:check_filters(),
    ok = expect_block(3),

    %% Console knows about all devices
    receive
        {console_filter_update, [Device1ID, Device2ID, Device3ID], []} ->
            ok
    after 2150 -> ct:fail("No console message about device-1")
    end,

    ok = test_utils:ignore_messages(),

    %% Remove device-2
    true = ets:insert(Tab, {devices, [Device1, Device3]}),
    ok = router_xor_filter_worker:check_filters(),
    timer:sleep(timer:seconds(1)),
    ok = expect_block(3),

    %% Console knows only device-2 was removed
    receive
        {console_filter_update, [], [Device2ID]} ->
            ok
    after 2150 -> ct:fail("No console message about device-2")
    end,

    %% Device cache should no longer know about device-2
    FilterToDevices = get_filter_to_devices(),
    ?assertEqual(0, erlang:length(maps:get(0, FilterToDevices))),
    ?assertEqual(2, erlang:length(maps:get(1, FilterToDevices))),
    ?assertEqual(0, erlang:length(maps:get(2, FilterToDevices))),
    ?assertEqual(0, erlang:length(maps:get(3, FilterToDevices))),
    ?assertEqual(0, erlang:length(maps:get(4, FilterToDevices))),

    %% ------------------------------------------------------------

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

estimate_cost_test(Config) ->
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    _Round1DevicesEUI = [router_xor_filter_worker:deveui_appeui(Device) || Device <- Round1Devices],

    LegacyFee = 0,

    true = ets:insert(Tab, {devices, Round1Devices}),
    ?assertMatch(
        {ok, LegacyFee, Added, #{}} when length(Added) == length(Round1Devices),
        router_xor_filter_worker:estimate_cost()
    ),
    ok = router_xor_filter_worker:check_filters(),

    %% should have pushed a new filter to the chain
    ok = expect_block(3),

    %% Remove all Devices
    true = ets:insert(Tab, {devices, []}),
    ?assertMatch(
        {ok, LegacyFee, [], #{1 := Removed}} when length(Removed) == length(Round1Devices),
        router_xor_filter_worker:estimate_cost()
    ),
    ok = router_xor_filter_worker:check_filters(),

    ?assertEqual(0, maps:size(get_pending_txns())),

    %% should _NOT_ have pushed a new filter to the chain for only removed devices
    ok = expect_block(3),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

%%--------------------------------------------------------------------
%% State Getters
%%--------------------------------------------------------------------
get_pending_txns() ->
    {state, _PubKeyBin, _SigFun, _OUI, PendingTxns, _FilterToDevices, _CheckFiltersRef} = sys:get_state(
        router_xor_filter_worker
    ),
    PendingTxns.

get_filter_to_devices() ->
    {state, _PubKeyBin, _SigFun, _OUI, _PendingTxns, FilterToDevices, _CheckFiltersRef} = sys:get_state(
        router_xor_filter_worker
    ),
    FilterToDevices.


%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

expect_block(BlockNum) ->
    case
        test_utils:wait_until(fun() ->
            {ok, Num} = router_blockchain:height(),
            if
                Num == BlockNum -> true;
                Num == BlockNum + 1 -> {fail, expected_block_passed};
                true -> false
            end
        end)
    of
        ok ->
            timer:sleep(500),
            ok;
        Err ->
            ct:fail("Expected Block ~p, got block ~p (~p)", [
                BlockNum,
                router_blockchain:height(),
                Err
            ])
    end.

n_rand_devices(N) ->
    lists:map(
        fun(Idx) ->
            Updates = [
                {app_eui, crypto:strong_rand_bytes(8)},
                {dev_eui, crypto:strong_rand_bytes(8)}
            ],
            Name = erlang:list_to_binary(io_lib:format("Device-~p", [Idx])),
            Device = router_device:update(Updates, router_device:new(Name)),
            Device
        end,
        lists:seq(1, N)
    ).

get_filters(OUI) ->
    {ok, Routing} = router_blockchain:routing_for_oui(OUI),
    blockchain_ledger_routing_v1:filters(Routing).

sort_binaries_by_size(Bins) ->
    lists:sort(
        fun
            ({_, A}, {_, B}) -> byte_size(A) < byte_size(B);
            (A, B) -> byte_size(A) < byte_size(B)
        end,
        Bins
    ).

bin_sizes([{_, _} | _] = Bins) ->
    [{I, byte_size(Bin)} || {I, Bin} <- Bins];
bin_sizes(Bins) ->
    [byte_size(Bin) || Bin <- Bins].
