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
    decoder_observe/3,
    function_observe/2,
    console_api_observe/3,
    downlink_inc/2,
    ws_state/1,
    network_id_inc/1,
    get_reporter_props/1,
    update_queues/1
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
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    routing_packet_duration :: map(),
    packet_duration :: map(),
    queues = [] :: list(pid())
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
    ok = notify(?METRICS_ROUTING_OFFER, Time, [Type, Status, Reason]).

-spec routing_packet_observe(join | packet, any(), rejected, non_neg_integer()) -> ok.
routing_packet_observe(Type, Status, Reason, Time) when
    (Type == join orelse Type == packet) andalso
        Status == rejected
->
    ok = notify(?METRICS_ROUTING_PACKET, Time, [Type, Status, Reason, false]).

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

-spec decoder_observe(atom(), ok | error, non_neg_integer()) -> ok.
decoder_observe(Type, Status, Time) when Status == ok orelse Status == error ->
    ok = notify(?METRICS_DECODED_TIME, Time, [Type, Status]).

-spec function_observe(atom(), non_neg_integer()) -> ok.
function_observe(Fun, Time) ->
    ok = notify(?METRICS_FUN_DURATION, Time, [Fun]).

-spec console_api_observe(atom(), atom(), non_neg_integer()) -> ok.
console_api_observe(Type, Status, Time) ->
    ok = notify(?METRICS_CONSOLE_API_TIME, Time, [Type, Status]).

-spec downlink_inc(atom(), ok | error) -> ok.
downlink_inc(Type, Status) ->
    ok = notify(?METRICS_DOWNLINK, undefined, [Type, Status]).

-spec ws_state(boolean()) -> ok.
ws_state(State) ->
    ok = notify(?METRICS_WS, State).

-spec network_id_inc(any()) -> ok.
network_id_inc(NetID) ->
    ok = notify(?METRICS_NETWORK_ID, undefined, [NetID]).

-spec get_reporter_props(atom()) -> list().
get_reporter_props(Reporter) ->
    MetricsEnv = application:get_env(router, metrics, []),
    proplists:get_value(Reporter, MetricsEnv, []).

-spec update_queues([pid()]) -> ok.
update_queues(Pids) ->
    gen_server:cast(
        ?MODULE,
        {update_queues, Pids}
    ).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, EvtMgr} = gen_event:start_link({local, ?METRICS_EVT_MGR}),
    MetricsEnv = application:get_env(router, metrics, []),
    lists:foreach(
        fun(Reporter) ->
            ok = gen_event:add_sup_handler(EvtMgr, Reporter, #{
                metrics => ?METRICS
            })
        end,
        proplists:get_value(reporters, MetricsEnv, [])
    ),
    {ok, PubKey, _, _} = blockchain_swarm:keys(),
    PubkeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    _ = schedule_next_tick(),
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
                ok = notify(?METRICS_PACKET_TRIP, End - Start0, [Type, Downlink]),
                State0#state{packet_duration = maps:remove({PacketHash, PubKeyBin}, PD)}
        end,
    State2 =
        case maps:get({PacketHash, PubKeyBin}, RPD, undefined) of
            undefined ->
                State1;
            Start1 ->
                ok = notify(?METRICS_ROUTING_PACKET, End - Start1, [
                    Type,
                    accepted,
                    accepted,
                    Downlink
                ]),
                State1#state{routing_packet_duration = maps:remove({PacketHash, PubKeyBin}, RPD)}
        end,
    {noreply, State2};
handle_cast({update_queues, Pids}, State) ->
    {noreply, State#state{queues = Pids}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    ?METRICS_TICK,
    #state{
        pubkey_bin = PubkeyBin,
        routing_packet_duration = RPD,
        packet_duration = PD,
        queues = _Pids
    } = State
) ->
    lager:info("running metrcis"),
    erlang:spawn(
        fun() ->
            ok = record_dc_balance(PubkeyBin),
            ok = record_state_channels(),
            ok = record_chain_blocks(),
            ok = record_vm_stats(),
            % ok = record_queues(Pids),
            ok = record_ets()
        end
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
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec cleanup_pd(map()) -> map().
cleanup_pd(PD) ->
    End = erlang:system_time(millisecond),
    maps:filter(fun(_K, Start) -> End - Start < timer:seconds(10) end, PD).

-spec record_dc_balance(PubkeyBin :: libp2p_crypto:pubkey_bin()) -> ok.
record_dc_balance(PubkeyBin) ->
    Ledger = blockchain:ledger(blockchain_worker:blockchain()),
    case blockchain_ledger_v1:find_dc_entry(PubkeyBin, Ledger) of
        {error, _} ->
            ok;
        {ok, Entry} ->
            Balance = blockchain_ledger_data_credits_entry_v1:balance(Entry),
            ok = notify(?METRICS_DC, Balance)
    end.

-spec record_state_channels() -> ok.
record_state_channels() ->
    OpenedSCs = blockchain_state_channels_server:state_channels(),
    ok = notify(?METRICS_SC_OPENED_COUNT, maps:size(OpenedSCs)),
    ActiveSCs = blockchain_state_channels_server:active_scs(),
    lists:foreach(
        fun({I, ActiveSC}) ->
            TotalDC = blockchain_state_channel_v1:total_dcs(ActiveSC),
            DCLeft = blockchain_state_channel_v1:amount(ActiveSC) - TotalDC,
            ok = notify(?METRICS_SC_ACTIVE_BALANCE, DCLeft, [I]),
            Summaries = blockchain_state_channel_v1:summaries(ActiveSC),
            ok = notify(?METRICS_SC_ACTIVE_ACTORS, erlang:length(Summaries), [I])
        end,
        lists:zip(lists:seq(1, erlang:length(ActiveSCs)), ActiveSCs)
    ).

-spec record_chain_blocks() -> ok.
record_chain_blocks() ->
    Chain = blockchain_worker:blockchain(),
    case blockchain:height(Chain) of
        {error, _} ->
            ok;
        {ok, Height} ->
            case hackney:get(<<"https://api.helium.io/v1/blocks/height">>, [], <<>>, [with_body]) of
                {ok, 200, _, Body} ->
                    CurHeight = kvc:path(
                        [<<"data">>, <<"height">>],
                        jsx:decode(Body, [return_maps])
                    ),
                    ok = notify(?METRICS_CHAIN_BLOCKS, CurHeight - Height);
                _ ->
                    ok
            end
    end.

-spec record_vm_stats() -> ok.
record_vm_stats() ->
    [{_Mem, CPU}] = recon:node_stats_list(1, 1),
    lists:foreach(
        fun({Num, Usage}) ->
            ok = notify(?METRICS_VM_CPU, Usage, [Num])
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
                        true -> ok = notify(?METRICS_VM_ETS_MEMORY, Bytes, [Name])
                    end
            end
        end,
        ets:all()
    ),
    ok.

% This function needs to be reworked
% -spec record_queues([pid()]) -> ok.
% record_queues(Pids0) ->
%     Offenders = recon:proc_count(message_queue_len, 5),
%     Pids1 = lists:foldl(
%         fun
%             ({Pid, Length, _Extra}, Acc) when Length == 0 ->
%                 case lists:member(Pid, Acc) of
%                     false ->
%                         ok;
%                     true ->
%                         Name = get_pid_name(Pid),
%                         ok = notify(?METRICS_VM_PROC_Q, Length, [Name])
%                 end,
%                 lists:delete(Pid, Acc);
%             ({Pid, Length, _Extra}, Acc) when Length < 1000 ->
%                 case lists:member(Pid, Acc) of
%                     false ->
%                         Acc;
%                     true ->
%                         Name = get_pid_name(Pid),
%                         case erlang:is_process_alive(Pid) of
%                             false ->
%                                 ok = notify(?METRICS_VM_PROC_Q, 0, [Name]),
%                                 lists:delete(Pid, Acc);
%                             true ->
%                                 ok = notify(?METRICS_VM_PROC_Q, Length, [Name]),
%                                 Acc
%                         end
%                 end;
%             ({Pid, Length, _Extra}, Acc) ->
%                 case erlang:is_process_alive(Pid) of
%                     false ->
%                         Acc;
%                     true ->
%                         Name = get_pid_name(Pid),
%                         ok = notify(?METRICS_VM_PROC_Q, Length, [Name]),
%                         [Pid | Acc]
%                 end
%         end,
%         Pids0,
%         Offenders
%     ),
%     ?MODULE:update_queues(Pids1).

% -spec get_pid_name(pid()) -> atom().
% get_pid_name(Pid) ->
%     case recon:info(Pid, registered_name) of
%         [] -> erlang:pid_to_list(Pid);
%         {registered_name, Name} -> Name;
%         _Else -> erlang:pid_to_list(Pid)
%     end.

-spec notify(atom(), any()) -> ok.
notify(Key, Data) ->
    ok = notify(Key, Data, []).

-spec notify(atom(), any(), list()) -> ok.
notify(Key, Data, MetaData) ->
    ok = gen_event:notify(?METRICS_EVT_MGR, {data, Key, Data, MetaData}).

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_TICK_INTERVAL, self(), ?METRICS_TICK).
