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
            "Usage:\n\n",
            "  device                                   - this message\n",
            "  device all                               - All devices in rocksdb\n",
            "  device <id>                              - Info for a device\n",
            "  device <id> queue                        - Queue of messages for device\n",
            "  device <id> queue clear                  - Empties the devices queue\n",
            "  device <id> queue add [see Msg Options]  - Adds Msg to end of device queue\n\n",
            "Msg Options:\n\n",
            "  --payload=<content>    - Content for message " ++
                "[default: \"Test cli downlink message\"]\n",
            "  --ack                  - Require confirmation from the device [default: false]\n",
            "  --channel-name=<name>  - Channel name to show up in console " ++
                "[default: \"CLI custom channel\"]\n",
            "  --port\n               - Port for frame [default: 1]\n\n"
        ]
    ].

device_cmd() ->
    [
        [["device"], [], [], ?USAGE],
        [["device", "all"], [], [], fun device_list_all/3],
        [["device", '*'], [], [], fun device_info/3],
        [["device", '*', "queue"], [], [], fun device_queue/3],
        [["device", '*', "queue", "clear"], [], [], fun device_queue_clear/3],
        [
            ["device", '*', "queue", "add"],
            [],
            [
                {confirmed, {longname, "ack"}, {datatype, boolean}},
                {port, {longname, "port"}, {datatype, integer}},
                {channel_name, {longname, "channel-name"}, {datatype, binary}},
                {payload, {longname, "payload"}, {datatype, binary}}
            ],
            fun device_queue_add_front/3
        ]
    ].

device_list_all(["device", "all"], [], []) ->
    c_table([format_device_for_table(Device) || Device <- lookup_all()]).

device_info(["device", ID], [], []) ->
    DeviceID = erlang:list_to_binary(ID),
    {ok, D} = lookup(DeviceID),
    c_list(
        io_lib:format("Device ~p", [DeviceID]),
        format_device_as_list(D)
    ).

device_queue(["device", ID, "queue"], [], []) ->
    DeviceID = erlang:list_to_binary(ID),
    {ok, D} = lookup(DeviceID),
    Title = io_lib:format("Device Queue: ~p", [DeviceID]),
    c_list(Title, router_device:queue(D)).

device_queue_clear(["device", ID, "queue", "clear"], [], []) ->
    DeviceID = erlang:list_to_binary(ID),
    {ok, D, WorkerPid} = lookup_and_get_worker(DeviceID),

    ok = router_device_worker:clear_queue(WorkerPid),

    Title = io_lib:format("~p Queue cleared", [DeviceID]),
    c_list(Title, router_device:queue(D)).

device_queue_add_front(["device", ID, "queue", "add"], [], Flags) ->
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
    c_text("Added ~n~p~n to queue for device ~n~p [new_queue_length: ~p]~n", [
        Msg,
        DeviceID,
        length(router_device:queue(D)) + 1
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

-spec c_list(string(), list()) -> clique_status:status().
c_list(Name, L) -> [clique_status:list(Name, L)].

-spec c_table(proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table([PropLists])].

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

%%
-spec format_device_as_list(router_device:device()) -> [string()].
format_device_as_list(D) ->
    lists:map(
        fun(I) -> io_lib:format("~p", [I]) end,
        [
            router_device:name(D),
            router_device:app_eui(D),
            router_device:dev_eui(D),
            router_device:devaddr(D),
            router_device:fcnt(D),
            router_device:fcntdown(D),
            router_device:queue(D),
            blockchain_utils:addr2name(router_device:location(D)),
            router_device:metadata(D),
            router_device:is_active(D)
        ]
    ).
