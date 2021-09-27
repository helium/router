-module(router_metrics_reporter_prometheus).

-behaviour(gen_event).

-include("metrics.hrl").

%% ------------------------------------------------------------------
%% gen_event Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_event/2,
    handle_call/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    ReporterArgs = router_metrics:get_reporter_props(?MODULE),
    lager:info("~p init with ~p and ~p", [?MODULE, Args, ReporterArgs]),
    ElliOpts = [
        {callback, router_metrics_reporter_prometheus_handler},
        {callback_args, #{}},
        {port, proplists:get_value(port, ReporterArgs, 3000)}
    ],
    {ok, _Pid} = elli:start_link(ElliOpts),
    Metrics = maps:get(metrics, Args, []),
    lists:foreach(
        fun({Key, Meta, Desc}) ->
            declare_metric(Key, Meta, Desc)
        end,
        Metrics
    ),
    {ok, #state{}}.

handle_event({data, Key, Data, MetaData}, State) when
    Key == ?METRICS_ROUTING_OFFER;
    Key == ?METRICS_ROUTING_PACKET;
    Key == ?METRICS_PACKET_TRIP;
    Key == ?METRICS_DECODED_TIME;
    Key == ?METRICS_FUN_DURATION;
    Key == ?METRICS_CONSOLE_API_TIME
->
    _ = prometheus_histogram:observe(erlang:atom_to_list(Key), MetaData, Data),
    {ok, State};
handle_event({data, Key, _Data, MetaData}, State) when
    Key == ?METRICS_DOWNLINK; Key == ?METRICS_NETWORK_ID
->
    _ = prometheus_counter:inc(erlang:atom_to_list(Key), MetaData),
    {ok, State};
handle_event({data, Key, Data, _MetaData}, State) when Key == ?METRICS_WS ->
    _ = prometheus_boolean:set(erlang:atom_to_list(Key), Data),
    {ok, State};
handle_event({data, Key, Data, _MetaData}, State) when
    Key == ?METRICS_SC_OPENED_COUNT;
    Key == ?METRICS_SC_ACTIVE_COUNT;
    Key == ?METRICS_SC_ACTIVE_BALANCE;
    Key == ?METRICS_SC_ACTIVE_ACTORS;
    Key == ?METRICS_DC;
    Key == ?METRICS_CHAIN_BLOCKS
->
    _ = prometheus_gauge:set(erlang:atom_to_list(Key), Data),
    {ok, State};
handle_event({data, Key, Data, MetaData}, State) when
    Key == ?METRICS_VM_CPU;
    Key == ?METRICS_VM_PROC_Q;
    Key == ?METRICS_VM_ETS_MEMORY
->
    _ = prometheus_gauge:set(erlang:atom_to_list(Key), MetaData, Data),
    {ok, State};
handle_event({data, _Key, _Data, _MetaData}, State) ->
    lager:debug("ignore data ~p ~p ~p", [_Key, _Data, _MetaData]),
    {ok, State};
handle_event(_Msg, State) ->
    lager:debug("rcvd unknown evt msg: ~p", [_Msg]),
    {ok, State}.

handle_call(_Msg, State) ->
    lager:debug("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec declare_metric(atom(), list(), string()) -> any().
declare_metric(Key, Meta, Desc) when
    Key == ?METRICS_SC_OPENED_COUNT;
    Key == ?METRICS_SC_ACTIVE_COUNT;
    Key == ?METRICS_SC_ACTIVE_BALANCE;
    Key == ?METRICS_SC_ACTIVE_ACTORS;
    Key == ?METRICS_DC;
    Key == ?METRICS_CHAIN_BLOCKS;
    Key == ?METRICS_VM_CPU;
    Key == ?METRICS_VM_PROC_Q;
    Key == ?METRICS_VM_ETS_MEMORY
->
    _ = prometheus_gauge:declare([
        {name, erlang:atom_to_list(Key)},
        {help, Desc},
        {labels, Meta}
    ]);
declare_metric(Key, Meta, Desc) when
    Key == ?METRICS_ROUTING_OFFER;
    Key == ?METRICS_ROUTING_PACKET;
    Key == ?METRICS_PACKET_TRIP;
    Key == ?METRICS_DECODED_TIME;
    Key == ?METRICS_FUN_DURATION;
    Key == ?METRICS_CONSOLE_API_TIME
->
    _ = prometheus_histogram:declare([
        {name, erlang:atom_to_list(Key)},
        {help, Desc},
        {labels, Meta},
        {buckets, [50, 100, 250, 500, 1000, 2000]}
    ]);
declare_metric(Key, Meta, Desc) when Key == ?METRICS_DOWNLINK; Key == ?METRICS_NETWORK_ID ->
    _ = prometheus_counter:declare([
        {name, erlang:atom_to_list(Key)},
        {help, Desc},
        {labels, Meta}
    ]);
declare_metric(Key, Meta, Desc) when Key == ?METRICS_WS ->
    _ = prometheus_boolean:declare([
        {name, erlang:atom_to_list(Key)},
        {help, Desc},
        {labels, Meta}
    ]);
declare_metric(Key, _Meta, Desc) ->
    lager:warning("cannot declare unknown metric ~p / ~p", [Key, Desc]).
