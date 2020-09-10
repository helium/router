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

-define(BASE, "router_").
-define(OFFER, ?BASE ++ "device_routing_offer").
-define(PACKET, ?BASE ++ "device_routing_packet").

-define(METRICS, [{counter, ?OFFER, [type, status], "Offer count"},
                  {counter, ?PACKET, [type, status], "Packet count"}]).

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
                                              {labels, Labels}])
      end,
      ?METRICS),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

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

