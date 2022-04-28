-module(router_metrics).

-behavior(gen_server).

-include("metrics.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    routing_offer_observe/4,
    routing_packet_observe/4,
    routing_packet_observe_start/3,
    packet_trip_observe_start/3,
    packet_trip_observe_end/5, packet_trip_observe_end/6,
    packet_hold_time_observe/2,
    packet_routing_error/2,
    decoder_observe/3,
    function_observe/2,
    console_api_observe/3,
    downlink_inc/2,
    ws_state/1,
    xor_filter_update/1,
    sc_close_submit_inc/1
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
    chain = undefined :: undefined | blockchain:blockchain(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    routing_packet_duration :: map(),
    packet_duration :: map()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec routing_offer_observe(join | packet, accepted | rejected, any(), non_neg_integer()) -> ok.
routing_offer_observe(Type, Status, Reason, Time) when
    (Type == join orelse Type == packet) andalso
        (Status == accepted orelse Status == rejected)
->
    _ = prometheus_histogram:observe(?METRICS_ROUTING_OFFER, [Type, Status, Reason], Time),
    ok.

-spec routing_packet_observe(join | packet, any(), rejected, non_neg_integer()) -> ok.
routing_packet_observe(Type, Status, Reason, Time) when
    (Type == join orelse Type == packet) andalso
        Status == rejected
->
    _ = prometheus_histogram:observe(?METRICS_ROUTING_PACKET, [Type, Status, Reason, false], Time),
    ok.

-spec routing_packet_observe_start(binary(), binary(), non_neg_integer()) -> ok.
routing_packet_observe_start(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {routing_packet_observe_start, PacketHash, PubKeyBin, Time}).

-spec packet_trip_observe_start(binary(), binary(), non_neg_integer()) -> ok.
packet_trip_observe_start(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {packet_trip_observe_start, PacketHash, PubKeyBin, Time}).

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

-spec packet_hold_time_observe(Type :: join | packet, HoldTime :: non_neg_integer()) -> ok.
packet_hold_time_observe(Type, HoldTime) when Type == join orelse Type == packet ->
    _ = prometheus_histogram:observe(?METRICS_PACKET_HOLD_TIME, [Type], HoldTime),
    ok.

-spec packet_routing_error(
    Type :: join | packet,
    Error :: device_not_found | api_not_found | bad_mic
) -> ok.
packet_routing_error(Type, Error) ->
    _ = prometheus_counter:inc(?METRICS_PACKET_ERROR, [Type, Error]),
    ok.

-spec decoder_observe(atom(), ok | error, non_neg_integer()) -> ok.
decoder_observe(Type, Status, Time) when Status == ok orelse Status == error ->
    _ = prometheus_histogram:observe(?METRICS_DECODED_TIME, [Type, Status], Time),
    ok.

-spec function_observe(atom(), non_neg_integer()) -> ok.
function_observe(Fun, Time) ->
    _ = prometheus_histogram:observe(?METRICS_FUN_DURATION, [Fun], Time),
    ok.

-spec console_api_observe(atom(), atom(), non_neg_integer()) -> ok.
console_api_observe(Type, Status, Time) ->
    _ = prometheus_histogram:observe(?METRICS_CONSOLE_API_TIME, [Type, Status], Time),
    ok.

-spec downlink_inc(atom(), ok | error) -> ok.
downlink_inc(Type, Status) ->
    _ = prometheus_counter:inc(?METRICS_DOWNLINK, [Type, Status]),
    ok.

-spec ws_state(boolean()) -> ok.
ws_state(State) ->
    _ = prometheus_boolean:set(?METRICS_WS, State),
    ok.

-spec xor_filter_update(DC :: non_neg_integer()) -> ok.
xor_filter_update(DC) ->
    _ = prometheus_counter:inc(?METRICS_XOR_FILTER, DC),
    ok.

-spec sc_close_submit_inc(ok | error) -> ok.
sc_close_submit_inc(Status) ->
    _ = prometheus_counter:inc(?METRICS_SC_CLOSE_SUBMIT, [Status]),
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    ok = declare_metrics(),
    MetricsEnv = application:get_env(router, metrics, []),
    ElliOpts = [
        {callback, router_metrics_reporter},
        {callback_args, #{}},
        {port, proplists:get_value(port, MetricsEnv, 3000)}
    ],
    {ok, _Pid} = elli:start_link(ElliOpts),
    ok = blockchain_event:add_handler(self()),
    {ok, PubKey, _, _} = blockchain_swarm:keys(),
    PubkeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    _ = erlang:send_after(500, self(), post_init),
    {ok, #state{
        pubkey_bin = PubkeyBin,
        routing_packet_duration = #{},
        packet_duration = #{}
    }}.

handle_call(_Msg, _From, State) ->
    lager:debug("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {routing_packet_observe_start, PacketHash, PubKeyBin, Start},
    #state{routing_packet_duration = RPD} = State
) ->
    {noreply, State#state{routing_packet_duration = maps:put({PacketHash, PubKeyBin}, Start, RPD)}};
handle_cast(
    {packet_trip_observe_start, PacketHash, PubKeyBin, Start},
    #state{packet_duration = PD} = State
) ->
    {noreply, State#state{packet_duration = maps:put({PacketHash, PubKeyBin}, Start, PD)}};
handle_cast(
    {packet_trip_observe_end, PacketHash, PubKeyBin, End, Type, Downlink},
    #state{routing_packet_duration = RPD, packet_duration = PD} = State0
) ->
    State1 =
        case maps:get({PacketHash, PubKeyBin}, PD, undefined) of
            undefined ->
                State0;
            Start0 ->
                _ = prometheus_histogram:observe(
                    ?METRICS_PACKET_TRIP,
                    [Type, Downlink],
                    End - Start0
                ),
                State0#state{packet_duration = maps:remove({PacketHash, PubKeyBin}, PD)}
        end,
    State2 =
        case maps:get({PacketHash, PubKeyBin}, RPD, undefined) of
            undefined ->
                State1;
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
                State1#state{routing_packet_duration = maps:remove({PacketHash, PubKeyBin}, RPD)}
        end,
    {noreply, State2};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{chain = undefined} = State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            _ = schedule_next_tick(),
            {noreply, State#state{chain = Chain}}
    end;
handle_info({blockchain_event, {new_chain, Chain}}, State) ->
    {noreply, State#state{chain = Chain}};
handle_info(
    {blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}},
    #state{chain = undefined} = State
) ->
    erlang:send_after(500, self(), post_init),
    {noreply, State};
handle_info(
    {blockchain_event, {add_block, BlockHash, _Syncing, _Ledger}},
    #state{chain = Chain, pubkey_bin = PubkeyBin} = State
) ->
    _ = erlang:spawn(fun() -> ok = record_sc_close_conflict(Chain, BlockHash, PubkeyBin) end),
    {noreply, State};
handle_info(
    ?METRICS_TICK,
    #state{
        chain = Chain,
        pubkey_bin = PubkeyBin,
        routing_packet_duration = RPD,
        packet_duration = PD
    } = State
) ->
    lager:info("running metrcis"),
    erlang:spawn_opt(
        fun() ->
            ok = record_dc_balance(Chain, PubkeyBin),
            ok = record_state_channels(Chain),
            ok = record_chain_blocks(Chain),
            ok = record_vm_stats(),
            ok = record_ets(),
            ok = record_queues(),
            ok = record_grpc_connections(),
            ok = record_hotspot_reputations()
        end,
        [
            {fullsweep_after, 0},
            {priority, high}
        ]
    ),
    _ = schedule_next_tick(),
    {noreply, State#state{
        routing_packet_duration = cleanup_pd(RPD),
        packet_duration = cleanup_pd(PD)
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

-spec record_sc_close_conflict(
    Chain :: blockchain:blockchain(),
    BlockHash :: binary(),
    PubkeyBin :: libp2p_crypto:pubkey_bin()
) -> ok.
record_sc_close_conflict(Chain, BlockHash, PubkeyBin) ->
    case blockchain:get_block(BlockHash, Chain) of
        {error, _Reason} ->
            lager:error("failed to get block:~p ~p", [BlockHash, _Reason]);
        {ok, Block} ->
            Txns = lists:filter(
                fun(Txn) ->
                    case blockchain_txn:type(Txn) of
                        blockchain_txn_state_channel_close_v1 ->
                            SC = blockchain_txn_state_channel_close_v1:state_channel(Txn),
                            blockchain_state_channel_v1:owner(SC) == PubkeyBin andalso
                                blockchain_txn_state_channel_close_v1:conflicts_with(Txn) =/=
                                    undefined;
                        _ ->
                            false
                    end
                end,
                blockchain_block:transactions(Block)
            ),
            _ = prometheus_gauge:set(?METRICS_SC_CLOSE_CONFLICT, erlang:length(Txns)),
            ok
    end.

-spec record_dc_balance(
    Chain :: blockchain:blockchain(),
    PubkeyBin :: libp2p_crypto:pubkey_bin()
) -> ok.
record_dc_balance(Chain, PubkeyBin) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_dc_entry(PubkeyBin, Ledger) of
        {error, _} ->
            ok;
        {ok, Entry} ->
            Balance = blockchain_ledger_data_credits_entry_v1:balance(Entry),
            _ = prometheus_gauge:set(?METRICS_DC, Balance),
            ok
    end.

-spec record_state_channels(Chain :: blockchain:blockchain()) -> ok.
record_state_channels(Chain) ->
    {ok, Height} = blockchain:height(Chain),
    {OpenedCount, OverspentCount, _GettingCloseCount} = router_sc_worker:counts(Height),
    _ = prometheus_gauge:set(?METRICS_SC_OPENED_COUNT, OpenedCount),
    _ = prometheus_gauge:set(?METRICS_SC_OVERSPENT_COUNT, OverspentCount),

    ActiveSCs = maps:values(blockchain_state_channels_server:get_actives()),
    ActiveCount = erlang:length(ActiveSCs),
    _ = prometheus_gauge:set(?METRICS_SC_ACTIVE_COUNT, ActiveCount),

    {TotalDCLeft, TotalActors} = lists:foldl(
        fun({ActiveSC, _, _}, {DCs, Actors}) ->
            Summaries = blockchain_state_channel_v1:summaries(ActiveSC),
            TotalDC = blockchain_state_channel_v1:total_dcs(ActiveSC),
            DCLeft = blockchain_state_channel_v1:amount(ActiveSC) - TotalDC,
            %% If SC ran out of DC we should not be counted towards active metrics
            case DCLeft of
                0 ->
                    {DCs, Actors};
                _ ->
                    {DCs + DCLeft, Actors + erlang:length(Summaries)}
            end
        end,
        {0, 0},
        ActiveSCs
    ),
    _ = prometheus_gauge:set(?METRICS_SC_ACTIVE_BALANCE, TotalDCLeft),
    _ = prometheus_gauge:set(?METRICS_SC_ACTIVE_ACTORS, TotalActors),
    ok.

-spec record_chain_blocks(Chain :: blockchain:blockchain()) -> ok.
record_chain_blocks(Chain) ->
    case blockchain:head_block(Chain) of
        {error, _} ->
            ok;
        {ok, Block} ->
            Now = erlang:system_time(seconds),
            Time = blockchain_block:time(Block),
            _ = prometheus_gauge:set(?METRICS_CHAIN_BLOCKS, Now - Time),
            ok
    end.

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

-spec record_grpc_connections() -> ok.
record_grpc_connections() ->
    Opts = application:get_env(grpcbox, listen_opts, #{}),
    PoolName = grpcbox_services_sup:pool_name(Opts),
    try
        Counts = acceptor_pool:count_children(PoolName),
        proplists:get_value(active, Counts)
    of
        Count ->
            _ = prometheus_gauge:set(?METRICS_GRPC_CONNECTION_COUNT, Count)
    catch
        _:_ ->
            lager:warning("no grpcbox acceptor named ~p", [PoolName]),
            _ = prometheus_gauge:set(?METRICS_GRPC_CONNECTION_COUNT, 0)
    end,
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

-spec record_hotspot_reputations() -> ok.
record_hotspot_reputations() ->
    lists:foreach(
        fun({Hotspot, Counter}) ->
            Name = blockchain_utils:addr2name(Hotspot),
            case Counter >= router_hotspot_reputation:threshold() of
                true ->
                    _ = prometheus_gauge:set(?METRICS_HOTSPOT_REPUTATION, [Name], Counter);
                false ->
                    ok
            end
        end,
        router_hotspot_reputation:reputations()
    ).

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
