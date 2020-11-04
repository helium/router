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
-define(INSERT_DATA,
    "insert into data (device_id, hotspot_id, payload_size) values ($1, $2, $3)"
).

-record(state, {}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    ReporterArgs = router_metrics:get_reporter_props(?MODULE),
    lager:info("~p init with ~p and ~p", [?MODULE, Args, ReporterArgs]),
    pgapp:connect(?POOL, [
        {size, proplists:get_value(size, ReporterArgs, 2)},
        {host, proplists:get_value(host, ReporterArgs, "localhost")},
        {port, proplists:get_value(port, ReporterArgs, 5432)},
        {database, proplists:get_value(database, ReporterArgs, "helium")},
        {username, proplists:get_value(username, ReporterArgs, "postgres")},
        {password, proplists:get_value(password, ReporterArgs, "postgres")}
    ]),
    ok = init_tables(),
    {ok, #state{}}.

handle_event({data, Key, Data, [PubKeyBin, DeviceID]}, State) when Key == ?METRICS_DEVICE_DATA ->
    ok = query_db(?INSERT_DATA, [DeviceID, libp2p_crypto:bin_to_b58(PubKeyBin), Data]),
    {ok, State};
handle_event({data, _Key, _Data, _MetaData}, State) ->
    lager:debug("ignore data ~p ~p ~p", [_Key, _Data, _MetaData]),
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

-spec init_tables() -> ok.
init_tables() ->
    lists:foreach(
        fun(Query) ->
            query_db(Query, [])
        end,
        [
            "CREATE SEQUENCE IF NOT EXISTS data_id_seq INCREMENT 1 MINVALUE 1 MAXVALUE 2147483647 START 1 CACHE 1;",
            "CREATE TABLE IF NOT EXISTS \"public\".\"data\" (\n"
            "    \"id\" integer DEFAULT nextval('data_id_seq') NOT NULL,\n"
            "    \"device_id\" text NOT NULL,\n"
            "    \"hotspot_id\" text NOT NULL,\n"
            "    \"payload_size\" bigint NOT NULL,\n"
            "    \"created\" timestamp DEFAULT CURRENT_TIMESTAMP,\n"
            "    CONSTRAINT \"data_id\" PRIMARY KEY (\"id\")\n"
            ") WITH (oids = false);",
            "CREATE TABLE IF NOT EXISTS \"public\".\"devices\" (\n"
            "    \"id\" text NOT NULL,\n"
            "    \"org_id\" text NOT NULL,\n"
            "    \"hotspot_id\" text NOT NULL,\n"
            "    \"updated\" timestamp DEFAULT CURRENT_TIMESTAMP,\n"
            "    CONSTRAINT \"devices_id\" PRIMARY KEY (\"id\")\n"
            ") WITH (oids = false);",
            "CREATE TABLE IF NOT EXISTS \"public\".\"hotspots\" (\n"
            "    \"id\" text NOT NULL,\n"
            "    \"name\" text NOT NULL,\n"
            "    \"lat\" double precision NOT NULL,\n"
            "    \"long\" double precision NOT NULL,\n"
            "    \"created\" timestamp DEFAULT CURRENT_TIMESTAMP,\n"
            "    CONSTRAINT \"hotspots_id\" PRIMARY KEY (\"id\")\n"
            ") WITH (oids = false);"
        ]
    ).

-spec query_db(string(), list(any())) -> ok.
query_db(Query, Params) ->
    case pgapp:equery(?POOL, Query, Params) of
        {error, _Reason} ->
            lager:error("query ~p failed: ~p : ~p", [Query, Params, _Reason]);
        {ok, _} ->
            ok;
        {ok, _, _} ->
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

    #{public := Pubkey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(Pubkey),
    DeviceUpdates = [
        {name, <<"Test Device Name">>},
        {location, PubKeyBin},
        {devaddr, <<3, 4, 0, 72>>}
    ],
    Device = router_device:update(DeviceUpdates, router_device:new(<<"test_device_id">>)),
    ok = router_metrics:data_inc(PubKeyBin, router_device:id(Device), 10),

    gen_server:stop(Pid),
    application:stop(pgapp),
    ok.

-endif.
