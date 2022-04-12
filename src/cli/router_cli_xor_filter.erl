-module(router_cli_xor_filter).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [filter_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [filter_cmd()]
    ).

%%--------------------------------------------------------------------
%% filter
%%--------------------------------------------------------------------

filter_usage() ->
    [
        ["filter"],
        [
            "\n\n",
            "  filter                                           - this message\n"
            "  filter timer                                     - How much time until next xor filter run\n"
            "  filter update --commit                           - Update XOR filter\n"
            "  filter rebalance --commit                        - Evenly distribute known devices among existing filters\n"
            "  filter report                                    - Size report\n"
            "  filter report --id=<id>                          - Filter info for a device\n"
            "  filter reset_db  --commit                        - Reset rocksdb from Console api\n"
            "  filter migrate --from=<from> --to=<to> --commit  - Migrate devices, emptying filter <from> (Remember: filters are 0-indexed)\n"
            "  filter move_to_front <NumGroups> --commit        - Migrate devices to <NumGroups> filters, emptying the rest\n"
            "  filter contains --app=<app_eui> --dev=<dev_eui>  - Check if a device EUI pair is in XOR filters\n"
            "\n"
        ]
    ].

filter_cmd() ->
    [
        [["filter"], [], [], ?USAGE],
        [["filter", "timer"], [], [], fun filter_timer/3],
        [
            ["filter", "update"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun filter_update/3
        ],
        [
            ["filter", "rebalance"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun filter_rebalance/3
        ],
        [["filter", "report"], [], [{id, [{longname, "id"}]}], fun filter_report/3],
        [
            ["filter", "reset_db"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun filter_reset_db/3
        ],
        [
            ["filter", "migrate"],
            [],
            [
                {from, [{longname, "from"}, {typecast, fun erlang:list_to_integer/1}]},
                {to, [{longname, "to"}, {typecast, fun erlang:list_to_integer/1}]},
                {commit, [{longname, "commit"}, {datatype, boolean}]}
            ],
            fun filter_migrate/3
        ],
        [
            ["filter", "move_to_front", '*'],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun filter_move_to_front/3
        ],
        [
            ["filter", "contains"],
            [],
            [
                {app, [{longname, "app_eui"}, {typecast, fun erlang:list_to_binary/1}]},
                {dev, [{longname, "dev_eui"}, {typecast, fun erlang:list_to_binary/1}]}
            ],
            fun filter_contains/3
        ]
    ].

filter_contains(["filter", "contains"], [], Flags) ->
    #{app_eui := AppEUI0, dev_eui := DevEUI0} = maps:from_list(Flags),

    %% Device creds put into filter
    <<AppEUI:64/integer-unsigned-big>> = lorawan_utils:hex_to_binary(AppEUI0),
    <<DevEUI:64/integer-unsigned-big>> = lorawan_utils:hex_to_binary(DevEUI0),
    Target = <<DevEUI:64/integer-unsigned-little, AppEUI:64/integer-unsigned-little>>,

    Ledger = blockchain:ledger(),
    {ok, OUICount} = blockchain_ledger_v1:get_oui_counter(Ledger),
    Enum = fun(L) -> lists:zip(lists:seq(1, length(L)), L) end,
    HashFun = fun xxhash:hash64/1,

    %% [{1, {routing_v1, ...}}]
    Routing = [
        {OUI, element(2, blockchain_ledger_v1:find_routing(OUI, Ledger))}
     || OUI <- lists:seq(1, OUICount)
    ],
    %% [{1, [filter1, filter2]}]
    Filters = [
        {OUI, blockchain_ledger_routing_v1:filters(InnerRouting)}
     || {OUI, InnerRouting} <- Routing
    ],

    %% #{{1, 1} => filter1, {1, 2} => filter2}
    OUIFilterMap = maps:from_list(
        [
            {{OUI, Idx}, Filter}
         || {OUI, IF} <- Filters, {Idx, Filter} <- Enum(IF)
        ]
    ),

    Contains = fun(OUI, FilterNum, Creds) ->
        case maps:get({OUI, FilterNum}, OUIFilterMap, no_filter) of
            no_filter -> "__";
            Filter -> xor16:contain({Filter, HashFun}, Creds)
        end
    end,

    %% [
    %%  [{oui, 1}, {{filter, 1}, true}, {{filter, 2}, false}],
    %%  [{oui, 2}, {{filter, 1}, false}, {{filter, 2}, false}]
    %% ]
    Results = [
        [
            {'OUI', OUI}
            | [
                {{filter, Num}, Contains(OUI, Num, Target)}
             || Num <- lists:seq(1, 5)
            ]
        ]
     || OUI <- lists:seq(1, OUICount)
    ],

    c_table(Results).

filter_migrate(["filter", "migrate"], [], Flags) ->
    Options = #{from := FromIndex, to := ToIndex} = maps:from_list(Flags),
    Commit = maps:is_key(commit, Options),

    {ok, Curr, NewGroups, Costs} = router_xor_filter_worker:migrate_filter(
        FromIndex,
        ToIndex,
        Commit
    ),

    Output = [
        [
            {filter, Index},
            {old_size, length(maps:get(Index, Curr))},
            {new_size, length(maps:get(Index, NewGroups))},
            {cost, maps:get(Index, Costs)}
        ]
     || Index <- [FromIndex, ToIndex]
    ],

    case Commit of
        false ->
            DryRun = [[{filter, "DRY"}, {old_size, "RUN"}, {new_size, "!!!"}, {cost, "!!!"}]],
            c_table(DryRun ++ Output);
        true ->
            c_table(Output)
    end.

filter_move_to_front(["filter", "move_to_front", NumGroupStr], [], Flags) ->
    Commit = maps:is_key(commit, maps:from_list(Flags)),
    NumGroups = erlang:list_to_integer(NumGroupStr),

    {ok, Curr, NewGroups, Costs} = router_xor_filter_worker:move_to_front(NumGroups, Commit),

    Output = [
        [
            {filter, Index},
            {old_size, length(maps:get(Index, Curr))},
            {new_size, length(maps:get(Index, NewGroups))},
            {cost, maps:get(Index, Costs)}
        ]
     || Index <- lists:seq(0, 4)
    ],

    case Commit of
        false ->
            DryRun = [[{filter, "DRY"}, {old_size, "RUN"}, {new_size, "!!!"}, {cost, "!!!"}]],
            c_table(DryRun ++ Output);
        true ->
            c_table(Output)
    end.

filter_report(["filter", "report"], [], [{id, ID}]) ->
    DeviceID = erlang:iolist_to_binary(ID),
    report_device(DeviceID);
filter_report(["filter", "report"], [], []) ->
    [
        {routing, Routing0},
        {in_memory, Memory0}
    ] = router_xor_filter_worker:report_filter_sizes(),

    Max = lists:max([length(Routing0), length(Memory0)]),
    Routing = router_utils:enumerate_0_to_size(Routing0, Max, unused),
    Memory = router_utils:enumerate_0_to_size(Memory0, Max, unsued),

    c_table([
        [
            {filter, Idx},
            {num_devices_in_cache, Devices},
            {size_in_bytes, Size}
        ]
     || {{Idx, Devices}, {Idx, Size}} <- lists:zip(Memory, Routing)
    ]).

filter_timer(["filter", "timer"], [], []) ->
    case router_xor_filter_worker:report_timer() of
        undefined ->
            c_text("Timer not active");
        Timer ->
            case erlang:read_timer(Timer) of
                false ->
                    c_text("Currently running");
                TimeLeft ->
                    TotalSeconds = erlang:convert_time_unit(TimeLeft, millisecond, second),
                    {_Hour, Minute, Seconds} = calendar:seconds_to_time(TotalSeconds),
                    c_text("Running again in T- ~pm ~ps", [Minute, Seconds])
            end
    end.

filter_update(["filter", "update"], [], Flags) ->
    Options = maps:from_list(Flags),
    case {maps:is_key(commit, Options), router_xor_filter_worker:estimate_cost()} of
        {_, noop} ->
            c_text("No Updates");
        {false, {ok, Cost, Added, Removed}} ->
            Adding = io_lib:format("- Adding ~p devices", [length(Added)]),
            Removing = [
                io_lib:format("  - ~p - ~p", [FI, length(Devices)])
             || {FI, Devices} <- maps:to_list(Removed)
            ],
            c_list(
                lists:join(
                    "\n",
                    [
                        " -- DRY RUN -- ",
                        io_lib:format("- Estimated Cost: ~p", [Cost]),
                        Adding,
                        "- Removing : (filter, num_devices)"
                    ] ++ Removing
                )
            );
        {true, {ok, Cost, Added, Removed}} ->
            ok = router_xor_filter_worker:check_filters(),
            Adding = io_lib:format("- Adding ~p devices", [length(Added)]),
            Removing = [
                io_lib:format("  - ~p - ~p", [FI, length(Devices)])
             || {FI, Devices} <- maps:to_list(Removed)
            ],
            c_list(
                lists:join(
                    "\n",
                    [
                        io_lib:format("- Estimated Cost: ~p", [Cost]),
                        Adding,
                        "- Removing : (filter, num_devices)"
                    ] ++ Removing
                )
            )
    end.

filter_rebalance(["filter", "rebalance"], [], Flags) ->
    Options = maps:from_list(Flags),
    Commit = maps:is_key(commit, Options),
    case {Commit, router_xor_filter_worker:get_balanced_filters()} of
        {false, {ok, OldGroups, NewGroups}} ->
            c_table([
                [{filter, "DRY"}, {old_size, "RUN"}, {new_size, "!!!"}] ++
                    [
                        {filter, Key},
                        {old_size, erlang:length(maps:get(Key, OldGroups))},
                        {new_size, erlang:length(maps:get(Key, NewGroups))}
                    ]
             || Key <- lists:seq(0, 4)
            ]);
        {true, {ok, OldGroups, NewGroups}} ->
            {ok, _NewPending} = router_xor_filter_worker:commit_groups_to_filters(NewGroups),
            c_table([
                [
                    {filter, Key},
                    {old_size, erlang:length(maps:get(Key, OldGroups))},
                    {new_size, erlang:length(maps:get(Key, NewGroups))}
                ]
             || Key <- lists:seq(0, 4)
            ])
    end.

filter_reset_db(["filter", "reset_db"], [], Flags) ->
    Options = maps:from_list(Flags),
    Commit = maps:is_key(commit, Options),
    Reply = router_xor_filter_worker:reset_db(Commit),
    case Commit of
        false -> c_text("DRY-RUN:~n~p~n", [Reply]);
        true -> c_text("Committing:~n~p~n", [Reply])
    end.

%%--------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------

report_device(DeviceID) ->
    DeviceAlive =
        case router_devices_sup:lookup_device_worker(DeviceID) of
            {error, not_found} -> false;
            {ok, _} -> true
        end,
    ConsoleDevice =
        case router_console_api:get_device(DeviceID) of
            {error, _} -> false;
            {ok, D0} -> D0
        end,

    {ok, DB0, [_, CF0]} = router_db:get(),
    DBDevice =
        case router_device:get_by_id(DB0, CF0, DeviceID) of
            {error, _} -> false;
            {ok, D1} -> D1
        end,
    Device =
        case {DBDevice =/= false, ConsoleDevice =/= false} of
            {true, _} -> DBDevice;
            {_, true} -> ConsoleDevice;
            {false, false} -> false
        end,
    {InWorkerFilter, InChainFilter} =
        case Device =/= false of
            false ->
                {not_found, not_found};
            true ->
                [
                    {routing, ChainFilters},
                    {in_memory, WorkerFilters}
                ] = router_xor_filter_worker:report_device_status(Device),
                InWorkerFilter0 =
                    case [I || {I, Present} <- WorkerFilters, Present == true] of
                        [] -> false;
                        V1 -> V1
                    end,
                InChainFilter0 =
                    case [I || {I, Present} <- ChainFilters, Present == true] of
                        [] -> false;
                        V2 -> V2
                    end,
                {InWorkerFilter0, InChainFilter0}
        end,
    RocksDBCache =
        case Device =/= false of
            false ->
                false;
            true ->
                {ok, DB1, CF1} = router_db:get_xor_filter_devices(),
                EUI = router_xor_filter_worker:deveui_appeui(Device),
                case rocksdb:get(DB1, CF1, EUI, []) of
                    {ok, Bin} ->
                        maps:get(filter_index, binary_to_term(Bin), false);
                    _ ->
                        false
                end
        end,
    c_table([
        [{place, device_id}, {value, io_lib:format("~s", [DeviceID])}],
        [{place, in_console}, {value, ConsoleDevice =/= false}],
        [{place, in_rocksdb}, {value, DBDevice =/= false}],
        [{place, running}, {value, DeviceAlive}],
        [{place, worker_cache}, {value, lists:flatten(io_lib:format("~p", [InWorkerFilter]))}],
        [{place, rocks_db_cache}, {value, RocksDBCache}],
        [{place, chain_filter}, {value, lists:flatten(io_lib:format("~p", [InChainFilter]))}]
    ]).

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

-spec c_list(list(string())) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_table([proplists:proplist()]) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].
