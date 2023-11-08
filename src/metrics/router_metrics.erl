-module(router_metrics).

-behavior(gen_server).

-include("metrics.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    routing_packet_observe/4,
    routing_packet_observe_start/3,
    packet_trip_observe_end/5, packet_trip_observe_end/6,
    console_api_observe/3,
    ws_state/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-record(state, {
    packets :: map()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec routing_packet_observe(join | packet, any(), rejected, non_neg_integer()) -> ok.
routing_packet_observe(Type, Status, Reason, Time) when
    (Type == join orelse Type == packet) andalso
        Status == rejected
->
    _ = prometheus_histogram:observe(
        ?METRICS_ROUTING_PACKET, [Type, Status, Reason, false], Time
    ),
    ok.

-spec routing_packet_observe_start(binary(), binary(), non_neg_integer()) -> ok.
routing_packet_observe_start(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {routing_packet_observe_start, PacketHash, PubKeyBin, Time}).

-spec packet_trip_observe_end(binary(), binary(), non_neg_integer(), atom(), boolean()) -> ok.
packet_trip_observe_end(PacketHash, PubKeyBin, Time, Type, Downlink) ->
    packet_trip_observe_end(PacketHash, PubKeyBin, Time, Type, Downlink, false).

-spec packet_trip_observe_end(
    binary(),
    binary(),
    non_neg_integer(),
    atom(),
    boolean(),
    boolean()
) -> ok.
packet_trip_observe_end(_PacketHash, _PubKeyBin, _Time, _Type, _Downlink, true) ->
    ok;
packet_trip_observe_end(PacketHash, PubKeyBin, Time, Type, Downlink, false) ->
    gen_server:cast(
        ?MODULE,
        {packet_trip_observe_end, PacketHash, PubKeyBin, Time, Type, Downlink}
    ).

-spec console_api_observe(atom(), atom(), non_neg_integer()) -> ok.
console_api_observe(Type, Status, Time) ->
    _ = prometheus_histogram:observe(?METRICS_CONSOLE_API, [Type, Status], Time),
    ok.

-spec ws_state(boolean()) -> ok.
ws_state(State) ->
    _ = prometheus_boolean:set(?METRICS_WS, State),
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    ok = declare_metrics(),
    ElliOpts = [
        {callback, router_metrics_reporter},
        {callback_args, #{}},
        {port, router_utils:get_env_int(metrics_port, 3000)}
    ],
    {ok, _Pid} = elli:start_link(ElliOpts),
    _ = schedule_next_tick(),
    {ok, #state{
        packets = #{}
    }}.

handle_call(_Msg, _From, State) ->
    lager:debug("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {routing_packet_observe_start, PacketHash, PubKeyBin, Start},
    #state{packets = RPD} = State
) ->
    {noreply, State#state{packets = maps:put({PacketHash, PubKeyBin}, Start, RPD)}};
handle_cast(
    {packet_trip_observe_end, PacketHash, PubKeyBin, End, Type, Downlink},
    #state{packets = RPD} = State0
) ->
    State1 =
        case maps:get({PacketHash, PubKeyBin}, RPD, undefined) of
            undefined ->
                State0;
            Start1 ->
                _ = prometheus_histogram:observe(
                    ?METRICS_ROUTING_PACKET,
                    [
                        Type,
                        accepted,
                        accepted,
                        Downlink
                    ],
                    End - Start1
                ),
                State0#state{packets = maps:remove({PacketHash, PubKeyBin}, RPD)}
        end,
    {noreply, State1};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    ?METRICS_TICK,
    #state{
        packets = RPD
    } = State
) ->
    lager:info("running metrics"),
    erlang:spawn_opt(
        fun() ->
            ok = record_vm_stats(),
            ok = record_ets(),
            ok = record_queues(),
            ok = record_devices(),
            ok = record_pools()
        end,
        [
            {fullsweep_after, 0},
            {priority, high}
        ]
    ),
    _ = schedule_next_tick(),
    {noreply, State#state{
        packets = cleanup_pd(RPD)
    }};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    lager:warning("going down ~p", [_Reason]),
    lists:foreach(
        fun({Metric, Module, _Meta, _Description}) ->
            lager:info("removing metric ~p as ~p", [Metric, Module]),
            Module:deregister(Metric)
        end,
        ?METRICS
    ).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec declare_metrics() -> ok.
declare_metrics() ->
    lists:foreach(
        fun({Metric, Module, Meta, Description}) ->
            lager:info("declaring metric ~p as ~p meta=~p", [Metric, Module, Meta]),
            case Module of
                prometheus_histogram ->
                    _ = Module:declare([
                        {name, Metric},
                        {help, Description},
                        {labels, Meta},
                        {buckets, [50, 100, 250, 500, 1000, 2000, 5000, 10000, 30000, 60000]}
                    ]);
                _ ->
                    _ = Module:declare([
                        {name, Metric},
                        {help, Description},
                        {labels, Meta}
                    ])
            end
        end,
        ?METRICS
    ).

-spec cleanup_pd(map()) -> map().
cleanup_pd(PD) ->
    End = erlang:system_time(millisecond),
    maps:filter(fun(_K, Start) -> End - Start < timer:seconds(10) end, PD).

-spec record_vm_stats() -> ok.
record_vm_stats() ->
    [{_Mem, CPU}] = recon:node_stats_list(1, 1),
    lists:foreach(
        fun({Num, Usage}) ->
            _ = prometheus_gauge:set(?METRICS_VM_CPU, [Num], Usage)
        end,
        proplists:get_value(scheduler_usage, CPU, [])
    ),
    ok.

-spec record_pools() -> ok.
record_pools() ->
    lists:foreach(
        fun(Pool) ->
            try hackney_pool:get_stats(Pool) of
                Stats ->
                    InUse = proplists:get_value(in_use_count, Stats, 0),
                    _ = prometheus_gauge:set(?METRICS_CONSOLE_POOL, [Pool], InUse)
            catch
                _E:_R ->
                    lager:error("failed to get stats for pool ~p ~p ~p", [Pool, _E, _R])
            end
        end,
        [router_console_api_pool, router_console_api_event_pool]
    ),
    ok.

-spec record_ets() -> ok.
record_ets() ->
    lists:foreach(
        fun(ETS) ->
            Name = ets:info(ETS, name),
            case ets:info(ETS, memory) of
                undefined ->
                    ok;
                Memory ->
                    Bytes = Memory * erlang:system_info(wordsize),
                    case Bytes > 1000000 of
                        false -> ok;
                        true -> _ = prometheus_gauge:set(?METRICS_VM_ETS_MEMORY, [Name], Bytes)
                    end
            end
        end,
        ets:all()
    ),
    ok.

-spec record_queues() -> ok.
record_queues() ->
    CurrentQs = lists:foldl(
        fun({Pid, Length, _Extra}, Acc) ->
            Name = get_pid_name(Pid),
            maps:put(Name, Length, Acc)
        end,
        #{},
        recon:proc_count(message_queue_len, 5)
    ),
    RecorderQs = lists:foldl(
        fun({[{"name", Name} | _], Length}, Acc) ->
            maps:put(Name, Length, Acc)
        end,
        #{},
        prometheus_gauge:values(default, ?METRICS_VM_PROC_Q)
    ),
    OldQs = maps:without(maps:keys(CurrentQs), RecorderQs),
    lists:foreach(
        fun({Name, _Length}) ->
            case name_to_pid(Name) of
                undefined ->
                    prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                Pid ->
                    case recon:info(Pid, message_queue_len) of
                        undefined ->
                            prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                        {message_queue_len, 0} ->
                            prometheus_gauge:remove(?METRICS_VM_PROC_Q, [Name]);
                        {message_queue_len, Length} ->
                            prometheus_gauge:set(?METRICS_VM_PROC_Q, [Name], Length)
                    end
            end
        end,
        maps:to_list(OldQs)
    ),
    NewQs = maps:without(maps:keys(OldQs), CurrentQs),
    Config = application:get_env(router, metrics, []),
    MinLength = proplists:get_value(record_queue_min_length, Config, 2000),
    lists:foreach(
        fun({Name, Length}) ->
            case Length > MinLength of
                true ->
                    _ = prometheus_gauge:set(?METRICS_VM_PROC_Q, [Name], Length);
                false ->
                    ok
            end
        end,
        maps:to_list(NewQs)
    ),
    ok.

-spec record_devices() -> ok.
record_devices() ->
    Running = proplists:get_value(active, supervisor:count_children(router_devices_sup), 0),
    _ = prometheus_gauge:set(?METRICS_DEVICE_TOTAL, router_device_cache:size()),
    _ = prometheus_gauge:set(?METRICS_DEVICE_RUNNING, Running),
    ok.

-spec get_pid_name(pid()) -> list().
get_pid_name(Pid) ->
    case recon:info(Pid, registered_name) of
        [] -> erlang:pid_to_list(Pid);
        {registered_name, Name} -> erlang:atom_to_list(Name);
        _Else -> erlang:pid_to_list(Pid)
    end.

-spec name_to_pid(list()) -> pid() | undefined.
name_to_pid(Name) ->
    case erlang:length(string:split(Name, ".")) > 1 of
        true ->
            erlang:list_to_pid(Name);
        false ->
            erlang:whereis(erlang:list_to_atom(Name))
    end.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_TICK_INTERVAL, self(), ?METRICS_TICK).
