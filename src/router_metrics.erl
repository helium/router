-module(router_metrics).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         routing_offer_observe/4,
         routing_packet_observe/4, routing_packet_observe_start/3,
         packet_trip_observe_start/3, packet_trip_observe_end/5,
         downlink_inc/2,
         decoder_observe/3,
         console_api_observe/3,
         ws_state/1,
         function_observe/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-define(METRICS_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_TICK, '__router_metrics_tick').

-define(BASE, "router_").
-define(ROUTING_OFFER, ?BASE ++ "device_routing_offer_duration").
-define(ROUTING_PACKET, ?BASE ++ "device_routing_packet_duration").
-define(PACKET_TRIP, ?BASE ++ "device_packet_trip_duration").
-define(DOWNLINK, ?BASE ++ "device_downlink_packet").
-define(DC, ?BASE ++ "dc_balance").
-define(SC_ACTIVE_COUNT, ?BASE ++ "state_channel_active_count").
-define(SC_ACTIVE, ?BASE ++ "state_channel_active").
-define(DECODED_TIME, ?BASE ++ "decoder_decoded_duration").
-define(CONSOLE_API_TIME, ?BASE ++ "console_api_duration").
-define(WS, ?BASE ++ "ws_state").
-define(FUN_DURATION, ?BASE ++ "function_duration").

-define(METRICS, [{histogram, ?ROUTING_OFFER, [type, status, reason], "Routing Offer duration", [50, 100, 250, 500, 1000]},
                  {histogram, ?ROUTING_PACKET, [type, status, reason, downlink], "Routing Packet duration", [50, 100, 250, 500, 1000]},
                  {histogram, ?PACKET_TRIP, [type, downlink], "Packet round trip duration", [50, 100, 250, 500, 1000, 2000]},
                  {counter, ?DOWNLINK, [type, status], "Downlink count"},
                  {gauge, ?DC, [], "DC balance"},
                  {gauge, ?SC_ACTIVE_COUNT, [], "Active State Channel count"},
                  {gauge, ?SC_ACTIVE, [], "Active State Channel balance"},
                  {histogram, ?DECODED_TIME, [type, status], "Decoder decoded duration", [50, 100, 250, 500, 1000]},
                  {histogram, ?CONSOLE_API_TIME, [type, status], "Console API duration", [100, 250, 500, 1000]},
                  {boolean, ?WS, [], "Websocket State"},
                  {histogram, ?FUN_DURATION, [function], "Function duration", [1000, 5000, 10000, 50000, 100000]}]).

-record(state, {routing_packet_duration :: map(),
                packet_duration :: map()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec routing_offer_observe(join | packet, accepted | rejected, any(), non_neg_integer()) -> ok.
routing_offer_observe(Type, Status, Reason, Time) when (Type == join orelse Type == packet)
                                                       andalso (Status == accepted orelse Status == rejected) ->
    ok = prometheus_histogram:observe(?ROUTING_OFFER, [Type, Status, Reason], Time).

-spec routing_packet_observe(join | packet, any(), rejected, non_neg_integer()) -> ok.
routing_packet_observe(Type, Status, Reason, Time) when (Type == join orelse Type == packet)
                                                        andalso Status == rejected ->
    ok = prometheus_histogram:observe(?ROUTING_PACKET, [Type, Status, Reason, false], Time).

-spec routing_packet_observe_start(binary(), binary(), non_neg_integer()) -> ok.
routing_packet_observe_start(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {routing_packet_observe_start, PacketHash, PubKeyBin, Time}).

-spec packet_trip_observe_start(binary(), binary(), non_neg_integer()) -> ok.
packet_trip_observe_start(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {packet_trip_observe_start, PacketHash, PubKeyBin, Time}).

-spec packet_trip_observe_end(binary(), binary(), non_neg_integer(), atom(), boolean()) -> ok.
packet_trip_observe_end(PacketHash, PubKeyBin, Time, Type, Downlink) ->
    gen_server:cast(?MODULE, {packet_trip_observe_end, PacketHash, PubKeyBin, Time, Type, Downlink}).

-spec downlink_inc(atom(), ok | error) -> ok.
downlink_inc(Type, Status) ->
    ok = prometheus_counter:inc(?DOWNLINK, [Type, Status]).

-spec decoder_observe(atom(), ok | error, non_neg_integer()) -> ok.
decoder_observe(Type, Status, Time) when Status == ok orelse Status == error ->
    ok = prometheus_histogram:observe(?DECODED_TIME, [Type, Status], Time).

-spec console_api_observe(atom(), atom(), non_neg_integer()) -> ok.
console_api_observe(Type, Status, Time) ->
    ok = prometheus_histogram:observe(?CONSOLE_API_TIME, [Type, Status], Time).

-spec ws_state(boolean()) -> ok.
ws_state(State) ->
    ok = prometheus_boolean:set(?WS, [], State).

-spec function_observe(atom(), non_neg_integer()) -> ok.
function_observe(Fun, Time) ->
    ok = prometheus_histogram:observe(?FUN_DURATION, [Fun], Time).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Port = maps:get(port, Args, 3000),
    ElliOpts = [{callback, router_metrics_handler},
                {callback_args, #{}},
                {port, Port}],
    {ok, _Pid} = elli:start_link(ElliOpts),
    lists:foreach(
      fun({counter, Name, Labels, Help}) ->
              _ = prometheus_counter:declare([{name, Name},
                                              {help, Help},
                                              {labels, Labels}]);
         ({gauge, Name, Labels, Help}) ->
              _ = prometheus_gauge:declare([{name, Name},
                                            {help, Help},
                                            {labels, Labels}]);
         ({histogram, Name, Labels, Help, Buckets}) ->
              _ = prometheus_histogram:declare([{name, Name},
                                                {help, Help},
                                                {labels, Labels},
                                                {buckets, Buckets}]);
         ({boolean, Name, Labels, Help}) ->
              _ = prometheus_boolean:declare([{name, Name},
                                              {help, Help},
                                              {labels, Labels}])
      end,
      ?METRICS),
    _ = schedule_next_tick(),
    {ok, #state{routing_packet_duration = #{},
                packet_duration = #{}}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({routing_packet_observe_start, PacketHash, PubKeyBin, Start}, #state{routing_packet_duration=RPD}=State) ->
    {noreply, State#state{routing_packet_duration=maps:put({PacketHash, PubKeyBin}, Start, RPD)}};
handle_cast({packet_trip_observe_start, PacketHash, PubKeyBin, Start}, #state{packet_duration=PD}=State) ->
    {noreply, State#state{packet_duration=maps:put({PacketHash, PubKeyBin}, Start, PD)}};
handle_cast({packet_trip_observe_end, PacketHash, PubKeyBin, End, Type, Downlink}, #state{routing_packet_duration=RPD, packet_duration=PD}=State0) ->
    State1 = case maps:get({PacketHash, PubKeyBin}, PD, undefined) of
                 undefined ->
                     State0;
                 Start0 ->
                     ok = prometheus_histogram:observe(?PACKET_TRIP, [Type, Downlink], End-Start0),
                     State0#state{packet_duration=maps:remove({PacketHash, PubKeyBin}, PD)}
             end,
    State2 = case maps:get({PacketHash, PubKeyBin}, RPD, undefined) of
                 undefined ->
                     State1;
                 Start1 ->
                     ok = prometheus_histogram:observe(?ROUTING_PACKET, [Type, accepted, accepted, Downlink], End-Start1),
                     State1#state{routing_packet_duration=maps:remove({PacketHash, PubKeyBin}, RPD)}
             end,
    {noreply, State2};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?METRICS_TICK, #state{routing_packet_duration=RPD, packet_duration=PD}=State) ->
    erlang:spawn(
      fun() ->
              ok = record_dc_balance(),
              ok = record_state_channels()
      end),
    _ = schedule_next_tick(),
    {noreply, State#state{routing_packet_duration=cleanup_pd(RPD),
                          packet_duration=cleanup_pd(PD)}};
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
    maps:filter(fun(_K, Start) -> End-Start < timer:seconds(10) end, PD).

-spec record_dc_balance() -> ok.
record_dc_balance() ->
    Ledger = blockchain:ledger(blockchain_worker:blockchain()),
    Owner = blockchain_swarm:pubkey_bin(),
    case blockchain_ledger_v1:find_dc_entry(Owner, Ledger) of
        {error, _} ->
            ok;
        {ok, Entry} ->
            Balance = blockchain_ledger_data_credits_entry_v1:balance(Entry),
            _ = prometheus_gauge:set(?DC, Balance),
            ok
    end.

-spec record_state_channels() -> ok.
record_state_channels() ->
    ActiveSCCount = blockchain_state_channels_server:get_active_sc_count(),
    _ = prometheus_gauge:set(?SC_ACTIVE_COUNT, ActiveSCCount),
    case blockchain_state_channels_server:active_sc() of
        undefined ->
            _ = prometheus_gauge:set(?SC_ACTIVE, [], 0);
        ActiveSC ->
            TotalDC = blockchain_state_channel_v1:total_dcs(ActiveSC),
            DCLeft = blockchain_state_channel_v1:amount(ActiveSC)-TotalDC,
            _ = prometheus_gauge:set(?SC_ACTIVE, [], DCLeft)
    end,
    ok.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_TICK_INTERVAL, self(), ?METRICS_TICK).
