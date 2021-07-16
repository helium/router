-module(router_xor_filter_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    publish_xor_test/1,
    many_devices_test/1,
    more_devices_test/1,
    overflow_devices_test/1,
    max_filters_devices_test/1,
    ignore_largest_filter_test/1,
    evenly_rebalance_filter_test/1,
    oddly_rebalance_filter_test/1,
    remove_devices_filter_test/1,
    remove_devices_filter_after_restart_test/1
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
    check_filters_ref,
    txn_count
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
        many_devices_test,
        more_devices_test,
        overflow_devices_test,
        max_filters_devices_test,
        ignore_largest_filter_test,
        evenly_rebalance_filter_test,
        oddly_rebalance_filter_test,
        remove_devices_filter_test,
        remove_devices_filter_after_restart_test
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

    State0 = sys:get_state(router_xor_filter_worker),
    ?assertEqual(#{}, State0#state.pending_txns),
    ?assertEqual(#{1 => [DeviceDevEuiAppEui]}, State0#state.filter_to_devices),

    Filters = get_filters(Chain, OUI1),
    ?assertEqual(2, erlang:length(Filters)),

    [Filter1, Filter2] = Filters,
    ?assertNot(xor16:contain({Filter1, ?HASH_FUN}, DeviceDevEuiAppEui)),
    ?assert(xor16:contain({Filter2, ?HASH_FUN}, DeviceDevEuiAppEui)),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

many_devices_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),

    StartingDevices = n_rand_devices(10),

    %% Prepare devices to work with
    Tab = proplists:get_value(ets, Config),
    true = ets:insert(Tab, {devices, StartingDevices}),

    %% init worker processing first filter
    application:set_env(router, router_xor_filter_worker, true),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% OUI with blank filter should be pushed a new filter to the chain
    ok = expect_block(3, Chain),

    Filters = get_filters(Chain, OUI1),
    ?assertEqual(2, erlang:length(Filters)),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

more_devices_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),

    StartingDevices = n_rand_devices(10),
    MoreDevices = n_rand_devices(10),

    %% Prepare devices to work with
    Tab = proplists:get_value(ets, Config),
    true = ets:insert(Tab, {devices, StartingDevices}),

    %% init worker processing first filter
    application:set_env(router, router_xor_filter_worker, true),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% OUI with blank filter should be pushed a new filter to the chain
    ok = expect_block(3, Chain),

    Filters = get_filters(Chain, OUI1),
    ?assertEqual(2, erlang:length(Filters)),

    true = ets:insert(Tab, {devices, MoreDevices}),
    ok = router_xor_filter_worker:check_filters(),

    %% should have pushed a new filter to the chain
    ok = expect_block(4, Chain),

    Filters1 = get_filters(Chain, OUI1),
    ?assertEqual(2, erlang:length(Filters1)),

    ?assertNotEqual(Filters, Filters1),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

overflow_devices_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),

    StartingDevices = n_rand_devices(10),
    MoreDevices = n_rand_devices(10),

    %% Prepare devices to work with
    Tab = proplists:get_value(ets, Config),
    true = ets:insert(Tab, {devices, StartingDevices}),

    %% Init worker
    application:set_env(router, router_xor_filter_worker, true),
    erlang:whereis(router_xor_filter_worker) ! post_init,

    %% Wait until xor filter worker started properly
    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_xor_filter_worker),
        State#state.chain =/= undefined andalso
            State#state.oui =/= undefined
    end),

    %% OUI with blank filter should be pushed a new filter to the chain
    ok = expect_block(3, Chain),

    Filters = get_filters(Chain, OUI1),
    ?assertEqual(2, erlang:length(Filters)),

    true = ets:insert(Tab, {devices, StartingDevices ++ MoreDevices}),
    ok = router_xor_filter_worker:check_filters(),

    %% should have pushed a new filter to the chain
    ok = expect_block(4, Chain),

    Filters1 = get_filters(Chain, OUI1),
    ?assertEqual(3, erlang:length(Filters1)),

    ?assertNotEqual(Filters, Filters1),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok.

max_filters_devices_test(Config) ->
    Chain = proplists:get_value(chain, Config),
    OUI1 = proplists:get_value(oui, Config),
    Tab = proplists:get_value(ets, Config),

    Round1Devices = n_rand_devices(10),
    Round2Devices = Round1Devices ++ n_rand_devices(10),
    Round3Devices = Round2Devices ++ n_rand_devices(10),
    Round4Devices = Round3Devices ++ n_rand_devices(10),
    Round5Devices = Round4Devices ++ n_rand_devices(10),

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
    Round2Devices = Round1Devices ++ n_rand_devices(200),
    Round3Devices = Round2Devices ++ n_rand_devices(12),
    Round4Devices = Round3Devices ++ n_rand_devices(10),
    Round5Devices = Round4Devices ++ n_rand_devices(10),

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
    GetSizes = fun(L) -> [byte_size(F) || F <- L] end,

    ct:print("~nSizes: ~n~p~n", [GetSizes(Filters)]),
    %% Order: One   - 1 device
    %%        Two   - 10 devices
    %%        Three - 200 devices
    %%        Four  - 10 devices
    %%        Five  - 20 devices
    ?assertEqual(
        lists:sort(Filters),
        ExpectedOrder,
        lists:flatten(
            io_lib:format("Expected ~w got ~w", [
                GetSizes(ExpectedOrder),
                GetSizes(lists:sort(Filters))
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
    Round4Devices = Round3Devices ++ n_rand_devices(4),
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

    (fun() ->
        [One, Two, Three, Four, Five] = Filters = get_filters(Chain, OUI1),
        ct:print("~nOne Sizes: ~n~w~n", [[byte_size(F) || F <- Filters]]),
        %% Order: One   - 1 device
        %%        Two   - 10 devices
        %%        Three - 200 devices
        %%        Four  - 30 devices
        %%        Five  - 54 devices
        ?assertEqual(lists:sort(Filters), [One, Two, Four, Five, Three])
    end)(),
    ok = router_xor_filter_worker:rebalance_filters(),

    %% Wait until filters are committed
    %% Next filter would be 8
    %% Plus updating other filters (+4)
    %% Expecting 8 + 4 == 12
    ok = expect_block(12, Chain),

    (fun() ->
        Filters = get_filters(Chain, OUI1),
        Sizes = [byte_size(F) || F <- Filters],
        ct:print("~nTwo Sizes: ~n~w~n", [Sizes]),
        %% Order: One   - 59 devices
        %%        Two   - 59 devices
        %%        Three - 59 devices
        %%        Four  - 59 devices
        %%        Five  - 59 devices
        Diff = lists:max(Sizes) - lists:min(Sizes),
        ?assertEqual(0, Diff, "Devices should be disbtributed evenly")
    end)(),

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
    Round1Devices = n_rand_devices(10),
    Round2Devices = Round1Devices ++ n_rand_devices(200),
    Round3Devices = Round2Devices ++ n_rand_devices(35),
    Round4Devices = Round3Devices ++ n_rand_devices(45),
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

    Allowance = 10,
    (fun() ->
        Filters = get_filters(Chain, OUI1),
        Sizes = [byte_size(F) || F <- Filters],
        ct:print("~nOne Sizes: ~n~w~n", [Sizes]),
        %% Order: One   - 1 device
        %%        Two   - 10 devices
        %%        Three - 200 devices
        %%        Four  - 35 devices
        %%        Five  - 45+50 devices
        %% Total: 1 + 10 + 200 + 35 + 45 + 50 == 341
        Diff = lists:max(Sizes) - lists:min(Sizes),
        ?assert(
            Diff > Allowance,
            lists:flatten(
                io_lib:format("vastly uneven filters [diff: ~p] > [allowance: ~p]", [
                    Diff,
                    Allowance
                ])
            )
        )
    end)(),
    ok = router_xor_filter_worker:rebalance_filters(),

    %% Wait until filters are committed
    %% Next filter would be 8
    %% Plus updating other filters (+4)
    %% Expecting 8 + 4 == 12
    ok = expect_block(12, Chain),

    (fun() ->
        Filters = get_filters(Chain, OUI1),
        Sizes = [byte_size(F) || F <- Filters],
        ct:print("~nTwo Sizes: ~n~w~n", [Sizes]),
        %% Total: 1 + 10 + 200 + 35 + 45 + 50 == 341
        %% Distributed: 341/5 == 68.2
        %% Order: One   - ~68 devices
        %%        Two   - ~68 devices
        %%        Three - ~68 devices
        %%        Four  - ~68 devices
        %%        Five  - ~68 devices
        Diff = lists:max(Sizes) - lists:min(Sizes),
        ?assert(Diff =< Allowance, "Devices should be disbtributed closely")
    end)(),

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
    ct:print("Removed devices:~n~p, went from ~p to ~p", [
        length(Removed),
        length(Round5Devices),
        length(LeftoverDevices)
    ]),

    %% Check filters with devices that continue to exist
    ct:print("Michael look for me"),
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

    (fun() ->
        %% Make sure removed devices are not in those filters
        Filters = get_filters(Chain, OUI1),
        Containment = [
            xor16:contain(
                {Filter, fun xxhash:hash64/1},
                router_xor_filter_worker:deveui_appeui(Device)
            )
            || Filter <- Filters, Device <- Removed
        ],
        ?assertEqual(
            true,
            lists:member(true, Containment),
            "Removed devices _ARE_ in filters"
        )
    end)(),

    %% Restart the xor filter worker
    ct:print("michael we killed it"),
    exit(whereis(router_xor_filter_worker), kill),

    %% wait for worker to die
    ok = test_utils:wait_until(fun() ->
        not erlang:is_process_alive(whereis(router_xor_filter_worker))
    end),
    %% wait for worker to raise from the dead
    %% ok = test_utils:wait_until(fun() -> erlang:is_process_alive(whereis(router_xor_filter_worker)) end),
    timer:sleep(timer:seconds(1)),
    ok = test_utils:wait_until(fun() ->
        case whereis(router_xor_filter_worker) of
            undefined -> false;
            P -> erlang:is_process_alive(P)
        end
    end),

    %% Check filters with devices that continue to exist
    ct:print("Michael look for me"),
    true = ets:insert(Tab, {devices, LeftoverDevices}),
    ok = router_xor_filter_worker:check_filters(),

    %% Should commit filter for removed devices
    ok = expect_block(8, Chain),

    (fun() ->
        %% Make sure removed devices are not in those filters
        Filters = get_filters(Chain, OUI1),
        Containment = [
            xor16:contain(
                {Filter, fun xxhash:hash64/1},
                router_xor_filter_worker:deveui_appeui(Device)
            )
            || Filter <- Filters, Device <- Removed
        ],
        ?assertEqual(
            false,
            lists:member(true, Containment),
            "Removed devices are _NOT_ in filters"
        )
    end)(),

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
            Name = io_lib:format("Device-~p", [Idx]),
            Device = router_device:update(Updates, router_device:new(Name)),
            Device
        end,
        lists:seq(1, N)
    ).

get_filters(Chain, OUI) ->
    Ledger = blockchain:ledger(Chain),
    {ok, Routing} = blockchain_ledger_v1:find_routing(OUI, Ledger),
    blockchain_ledger_routing_v1:filters(Routing).
