-module(router_cli_device_worker).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).
-define(ID_FLAG, {id, [{longname, "id"}]}).

-include("router_device_worker.hrl").

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [
            device_usage(),
            device_trace_usage(),
            device_queue_usage(),
            device_prune_usage()
        ]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [
            device_cmd(),
            device_trace_cmd(),
            device_queue_cmd(),
            device_prune_cmd()
        ]
    ).

%%--------------------------------------------------------------------
%% device
%%--------------------------------------------------------------------

device_usage() ->
    [
        ["device"],
        [
            "Device Commands\n\n",
            "  device                                       - this message\n",
            "  device all                                   - All devices in rocksdb\n",
            "  device --id=<id>                             - Info for a device\n",
            "  device trace --id=<id> [--stop]              - Tracing device's log\n",
            "  device trace stop --id=<id>                  - Stop tracing device's log\n",
            "  device queue --id=<id>                       - Queue of messages for device\n",
            "  device queue clear --id=<id>                 - Empties the devices queue\n",
            "  device queue add --id=<id> [see Msg Options] - Adds Msg to end of device queue\n",
            "  device prune --commit                        - Removes Devices from Rocks that don't exist in Console\n",
            "\nNotes\n",
            "  device xor                                   - Moved to 'filter' command"
        ]
    ].

device_cmd() ->
    [
        [["device"], [], [], prepend_device_id(fun device_info/4)],
        [["device", "all"], [], [], fun device_list_all/3]
    ].

%%--------------------------------------------------------------------
%% device trace
%%--------------------------------------------------------------------

device_trace_usage() ->
    [
        ["device", "trace"],
        [
            "Device Trace Commands\n\n",
            "  trace                    - this message",
            "  trace --id=<id> [--stop] - Start/Stop tracing device to log file (default: start)\n",
            "\nNotes\n",
            "  Trace will deactivate after 240 minutes\n",
            "  <id> of device will be converted to binary, DO NOT wrap <<>>\n",
            "  Logs will be stored under BASE_DIR/traces/{first 5 of <id>}.log\n"
        ]
    ].

device_trace_cmd() ->
    [
        [
            ["trace"],
            [],
            [?ID_FLAG, {stop, [{longname, "stop"}, {datatype, boolean}]}],
            prepend_device_id(fun trace/4)
        ]
    ].

%%--------------------------------------------------------------------
%% device queue
%%--------------------------------------------------------------------

device_queue_usage() ->
    [
        ["device", "queue"],
        [
            "Device Queue Commands\n\n",
            "  queue                                 - this message\n",
            "  queue --id=<id>                       - List Devices queue\n",
            "  queue clear --id=<id>                 - Empty Device queue\n",
            "  queue add --id=<id> [see Msg Options] - Queue downlink for device\n",
            "\nMsg Options:\n",
            "  --id=<id>              - ID of Device, do not wrap, will be converted to binary\n",
            "  --payload=<content>    - Content for message [default: \"Test cli downlink message\"]\n",
            "  --ack                  - Require confirmation from the device [default: false]\n",
            "  --channel-name=<name>  - Channel name to show up in console [default: \"CLI custom channel\"]\n",
            "  --port                 - Port for frame [default: 1]\n\n"
        ]
    ].

device_queue_cmd() ->
    [
        [
            ["device", "queue"],
            [],
            [?ID_FLAG],
            prepend_device_id(fun device_queue/4)
        ],
        [
            ["device", "queue", "clear"],
            [],
            [?ID_FLAG],
            prepend_device_id(fun device_queue_clear/4)
        ],
        [
            ["device", "queue", "add"],
            [],
            [
                ?ID_FLAG,
                {confirmed, [{longname, "ack"}, {datatype, boolean}]},
                {port, [{longname, "port"}, {datatype, integer}]},
                {channel_name, [{longname, "channel-name"}, {datatype, string}]},
                {payload, [{longname, "payload"}, {datatype, string}]}
            ],
            prepend_device_id(fun device_queue_add_front/4)
        ]
    ].

%%--------------------------------------------------------------------
%% device prune
%%--------------------------------------------------------------------

device_prune_usage() ->
    [
        ["device", "prune"],
        [
            "Device Prune Commands\n\n",
            "  prune --commit     - Removes Devices from RocksDB that don't exist in Console\n"
        ]
    ].

device_prune_cmd() ->
    [
        [
            ["device", "prune"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun device_prune/3
        ]
    ].

%%--------------------------------------------------------------------
%% Internal Function Definitions
%%--------------------------------------------------------------------

trace(ID, ["device", "trace"], [], [{id, ID}]) ->
    DeviceID = erlang:list_to_binary(ID),
    erlang:spawn(router_utils, trace, [DeviceID]),
    c_text("Tracing device " ++ ID);
trace(ID, ["device", "trace"], [], [{id, ID}, {stop, _}]) ->
    DeviceID = erlang:list_to_binary(ID),
    erlang:spawn(router_utils, stop_trace, [DeviceID]),
    c_text("Stop tracing device " ++ ID).

prepend_device_id(Fn) ->
    fun(Cmd, Keys, Flags) ->
        case proplists:get_value(id, Flags) of
            undefined -> usage;
            Value -> Fn(Value, Cmd, Keys, Flags)
        end
    end.

device_list_all(["device", "all"], [], []) ->
    case router_console_api:get_devices() of
        {ok, Devices} ->
            c_table([format_device_for_table(Device) || Device <- Devices]);
        _ ->
            c_text("Failed to get devices from Console")
    end.

device_info(ID, ["device"], [], [{id, ID}]) ->
    DeviceID = erlang:list_to_binary(ID),
    {ok, D} = lookup(DeviceID),
    c_list(format_device_for_list(D)).

device_queue(ID, ["device", "queue"], [], [{id, ID}]) ->
    DeviceID = erlang:list_to_binary(ID),
    {ok, D} = lookup(DeviceID),
    case router_device:queue(D) of
        [] ->
            c_text("Queue is empty");
        Queue ->
            Heading = io_lib:format("Total: ~p~n~n", [length(Queue)]),
            Indexed = lists:zip(lists:seq(1, erlang:length(Queue)), Queue),
            Msgs = [io_lib:format("~p -- ~p~n~n", [I, X]) || {I, X} <- Indexed],
            c_list([Heading | Msgs])
    end.

device_queue_clear(ID, ["device", "queue", "clear"], [], [{id, ID}]) ->
    DeviceID = erlang:list_to_binary(ID),
    {ok, _D, WorkerPid} = lookup_and_get_worker(DeviceID),

    ok = router_device_worker:clear_queue(WorkerPid),

    Title = io_lib:format("~p Queue cleared", [DeviceID]),
    c_text(Title).

device_queue_add_front(ID, ["device", "queue", "add"], [], Flags) ->
    Options = maps:from_list(Flags),
    DeviceID = erlang:list_to_binary(ID),
    {ok, D, WorkerPid} = lookup_and_get_worker(DeviceID),

    Channel = router_channel:new(
        <<"cli_tool">>,
        remote_console,
        maps:get(channel_name, Options, <<"CLI custom channel">>),
        #{},
        DeviceID,
        self()
    ),
    Payload = maps:get(payload, Options, <<"Test cli downlink message">>),
    Msg = #downlink{
        confirmed = maps:is_key(confirmed, Options),
        port = maps:get(port, Options, 1),
        payload = router_utils:to_bin(Payload),
        channel = Channel
    },

    ok = router_device_worker:queue_message(WorkerPid, Msg),
    c_text("Queued Message to ~p [new_queue_length: ~p]~n~n~p~n~n", [
        DeviceID,
        length(router_device:queue(D)) + 1,
        Msg
    ]).

device_prune(["device", "prune"], [], Flags) ->
    Options = maps:from_list(Flags),
    Commit = maps:is_key(commit, Options),

    {ok, DB, CF} = router_db:get_devices(),
    RocksDevices = router_device:get(DB, CF),
    {ok, ConsoleDevices} = router_console_api:get_devices(),

    RocksDeviceIDs = [router_device:id(D) || D <- RocksDevices],
    ConsoleDeviceIDs = [router_device:id(D) || D <- ConsoleDevices],
    RocksOrphanedDeviceIDs = sets:to_list(
        sets:subtract(
            sets:from_list(RocksDeviceIDs),
            sets:from_list(ConsoleDeviceIDs)
        )
    ),

    RocksLen = length(RocksDeviceIDs),
    ConsoleLen = length(ConsoleDeviceIDs),
    OrphanLen = length(RocksOrphanedDeviceIDs),

    Output0 = [
        [{key, rocks}, {value, RocksLen}],
        [{key, console}, {value, ConsoleLen}],
        [{key, orphaned_in_rocks}, {value, OrphanLen}]
    ],

    Output1 =
        case Commit of
            true ->
                lists:foreach(
                    fun({Idx, DeviceID}) ->
                        ok = router_device:delete(DB, CF, DeviceID),
                        ok = router_device_cache:delete(DeviceID),
                        io:format("  Deleted: ~p/~p\r", [Idx, OrphanLen])
                    end,
                    lists:zip(lists:seq(1, OrphanLen), RocksOrphanedDeviceIDs)
                ),
                Output0;
            false ->
                [
                    [{key, "DRY RUN"}, {value, "!!!"}]
                    | Output0
                ]
        end,

    c_table(Output1).

%%--------------------------------------------------------------------
%% router_console_dc_tracker interface
%%--------------------------------------------------------------------

-spec lookup(binary()) -> {ok, router_device:device()}.
lookup(DeviceID) ->
    {ok, DB, [_, CF]} = router_db:get(),
    router_device:get_by_id(DB, CF, DeviceID).

-spec get_device_worker(router_device:device()) -> {ok, pid()}.
get_device_worker(Device) ->
    router_devices_sup:maybe_start_worker(router_device:id(Device), #{}).

-spec lookup_and_get_worker(binary()) -> {ok, router_device:device(), pid()}.
lookup_and_get_worker(DeviceID) ->
    {ok, Device} = lookup(DeviceID),
    {ok, Pid} = get_device_worker(Device),
    {ok, Device, Pid}.

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

-spec c_list(list(string())) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
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

-spec format_device_for_table(router_device:device()) -> proplists:proplist().
format_device_for_table(D) ->
    [
        {running, is_device_running(D)},
        {id, router_device:id(D)},
        {name, router_device:name(D)},
        {fcnt, router_device:fcnt(D)},
        {fcntdown, router_device:fcntdown(D)},
        {queue_length, length(router_device:queue(D))},
        {is_active, router_device:is_active(D)}
    ].

-spec format_device_for_list(router_device:device()) -> [string()].
format_device_for_list(D) ->
    Fields = [id, name, app_eui, dev_eui, devaddr, fcnt, fcntdown, queue, metadata, is_active],
    Longest = lists:max([length(atom_to_list(X)) || X <- Fields, is_atom(X)]),
    lists:map(
        fun(Field) ->
            io_lib:format("~s :: ~p~n", [
                string:pad(atom_to_list(Field), Longest, trailing),
                erlang:apply(router_device, Field, [D])
            ])
        end,
        Fields
    ).
