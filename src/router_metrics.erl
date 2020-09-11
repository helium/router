-module(router_metrics).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         offer_inc/2,
         packet_inc/2]).

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
-define(OFFER, ?BASE ++ "device_routing_offer").
-define(PACKET, ?BASE ++ "device_routing_packet").
-define(DC, ?BASE ++ "dc_balance").
-define(SC_ACTIVE_COUNT, ?BASE ++ "state_channel_active_count").
-define(SC_ACTIVE, ?BASE ++ "state_channel_active").

-define(METRICS, [{counter, ?OFFER, [type, status], "Offer count"},
                  {counter, ?PACKET, [type, status], "Packet count"},
                  {gauge, ?DC, [], "DC balance"},
                  {gauge, ?SC_ACTIVE_COUNT, [], "Active State Channel count"},
                  {gauge, ?SC_ACTIVE, [id], "Active State Channel"}]).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec offer_inc(join | packet, accepted | rejected) -> ok.
offer_inc(Type, Status) when (Type == join orelse Type == packet)
                             andalso (Status == accepted orelse Status == rejected) ->
    ok = prometheus_counter:inc(?OFFER, [Type, Status]).

-spec packet_inc(join | packet, accepted | rejected) -> ok.
packet_inc(Type, Status) when (Type == join orelse Type == packet)
                              andalso (Status == accepted orelse Status == rejected) ->
    ok = prometheus_counter:inc(?PACKET, [Type, Status]).

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
                                            {labels, Labels}])
      end,
      ?METRICS),
    _ = schedule_next_tick(),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?METRICS_TICK, State) ->
    erlang:spawn(
      fun() ->
              ok = record_dc_balance(),
              ok = record_state_channels()
      end),
    _ = schedule_next_tick(),
    {noreply, State};
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
    ActiveSC = blockchain_state_channels_server:active_sc(),
    ID = base64url:encode(blockchain_state_channel_v1:id(ActiveSC)),
    TotalDC = blockchain_state_channel_v1:total_dcs(ActiveSC),
    DCLeft = blockchain_state_channel_v1:total_dcs(ActiveSC)-TotalDC,
    _ = prometheus_gauge:set(?SC_ACTIVE, [ID], DCLeft),
    ok.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_TICK_INTERVAL, self(), ?METRICS_TICK).
