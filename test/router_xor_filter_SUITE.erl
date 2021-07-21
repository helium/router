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
    evenly_rebalance_filter_test/1,
    oddly_rebalance_filter_test/1,
    remove_devices_filter_test/1,
    remove_devices_filter_after_restart_test/1,
    report_device_status_test/1,
    remove_devices_single_txn_db_test/1,
    remove_devices_multiple_txn_db_test/1,
    send_updates_to_console_test/1,
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

-record(state, {
    pubkey,
    sig_fun,
    chain,
    oui,
    pending_txns = #{},
    filter_to_devices = #{},
    check_filters_ref
}).

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
        evenly_rebalance_filter_test,
        oddly_rebalance_filter_test,
        remove_devices_filter_test,
        remove_devices_filter_after_restart_test,
        report_device_status_test,
        remove_devices_single_txn_db_test,
        remove_devices_multiple_txn_db_test,
        send_updates_to_console_test,
        estimate_cost_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config0) ->
    application:set_env(router, router_xor_filter_worker, false),
    Config = test_utils:init_per_testcase(TestCase, Config0),
    ConsensusMembers = proplists:get_value(consensus_member, Config),

    test_utils:wait_until(fun() ->
        blockchain_worker:blockchain() =/= undefined
    end),

    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, submit_txn, fun(Txn, Callback) ->
        case blockchain_test_utils:create_block(ConsensusMembers, [Txn]) of
            {error, _Reason} = Error ->
                Callback(Error);
            {ok, Block} ->
                _ = blockchain_test_utils:add_block(
                    Block,
                    blockchain_worker:blockchain(),
                    self(),
                    blockchain_swarm:swarm()
                ),
                Callback(ok)
        end,
        ok
    end),

    Chain = blockchain_worker:blockchain(),
    {ok, PubKey, SignFun, _} = blockchain_swarm:keys(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% Create and submit OUI txn with an empty filter
    OUI1 = 1,
    {BinFilter, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn = blockchain_txn_oui_v1:new(OUI1, PubKeyBin, [PubKeyBin], BinFilter, 8),
    OUITxnFee = blockchain_txn_oui_v1:calculate_fee(OUITxn, Chain),
    OUITxnStakingFee = blockchain_txn_oui_v1:calculate_staking_fee(OUITxn, Chain),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, OUITxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, OUITxnStakingFee),
    SignedOUITxn = blockchain_txn_oui_v1:sign(OUITxn1, SignFun),

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
    _ = blockchain_test_utils:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    [{chain, Chain}, {oui, OUI1} | Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
publish_xor_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),

    %% init worker processing first filter
    application:set_env(router, router_xor_filter_worker, true),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% OUI with blank filter should be pushed a new filter to the chain
    ok = expect_block(3, Chain),

    DeviceUpdates = [
        {dev_eui, ?DEVEUI},
        {app_eui, ?APPEUI}
    ],
    Device = router_device:update(DeviceUpdates, router_device:new(<<"ID2">>)),
    DeviceDevEuiAppEui = router_xor_filter_worker:deveui_appeui(Device),

    BaseEmpty = maps:from_list([{X, []} || X <- lists:seq(0, 4)]),

    State0 = sys:get_state(router_xor_filter_worker),
    ?assertEqual(#{}, State0#state.pending_txns),
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
        State0#state.filter_to_devices
    ),

    Filters = get_filters(Chain, OUI1),
    ?assertEqual(2, erlang:length(Filters)),

    [Filter1, Filter2] = Filters,
    ?assertNot(xor16:contain({Filter1, ?HASH_FUN}, DeviceDevEuiAppEui)),
    ?assert(xor16:contain({Filter2, ?HASH_FUN}, DeviceDevEuiAppEui)),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

max_filters_devices_test(Config) ->
    Chain = proplists:get_value(chain, Config),
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

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% ------------------------------------------------------------
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock, Chain),

            Filters1 = get_filters(Chain, OUI1),
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
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker without processing first filter automatically
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% ------------------------------------------------------------

    Round1Devices = n_rand_devices(10),
    Round2Devices = n_rand_devices(200) ++ Round1Devices,
    Round3Devices = n_rand_devices(12) ++ Round2Devices,
    Round4Devices = n_rand_devices(10) ++ Round3Devices,
    Round5Devices = n_rand_devices(10) ++ Round4Devices,

    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock, Chain),

            Filters1 = get_filters(Chain, OUI1),
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

    [One, Two, Three, Four, Five] = Filters = get_filters(Chain, OUI1),
    ExpectedOrder = [One, Two, Four, Five, Three],

    %% ct:print("Sizes: ~n~p~n", [router_xor_filter_worker:report_filter_sizes()]),
    %% Order: One   - 0 device
    %%        Two   - 10 devices
    %%        Three - 200 devices
    %%        Four  - 12 devices
    %%        Five  - 20 devices
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

evenly_rebalance_filter_test(Config) ->
    %% If we have one really big filter, we should not update it when more
    %% devices come through
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

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
            ok = expect_block(ExpectedBlock, Chain),

            Filters1 = get_filters(Chain, OUI1),
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
    %% Order: One   - 1 device
    %%        Two   - 10 devices
    %%        Three - 200 devices
    %%        Four  - 30 devices
    %%        Five  - 54 devices
    [One, Two, Three, Four, Five] = Filters1 = get_filters(Chain, OUI1),
    ?assertEqual(sort_binaries_by_size(Filters1), [One, Two, Four, Five, Three]),

    ok = router_xor_filter_worker:rebalance_filters(),

    %% Wait until filters are committed
    %% Next filter would be 8
    %% Plus updating other filters (+4)
    %% Expecting 8 + 4 == 12
    ok = expect_block(12, Chain),

    %% ct:print("~nAfter Sizes: ~n~w~n", [router_xor_filter_worker:report_filter_sizes()]),
    %% Order: One   - 59 devices
    %%        Two   - 59 devices
    %%        Three - 59 devices
    %%        Four  - 59 devices
    %%        Five  - 59 devices
    Filters2 = get_filters(Chain, OUI1),
    Sizes = bin_sizes(Filters2),
    Diff = lists:max(Sizes) - lists:min(Sizes),
    ?assertEqual(0, Diff, "Devices should be disbtributed evenly"),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

oddly_rebalance_filter_test(Config) ->
    %% If we have one really big filter, we should not update it when more
    %% devices come through
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

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
            ok = expect_block(ExpectedBlock, Chain),

            Filters1 = get_filters(Chain, OUI1),
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

    %% Order: One   - 0 device
    %%        Two   - 15 devices
    %%        Three - 211 devices
    %%        Four  - 37 devices
    %%        Five  - 47+59 devices
    %% Total: 0 + 15 + 211 + 37 + 47 + 59 == 369
    Filters1 = get_filters(Chain, OUI1),
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
    ok = expect_block(12, Chain),

    %% Total: 0 + 15 + 211 + 37 + 47 + 59 == 369
    %% Distributed: 369/5 == 73.8
    %% Order: One   - 73 devices
    %%        Two   - 74 devices
    %%        Three - 74 devices
    %%        Four  - 74 devices
    %%        Five  - 74 devices
    Filters2 = get_filters(Chain, OUI1),
    Sizes2 = bin_sizes(Filters2),
    %% ct:print("~nAfter Sizes: ~n~p~n", [router_xor_filter_worker:report_filter_sizes()]),
    Diff2 = lists:max(Sizes2) - lists:min(Sizes2),
    ?assert(Diff2 =< Allowance, "Devices should be disbtributed closely"),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

remove_devices_filter_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

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

    Fitlers0 = get_filters(Chain, OUI1),
    ?assertEqual(1, erlang:length(Fitlers0)),

    %% Add devices
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            %% Ensure we aren't starting farther ahead than we expect
            ok = expect_block(ExpectedBlock - 1, Chain),

            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock, Chain),
            timer:sleep(timer:seconds(1)),

            Filters1 = get_filters(Chain, OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1)),
            timer:sleep(timer:seconds(1))
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

    %% Should commit filter for removed devices
    ok = expect_block(8, Chain),

    %% Make sure removed devices are not in those filters
    Filters = get_filters(Chain, OUI1),
    Containment = [
        xor16:contain({Filter, fun xxhash:hash64/1}, router_xor_filter_worker:deveui_appeui(Device))
        || Filter <- Filters, Device <- Removed
    ],
    ?assertEqual(
        false,
        lists:member(true, Containment),
        "Removed devices are _NOT_ in filters"
    ),
    State = sys:get_state(whereis(router_xor_filter_worker)),
    Devices = lists:flatten(maps:values(State#state.filter_to_devices)),
    ?assertEqual(
        [false, false],
        [lists:member(RemovedDevice, Devices) || RemovedDevice <- Removed],
        "Removed devices are _NOT_ in worker cache"
    ),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

remove_devices_filter_after_restart_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

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
            ok = expect_block(ExpectedBlock, Chain),

            Filters1 = get_filters(Chain, OUI1),
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
    Filters1 = get_filters(Chain, OUI1),
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
        not erlang:is_process_alive(whereis(router_xor_filter_worker))
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

    %% Should commit filter for removed devices
    ok = expect_block(8, Chain),

    %% Make sure removed devices are not in those filters
    Filters2 = get_filters(Chain, OUI1),
    Containment2 = [
        xor16:contain(
            {Filter, fun xxhash:hash64/1},
            router_xor_filter_worker:deveui_appeui(Device)
        )
        || Filter <- Filters2, Device <- Removed
    ],
    ?assertEqual(
        false,
        lists:member(true, Containment2),
        "Removed devices are _NOT_ in filters"
    ),
    State1 = sys:get_state(whereis(router_xor_filter_worker)),
    Devices1 = lists:flatten(maps:values(State1#state.filter_to_devices)),
    ?assertEqual(
        [false],
        lists:usort([lists:member(RemovedDevice, Devices1) || RemovedDevice <- Removed]),
        "Removed devices are _NOT_ in worker cache"
    ),

    %% Refresh the cache to make sure we don't have anything lying around
    ok = router_xor_filter_worker:refresh_cache(),

    State2 = sys:get_state(whereis(router_xor_filter_worker)),
    Devices2 = lists:flatten(maps:values(State2#state.filter_to_devices)),
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
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

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
            ok = expect_block(ExpectedBlock, Chain),

            Filters1 = get_filters(Chain, OUI1),
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
    %% Expecing this one because that's the smallest that has been written to.
    FiveExpectedReport = [{0, false}, {1, true}, {2, false}, {3, false}, {4, false}],

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
        "Fifth device should be written to filter 1 (smallest in-use filter)"
    ),

    %% NOTE: If filter selection is rewritten to consider filter size rather
    %% than known occupation, this test will need update

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

remove_devices_single_txn_db_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    Round1DevicesEUI = [router_xor_filter_worker:deveui_appeui(Device) || Device <- Round1Devices],

    Fitlers0 = get_filters(Chain, OUI1),
    ?assertEqual(1, erlang:length(Fitlers0)),

    %% Add devices
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            %% Ensure we aren't starting farther ahead than we expect
            ok = expect_block(ExpectedBlock - 1, Chain),

            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock, Chain),
            timer:sleep(timer:seconds(1)),

            Filters1 = get_filters(Chain, OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1)),
            timer:sleep(timer:seconds(1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            %% Removing all devices
            #{devices => [], block => 4, filter_count => 2}
        ]
    ),

    %% Make sure removed devices are not in those filters
    Filters = get_filters(Chain, OUI1),
    Containment = [
        xor16:contain({Filter, fun xxhash:hash64/1}, Device)
        || Filter <- Filters, Device <- Round1DevicesEUI
    ],
    ?assertEqual(
        [false],
        lists:usort(Containment),
        "Removed devices are _NOT_ in filters"
    ),
    State0 = sys:get_state(whereis(router_xor_filter_worker)),
    Devices0 = lists:flatten(maps:values(State0#state.filter_to_devices)),
    ?assertEqual(
        [false],
        lists:usort([lists:member(RemovedDevice, Devices0) || RemovedDevice <- Round1DevicesEUI]),
        "Removed devices are _NOT_ in worker cache"
    ),
    %% Refresh to make sure they don't load from the db
    router_xor_filter_worker:refresh_cache(),
    State1 = sys:get_state(whereis(router_xor_filter_worker)),
    Devices1 = lists:flatten(maps:values(State1#state.filter_to_devices)),
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
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    Round2Devices = n_rand_devices(20) ++ Round1Devices,
    Round3Devices = n_rand_devices(30) ++ Round2Devices,
    Round4Devices = n_rand_devices(40) ++ Round3Devices,
    Round5Devices = n_rand_devices(50) ++ Round4Devices,
    DeviceEUIs = [router_xor_filter_worker:deveui_appeui(Device) || Device <- Round5Devices],

    Fitlers0 = get_filters(Chain, OUI1),
    ?assertEqual(1, erlang:length(Fitlers0)),

    %% Add devices
    lists:foreach(
        fun(#{devices := Devices, block := ExpectedBlock, filter_count := ExpectedFilterNum}) ->
            true = ets:insert(Tab, {devices, Devices}),
            ok = router_xor_filter_worker:check_filters(),

            %% should have pushed a new filter to the chain
            ok = expect_block(ExpectedBlock, Chain),
            timer:sleep(timer:seconds(1)),

            Filters1 = get_filters(Chain, OUI1),
            ?assertEqual(ExpectedFilterNum, erlang:length(Filters1))
        end,
        [
            #{devices => Round1Devices, block => 3, filter_count => 2},
            #{devices => Round2Devices, block => 4, filter_count => 3},
            #{devices => Round3Devices, block => 5, filter_count => 4},
            #{devices => Round4Devices, block => 6, filter_count => 5},
            #{devices => Round5Devices, block => 7, filter_count => 5},
            %% Removing all devices
            %% Next filter would be 8
            %% Plus updating other filters (+4)
            %% Expecting 8 + 4 == 12
            #{devices => [], block => 12, filter_count => 5}
        ]
    ),

    %% Make sure removed devices are not in those filters
    Filters = get_filters(Chain, OUI1),
    Containment = [
        xor16:contain({Filter, fun xxhash:hash64/1}, Device)
        || Filter <- Filters, Device <- DeviceEUIs
    ],
    ?assertEqual(
        [false],
        lists:usort(Containment),
        "Removed devices are _NOT_ in filters"
    ),
    State0 = sys:get_state(whereis(router_xor_filter_worker)),
    Devices0 = lists:flatten(maps:values(State0#state.filter_to_devices)),
    ?assertEqual(
        [false],
        lists:usort([lists:member(RemovedDevice, Devices0) || RemovedDevice <- DeviceEUIs]),
        "Removed devices are _NOT_ in worker cache"
    ),
    %% Refresh to make sure they don't load from the db
    router_xor_filter_worker:refresh_cache(),
    State1 = sys:get_state(whereis(router_xor_filter_worker)),
    Devices1 = lists:flatten(maps:values(State1#state.filter_to_devices)),
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
    Chain = proplists:get_value(chain, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% ------------------------------------------------------------
    Round1Devices = n_rand_devices(10),
    _Round1DevicesEUI = [router_xor_filter_worker:deveui_appeui(Device) || Device <- Round1Devices],

    true = ets:insert(Tab, {devices, Round1Devices}),
    ok = router_xor_filter_worker:check_filters(),

    %% should have pushed a new filter to the chain
    ok = expect_block(3, Chain),
    timer:sleep(timer:seconds(1)),

    ShouldBeRemovedNext =
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

    %% should have pushed a new filter to the chain
    ok = expect_block(4, Chain),

    receive
        {console_filter_update, [], ShouldBeRemovedNext} ->
            ct:print("Console knows we removed : ~n~p", [ShouldBeRemovedNext]),
            ok
    after 2150 -> ct:fail("No console message about removing devices from filters")
    end,

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

estimate_cost_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    Tab = proplists:get_value(ets, Config),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, false),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

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
    ok = expect_block(3, Chain),
    timer:sleep(timer:seconds(1)),

    %% Remove all Devices
    true = ets:insert(Tab, {devices, []}),
    ?assertMatch(
        {ok, LegacyFee, [], #{1 := Removed}} when length(Removed) == length(Round1Devices),
        router_xor_filter_worker:estimate_cost()
    ),
    ok = router_xor_filter_worker:check_filters(),

    %% should have pushed a new filter to the chain
    ok = expect_block(4, Chain),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

expect_block(BlockNum, Chain) ->
    case
        test_utils:wait_until(fun() ->
            {ok, Num} = blockchain:height(Chain),
            if
                Num == BlockNum -> true;
                Num == BlockNum + 1 -> {fail, expected_block_passed};
                true -> false
            end
        end)
    of
        ok ->
            ok;
        Err ->
            ct:fail("Expected Block ~p, got block ~p (~p)", [
                BlockNum,
                blockchain:height(Chain),
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

get_filters(Chain, OUI) ->
    Ledger = blockchain:ledger(Chain),
    {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),
    blockchain_ledger_routing_v1:filters(Routing).

sort_binaries_by_size(Bins) ->
    lists:sort(
        fun(A, B) -> byte_size(A) < byte_size(B) end,
        Bins
    ).

bin_sizes(Bins) ->
    [byte_size(Bin) || Bin <- Bins].
