-module(router_metrics_reporter_postgres).

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

-define(POOL, router_metrics_reporter_postgres_pool).
-define(QUERY,
    "insert into test (data) values ($1)"
).

-record(state, {}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    ReporterArgs = router_metrics:get_reporter_props(?MODULE),
    lager:info("~p init with ~p and ~p", [?MODULE, Args, ReporterArgs]),
    pgapp:connect(?POOL, [
        {size, 10},
        {host, proplists:get_value(host, ReporterArgs, "localhost")},
        {port, proplists:get_value(port, ReporterArgs, 5432)},
        {database, proplists:get_value(database, ReporterArgs, "helium")},
        {username, proplists:get_value(username, ReporterArgs, "postgres")},
        {password, proplists:get_value(password, ReporterArgs, "postgres")}
    ]),
    {ok, #state{}}.

handle_event({data, Key, _Data, _MetaData}, State) ->
    ok = query_db([erlang:atom_to_list(Key)]),
    {ok, State};
handle_event(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
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

-spec query_db(list(any())) -> ok.
query_db(Params) ->
    case pgapp:equery(?POOL, ?QUERY, Params) of
        {error, _Reason} ->
            lager:error("failed to insert gateway_earnings ~p : ~p", [Params, _Reason]);
        {ok, _} ->
            ok
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

metrics_test() ->
    ok = application:set_env(router, metrics, [
        {reporters, [?MODULE]},
        {?MODULE, [
            {host, "localhost"},
            {port, 5432},
            {database, "helium"},
            {username, "postgres"},
            {password, "postgres"}
        ]}
    ]),
    {ok, _} = application:ensure_all_started(pgapp),
    {ok, Pid} = router_metrics:start_link(#{}),

    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?SC_ACTIVE, 1, []}),
    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?SC_ACTIVE_COUNT, 2, []}),
    ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?DC, 3, []}),
    ok = router_metrics:routing_offer_observe(join, accepted, accepted, 4),
    ok = router_metrics:routing_packet_observe(join, rejected, rejected, 5),
    ok = router_metrics:packet_trip_observe_start(<<"packethash">>, <<"pubkeybin">>, 0),
    ok = router_metrics:packet_trip_observe_end(<<"packethash">>, <<"pubkeybin">>, 6, packet, true),
    ok = router_metrics:decoder_observe(decoder, ok, 7),
    ok = router_metrics:function_observe('fun', 8),
    ok = router_metrics:console_api_observe(api, ok, 9),
    ok = router_metrics:downlink_inc(http, ok),
    ok = router_metrics:ws_state(true),

    gen_server:stop(Pid),
    application:stop(pgapp),
    ok.

-endif.
