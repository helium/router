-module(router_cli_device_worker).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).

-include("router_device_worker.hrl").

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
        ["device"],
        [
            "\n\n",
            "  device                                        - this message\n",
            "  device all                                    - All devices in rocksdb\n",
            "  device --id=<id>                              - Info for a device\n",
            "  device trace --id=<id> [--stop]               - Tracing device's log\n",
            "  device trace stop --id=<id>                   - Stop tracing device's log\n",
            "  device xor --commit                           - Update XOR filter\n",
            "  device queue --id=<id>                        - Queue of messages for device\n",
            "  device queue clear --id=<id>                  - Empties the devices queue\n",
            "  device queue add --id=<id> [see Msg Options]  - Adds Msg to end of device queue\n\n",
            "Msg Options:\n\n",
            "  --id=<id>              - ID of Device, do not wrap, will be converted to binary\n",
            "  --payload=<content>    - Content for message " ++
                "[default: \"Test cli downlink message\"]\n",
            "  --ack                  - Require confirmation from the device [default: false]\n",
            "  --channel-name=<name>  - Channel name to show up in console " ++
                "[default: \"CLI custom channel\"]\n",
            "  --port                 - Port for frame [default: 1]\n\n"
        ]
    ].

id_flag() ->
    {id, [{longname, "id"}]}.

device_cmd() ->
    [
        [["device"], [], [id_flag()], prepend_device_id(fun device_info/4)],
        [["device", "all"], [], [], fun device_list_all/3],
        [
            ["device", "trace"],
            [],
            [id_flag(), {stop, [{longname, "stop"}, {datatype, boolean}]}],
            prepend_device_id(fun trace/4)
        ],
        [["device", "trace", "stop"], [], [id_flag()], prepend_device_id(fun stop_trace/4)],
        [
            ["device", "xor"],
            [],
            [{commit, [{longname, "commit"}, {datatype, boolean}]}],
            fun xor_filter/3
        ],
        [["device", "queue"], [], [id_flag()], prepend_device_id(fun device_queue/4)],
        [
            ["device", "queue", "clear"],
            [],
            [id_flag()],
            prepend_device_id(fun device_queue_clear/4)
        ],
        [
            ["device", "queue", "add"],
            [],
            [
                id_flag(),
                {confirmed, [{longname, "ack"}, {datatype, boolean}]},
                {port, [{longname, "port"}, {datatype, integer}]},
                {channel_name, [{longname, "channel-name"}, {datatype, string}]},
                {payload, [{longname, "payload"}, {datatype, string}]}
            ],
            prepend_device_id(fun device_queue_add_front/4)
        ]
    ].

trace(ID, ["device", "trace"], [], [{id, ID}]) ->
    DeviceID = erlang:list_to_binary(ID),
    erlang:spawn(router_utils, trace, [DeviceID]),
    c_text("Tracing device " ++ ID);
trace(ID, ["device", "trace"], [], [{id, ID}, {stop, _}]) ->
    stop_trace(ID, ["device", "trace", "stop"], [], [{id, ID}]).

xor_filter(["device", "xor"], [], Flags) ->
    Options = maps:from_list(Flags),
    case {maps:is_key(commit, Options), router_xor_filter_worker:estimate_cost()} of
        {_, noop} ->
            c_text("No Updates");
        {false, {Cost, N}} ->
            c_text(
                "DRY RUN: Adding ~p devices for ~p DC",
                [erlang:integer_to_list(N), erlang:integer_to_list(Cost)]
            );
        {true, {Cost, N}} ->
            ok = router_xor_filter_worker:check_filters(),
            c_text(
                "Adding ~p devices for ~p DC",
                [erlang:integer_to_list(N), erlang:integer_to_list(Cost)]
            )
    end.

stop_trace(ID, ["device", "trace", "stop"], [], [{id, ID}]) ->
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
    c_table([format_device_for_table(Device) || Device <- lookup_all()]).

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
    Msg = #downlink{
        confirmed = maps:is_key(confirmed, Options),
        port = maps:get(port, Options, 1),
        payload = maps:get(payload, Options, <<"Test cli downlink message">>),
        channel = Channel
    },

    ok = router_device_worker:queue_message(WorkerPid, Msg),
    c_text("Queued Message to ~p [new_queue_length: ~p]~n~n~p~n~n", [
        DeviceID,
        length(router_device:queue(D)) + 1,
        Msg
    ]).

%%--------------------------------------------------------------------
%% router_cnonsole_dc_tracker interface
%%--------------------------------------------------------------------

-spec lookup_all() -> [router_device:device()].
lookup_all() ->
    {ok, DB, [_, CF]} = router_db:get(),
    router_device:get(DB, CF).

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

-spec c_table(proplists:proplist()) -> clique_status:status().
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
