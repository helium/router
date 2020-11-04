-module(router_metrics_reporter_prometheus).

-behaviour(gen_event).

-include("metrics.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

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

handle_event({data, Key, Data, _MetaData}, State) when
    Key == ?METRICS_SC_ACTIVE; Key == ?METRICS_SC_ACTIVE_COUNT; Key == ?METRICS_DC
->
    _ = prometheus_gauge:set(erlang:atom_to_list(Key), Data),
    {ok, State};
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
handle_event({data, Key, _Data, MetaData}, State) when Key == ?METRICS_DOWNLINK ->
    _ = prometheus_counter:inc(erlang:atom_to_list(Key), MetaData),
    {ok, State};
handle_event({data, Key, Data, _MetaData}, State) when Key == ?METRICS_WS ->
    _ = prometheus_boolean:set(erlang:atom_to_list(Key), Data),
    {ok, State};
handle_event({data, Key, Data, _MetaData}, State) when
    Key == ?METRICS_SC_ACTIVE; Key == ?METRICS_SC_ACTIVE_COUNT; Key == ?METRICS_DC
->
    _ = prometheus_gauge:set(erlang:atom_to_list(Key), Data),
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
    Key == ?METRICS_SC_ACTIVE; Key == ?METRICS_SC_ACTIVE_COUNT; Key == ?METRICS_DC
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
declare_metric(Key, Meta, Desc) when Key == ?METRICS_DOWNLINK ->
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

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

metrics_test() ->
    ok = application:set_env(prometheus, collectors, [
        prometheus_boolean,
        prometheus_counter,
        prometheus_gauge,
        prometheus_histogram
    ]),
    ok = application:set_env(router, metrics, [
        {reporters, [?MODULE]},
        {?MODULE, [{port, 3000}]}
    ]),
    {ok, _} = application:ensure_all_started(prometheus),
    {ok, Pid} = router_metrics:start_link(#{}),

    ?assertEqual(
        <<"0">>,
        extract_data(erlang:atom_to_list(?METRICS_SC_ACTIVE_COUNT), prometheus_text_format:format())
    ),

    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?METRICS_SC_ACTIVE, 1, []}),
    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?METRICS_SC_ACTIVE_COUNT, 2, []}),
    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?METRICS_DC, 3, []}),
    ok = router_metrics:routing_offer_observe(join, accepted, accepted, 4),
    ok = router_metrics:routing_packet_observe(join, rejected, rejected, 5),
    ok = router_metrics:packet_trip_observe_start(<<"packethash">>, <<"pubkeybin">>, 0),
    ok = router_metrics:packet_trip_observe_end(<<"packethash">>, <<"pubkeybin">>, 6, packet, true),
    ok = router_metrics:decoder_observe(decoder, ok, 7),
    ok = router_metrics:function_observe('fun', 8),
    ok = router_metrics:console_api_observe(api, ok, 9),
    ok = router_metrics:downlink_inc(http, ok),
    ok = router_metrics:ws_state(true),
    Format = prometheus_text_format:format(),
    io:format(Format),
    ?assertEqual(
        <<"1">>,
        extract_data(erlang:atom_to_list(?METRICS_SC_ACTIVE), Format)
    ),
    ?assertEqual(
        <<"2">>,
        extract_data(erlang:atom_to_list(?METRICS_SC_ACTIVE_COUNT), Format)
    ),
    ?assertEqual(
        <<"3">>,
        extract_data(erlang:atom_to_list(?METRICS_DC), Format)
    ),
    ?assertEqual(
        <<"4">>,
        extract_data(
            "router_device_routing_offer_duration_sum{type=\"join\",status=\"accepted\",reason=\"accepted\"}",
            Format
        )
    ),
    ?assertEqual(
        <<"5">>,
        extract_data(
            "router_device_routing_packet_duration_sum{type=\"join\",status=\"rejected\",reason=\"rejected\",downlink=\"false\"}",
            Format
        )
    ),
    ?assertEqual(
        <<"6">>,
        extract_data(
            "router_device_packet_trip_duration_sum{type=\"packet\",downlink=\"true\"}",
            Format
        )
    ),
    ?assertEqual(
        <<"7">>,
        extract_data(
            "router_decoder_decoded_duration_sum{type=\"decoder\",status=\"ok\"}",
            Format
        )
    ),
    ?assertEqual(
        <<"8">>,
        extract_data(
            "router_function_duration_sum{function=\"fun\"}",
            Format
        )
    ),
    ?assertEqual(
        <<"9">>,
        extract_data(
            "router_console_api_duration_sum{type=\"api\",status=\"ok\"}",
            Format
        )
    ),
    ?assertEqual(
        <<"1">>,
        extract_data(
            "router_device_downlink_packet{type=\"http\",status=\"ok\"}",
            Format
        )
    ),
    ?assertEqual(<<>>, extract_data("router_ws_state", Format)),

    gen_server:stop(Pid),
    application:stop(prometheus),
    ok.

extract_data(Key, Format) ->
    Base = "\n" ++ Key ++ " ",
    case re:run(Format, Base ++ "[0-9]*", [global]) of
        {match, [[{Pos, Len}]]} ->
            binary:replace(binary:part(Format, Pos, Len), erlang:list_to_binary(Base), <<>>);
        _ ->
            not_found
    end.

-endif.
