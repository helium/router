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
        [device_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [device_cmd()]
    ).

%%--------------------------------------------------------------------
%% device
%%--------------------------------------------------------------------

device_usage() ->
    [
        ["filter"],
        [
            "\n\n",
            "  filter                     - this message\n",
            "  filter timer               - How much time until next xor filter run\n"
            "  filter update --commit     - Update XOR filter\n",
            "  filter report              - Size report\n"
            "  filter report device <id>  - Filter info for a device\n"
        ]
    ].

device_cmd() ->
    [
        [["filter"], [], [], ?USAGE],
        [["filter", "timer"], [], [], fun filter_timer/3],
        [
            ["filter", "update"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun filter_update/3
        ],
        [["filter", "report"], [], [], fun filter_report/3],
        [["filter", "report", "device", '*'], [], [], fun filter_report_device/3]
    ].

filter_report(["filter", "report"], [], []) ->
    [
        {routing, Routing},
        {in_memory, Memory}
    ] = router_xor_filter_worker:report_filter_sizes(),

    c_table([
        [
            {filter, Idx},
            {num_devices_in_cache, erlang:length(Devices)},
            {size_in_bytes, Size}
        ]
        || {{Idx, Devices}, {Idx, Size}} <- lists:zip(Memory, Routing)
    ]).

filter_timer(["filter", "timer"], [], []) ->
    case router_xor_filter_worker:report_timer() of
        undefined ->
            c_text("Timer not active");
        Timer when erlang:is_reference(Timer) ->
            TimeLeft = erlang:read_timer(Timer),
            TotalSeconds = erlang:convert_time_unit(TimeLeft, millisecond, second),
            {_Hour, Minute, Seconds} = calendar:seconds_to_time(TotalSeconds),
            c_text("Running again in T- ~pm ~ps", [Minute, Seconds])
    end.

filter_report_device(["filter", "report", "device", ID], [], []) ->
    DeviceID = erlang:list_to_binary(ID),

    {ok, Device} = lookup(DeviceID),
    DeviceAlive = is_device_running(Device),

    Console =
        case router_console_api:get_device(DeviceID) of
            {error, _} -> false;
            {ok, D} -> D
        end,

    [
        {routing, ChainFilters},
        {in_memory, WorkerFilters}
    ] = router_xor_filter_worker:report_device_status(Device),
    Worker = [I || {I, Present} <- WorkerFilters, Present == true],
    Chain = [I || {I, Present} <- ChainFilters, Present == true],

    c_table([
        [{place, console}, {value, Console}],
        [{place, worker_cache}, {value, Worker}],
        [{place, chain_filter}, {value, Chain}],
        %% Needs to be in rocks for us to fetch enough to ask other questions about device
        [{place, rocksdb}, {value, true}],
        [{place, running}, {value, DeviceAlive}]
    ]).

filter_update(["filter", "update"], [], Flags) ->
    Options = maps:from_list(Flags),
    case {maps:is_key(commit, Options), router_xor_filter_worker:estimate_cost()} of
        {_, noop} ->
            c_text("No Updates");
        {false, {ok, Cost, Added, Removed}} ->
            Adding = io_list:format("- Adding ~p devices", [length(Added)]),
            Removing = [
                io_lib:format("  - ~p - ~p", [FI, length(Devices)])
                || {FI, Devices} <- maps:to_list(Removed)
            ],
            c_list(
                [
                    " -- DRY RUN -- ",
                    io_lib:format("- Estimated Cost: ~p", [Cost]),
                    Adding,
                    "- Removing : (filter, num_devices)"
                ] ++ Removing
            );
        {true, {ok, Cost, Added, Removed}} ->
            ok = router_xor_filter_worker:check_filters(),
            Adding = io_list:format("- Adding ~p devices", [length(Added)]),
            Removing = [
                io_lib:format("  - ~p - ~p", [FI, length(Devices)])
                || {FI, Devices} <- maps:to_list(Removed)
            ],
            c_list(
                [
                    io_lib:format("- Estimated Cost: ~p", [Cost]),
                    Adding,
                    "- Removing : (filter, num_devices)"
                ] ++ Removing
            )
    end.

%%--------------------------------------------------------------------
%% router_cnonsole_dc_tracker interface
%%--------------------------------------------------------------------

-spec lookup(binary()) -> {ok, router_device:device()}.
lookup(DeviceID) ->
    {ok, DB, [_, CF]} = router_db:get(),
    router_device:get_by_id(DB, CF, DeviceID).

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

-spec is_device_running(router_device:device()) -> boolean().
is_device_running(D) ->
    case router_devices_sup:lookup_device_worker(router_device:id(D)) of
        {error, not_found} -> false;
        {ok, _} -> true
    end.
