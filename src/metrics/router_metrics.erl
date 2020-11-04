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
    packet_trip_observe_end/5,
    decoder_observe/3,
    function_observe/2,
    console_api_observe/3,
    downlink_inc/2,
    ws_state/1,
    get_reporter_props/1
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
    ok = notify(?ROUTING_OFFER, Time, [Type, Status, Reason]).

-spec routing_packet_observe(join | packet, any(), rejected, non_neg_integer()) -> ok.
routing_packet_observe(Type, Status, Reason, Time) when
    (Type == join orelse Type == packet) andalso
        Status == rejected
->
    ok = notify(?ROUTING_PACKET, Time, [Type, Status, Reason, false]).

-spec routing_packet_observe_start(binary(), binary(), non_neg_integer()) -> ok.
routing_packet_observe_start(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {routing_packet_observe_start, PacketHash, PubKeyBin, Time}).

-spec packet_trip_observe_start(binary(), binary(), non_neg_integer()) -> ok.
packet_trip_observe_start(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {packet_trip_observe_start, PacketHash, PubKeyBin, Time}).

-spec packet_trip_observe_end(binary(), binary(), non_neg_integer(), atom(), boolean()) -> ok.
packet_trip_observe_end(PacketHash, PubKeyBin, Time, Type, Downlink) ->
    gen_server:cast(
        ?MODULE,
        {packet_trip_observe_end, PacketHash, PubKeyBin, Time, Type, Downlink}
    ).

-spec decoder_observe(atom(), ok | error, non_neg_integer()) -> ok.
decoder_observe(Type, Status, Time) when Status == ok orelse Status == error ->
    ok = notify(?DECODED_TIME, Time, [Type, Status]).

-spec function_observe(atom(), non_neg_integer()) -> ok.
function_observe(Fun, Time) ->
    ok = notify(?FUN_DURATION, Time, [Fun]).

-spec console_api_observe(atom(), atom(), non_neg_integer()) -> ok.
console_api_observe(Type, Status, Time) ->
    ok = notify(?CONSOLE_API_TIME, Time, [Type, Status]).

-spec downlink_inc(atom(), ok | error) -> ok.
downlink_inc(Type, Status) ->
    ok = notify(?DOWNLINK, undefined, [Type, Status]).

-spec ws_state(boolean()) -> ok.
ws_state(State) ->
    ok = notify(?WS, State).

-spec get_reporter_props(atom()) -> list().
get_reporter_props(Reporter) ->
    MetricsEnv = application:get_env(router, metrics, []),
    proplists:get_value(Reporter, MetricsEnv, []).

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
    _ = schedule_next_tick(),
    {ok, #state{
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
                ok = notify(?PACKET_TRIP, End - Start0, [Type, Downlink]),
                State0#state{packet_duration = maps:remove({PacketHash, PubKeyBin}, PD)}
        end,
    State2 =
        case maps:get({PacketHash, PubKeyBin}, RPD, undefined) of
            undefined ->
                State1;
            Start1 ->
                ok = notify(?ROUTING_PACKET, End - Start1, [Type, accepted, accepted, Downlink]),
                State1#state{routing_packet_duration = maps:remove({PacketHash, PubKeyBin}, RPD)}
        end,
    {noreply, State2};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    ?METRICS_TICK,
    #state{routing_packet_duration = RPD, packet_duration = PD} = State
) ->
    erlang:spawn(
        fun() ->
            ok = record_dc_balance(),
            ok = record_state_channels()
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

-spec record_dc_balance() -> ok.
record_dc_balance() ->
    Ledger = blockchain:ledger(blockchain_worker:blockchain()),
    Owner = blockchain_swarm:pubkey_bin(),
    case blockchain_ledger_v1:find_dc_entry(Owner, Ledger) of
        {error, _} ->
            ok;
        {ok, Entry} ->
            Balance = blockchain_ledger_data_credits_entry_v1:balance(Entry),
            ok = notify(?DC, Balance)
    end.

-spec record_state_channels() -> ok.
record_state_channels() ->
    ActiveSCCount = blockchain_state_channels_server:get_active_sc_count(),
    ok = notify(?SC_ACTIVE_COUNT, ActiveSCCount),
    case blockchain_state_channels_server:active_sc() of
        undefined ->
            ok = notify(?SC_ACTIVE, 0);
        ActiveSC ->
            TotalDC = blockchain_state_channel_v1:total_dcs(ActiveSC),
            DCLeft = blockchain_state_channel_v1:amount(ActiveSC) - TotalDC,
            ok = notify(?SC_ACTIVE, DCLeft)
    end.

-spec notify(atom(), any()) -> ok.
notify(Key, Data) ->
    ok = notify(Key, Data, []).

-spec notify(atom(), any(), list()) -> ok.
notify(Key, Data, MetaData) ->
    ok = gen_event:notify(?METRICS_EVT_MGR, {data, Key, Data, MetaData}).

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_TICK_INTERVAL, self(), ?METRICS_TICK).
