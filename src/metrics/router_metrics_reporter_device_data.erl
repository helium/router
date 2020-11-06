-module(router_metrics_reporter_device_data).

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

-define(INSERT_DATA,
    "insert into data (device_id, hotspot_id, payload_size) values ($1, $2, $3)"
).

-define(MAYBE_UPDATE_DEVICE,
    "INSERT INTO devices (id, org_id, hotspot_id) VALUES ($1, $2, $3)\n" ++
        "ON CONFLICT (id)\n" ++
        "DO UPDATE SET org_id = $2, hotspot_id = $3, updated=CURRENT_TIMESTAMP"
).

-define(MAYBE_UPDATE_HOTSPOT,
    "INSERT INTO hotspots (id, name, lat, long) VALUES ($1, $2, $3, $4)\n" ++
        "ON CONFLICT (id)\n" ++
        "DO UPDATE SET lat = $3, long = $4, updated=CURRENT_TIMESTAMP"
).

-define(TICK_INTERVAL, timer:minutes(5)).
-define(TICK, '__router_metrics_reporter_device_data_tick').
-define(BACKOFF_MIN, timer:seconds(10)).
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    args :: map(),
    conn :: pid() | undefined,
    conn_backoff :: backoff:backoff()
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    ReporterArgs = router_metrics:get_reporter_props(?MODULE),
    lager:info("~p init with ~p and ~p", [?MODULE, Args, ReporterArgs]),
    DBArgs = #{
        host => proplists:get_value(host, ReporterArgs, "localhost"),
        port => proplists:get_value(port, ReporterArgs, 5432),
        database => proplists:get_value(database, ReporterArgs, "helium"),
        username => proplists:get_value(username, ReporterArgs, "postgres"),
        password => proplists:get_value(password, ReporterArgs, "postgres")
    },
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    self() ! {?MODULE, connect},
    {ok, #state{args = DBArgs, conn_backoff = Backoff}}.

handle_event({data, Key, Data, [PubKeyBin, DeviceID]}, #state{conn = Conn} = State) when
    Key == ?METRICS_DEVICE_DATA
->
    equery(Conn, ?INSERT_DATA, [DeviceID, libp2p_crypto:bin_to_b58(PubKeyBin), Data]),
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

handle_info({?MODULE, connect}, #state{args = Args, conn_backoff = Backoff0} = State) ->
    lager:info("connecting to postgres"),
    case epgsql:connect(Args) of
        {ok, Conn} ->
            ok = init_tables(Conn),
            self() ! ?TICK,
            {_, Backoff1} = backoff:succeed(Backoff0),
            {ok, State#state{conn = Conn, conn_backoff = Backoff1}};
        {error, _Reason} ->
            lager:error("failed to connect to postgres: ~p", [_Reason]),
            Backoff1 = reconnect(Backoff0),
            {ok, State#state{conn_backoff = Backoff1}}
    end;
handle_info(
    {'EXIT', Conn, _Reason},
    #state{conn = Conn, conn_backoff = Backoff0} = State
) ->
    lager:error("postgres connection crashed: ~p", [_Reason]),
    Backoff1 = reconnect(Backoff0),
    {ok, State#state{conn = undefined, conn_backoff = Backoff1}};
handle_info(?TICK, #state{conn = Conn} = State) ->
    lists:foreach(
        fun(Device) ->
            DeviceID = router_device:id(Device),
            Metadata = router_device:metadata(Device),
            OrgID = maps:get(organization_id, Metadata, <<"unknown">>),
            PubKeyBin = router_device:location(Device),
            HotspotID = libp2p_crypto:bin_to_b58(PubKeyBin),
            _ = equery(Conn, ?MAYBE_UPDATE_DEVICE, [DeviceID, OrgID, HotspotID]),
            HotspotName = blockchain_utils:addr2name(PubKeyBin),
            Chain = blockchain_worker:blockchain(),
            {Lat, Long} = router_utils:get_hotspot_location(PubKeyBin, Chain),
            _ = equery(Conn, ?MAYBE_UPDATE_HOTSPOT, [HotspotID, HotspotName, Lat, Long])
        end,
        router_device_cache:get()
    ),
    _ = schedule_next_tick(),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{conn = undefined}) ->
    ok;
terminate(_Reason, #state{conn = Conn}) ->
    ok = epgsql:close(Conn),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec equery(pid(), string(), list()) -> {error, any()} | {ok, any(), any()} | {ok, any()}.
equery(Conn, Query, Params) ->
    case epgsql:equery(Conn, Query, Params) of
        {error, _Reason} = Error ->
            lager:warning("query ~p failed ~p with ~p", [Query, _Reason, Params]),
            Error;
        Other ->
            Other
    end.

-spec reconnect(backoff:backoff()) -> backoff:backoff().
reconnect(Backoff0) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    erlang:send_after(Delay, self(), {?MODULE, connect}),
    lager:info("connectin in ~pms", [Delay]),
    Backoff1.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?TICK_INTERVAL, self(), ?TICK).

-spec init_tables(pid()) -> ok.
init_tables(Conn) ->
    lists:foreach(
        fun(Query) ->
            epgsql:equery(Conn, Query, [])
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
            "    \"updated\" timestamp DEFAULT CURRENT_TIMESTAMP,\n"
            "    CONSTRAINT \"hotspots_id\" PRIMARY KEY (\"id\")\n"
            ") WITH (oids = false);"
        ]
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

% router_metrics_reporter_device_data_test() ->
%     meck:new(router_utils, [passthrough]),
%     meck:expect(router_utils, get_hotspot_location, fun(_, _) ->
%         {1.098431279874, 2.401987234986}
%     end),

%     ok = application:set_env(router, metrics, [
%         {reporters, [?MODULE]},
%         {?MODULE, [
%             {host, "localhost"},
%             {port, 5432},
%             {database, "helium"},
%             {username, "postgres"},
%             {password, "postgres"}
%         ]}
%     ]),
%     {ok, _} = application:ensure_all_started(epgsql),
%     application:ensure_all_started(lager),
%     Dir = test_utils:tmp_dir("router_metrics_reporter_device_data_test"),
%     {ok, DBPid} = router_db:start_link([Dir]),
%     {ok, DB, [_, CF]} = router_db:get(),

%     #{public := Pubkey0} = libp2p_crypto:generate_keys(ecc_compact),
%     PubKeyBin0 = libp2p_crypto:pubkey_to_bin(Pubkey0),
%     DeviceID0 = <<"test">>,
%     DeviceUpdates0 = [
%         {name, <<"Test Device Name 0">>},
%         {location, PubKeyBin0},
%         {devaddr, <<3, 4, 0, 72>>},
%         {metadata, #{organization_id => uuid_v4()}}
%     ],
%     Device0 = router_device:update(DeviceUpdates0, router_device:new(DeviceID0)),
%     {ok, _} = router_device:save(DB, CF, Device0),

%     #{public := Pubkey1} = libp2p_crypto:generate_keys(ecc_compact),
%     PubKeyBin1 = libp2p_crypto:pubkey_to_bin(Pubkey1),
%     DeviceID1 = uuid_v4(),
%     DeviceUpdates1 = [
%         {name, <<"Test Device Name 1">>},
%         {location, PubKeyBin1},
%         {devaddr, <<3, 4, 0, 72>>},
%         {metadata, #{organization_id => uuid_v4()}}
%     ],
%     Device1 = router_device:update(DeviceUpdates1, router_device:new(DeviceID1)),
%     {ok, _} = router_device:save(DB, CF, Device1),

%     ok = router_device_cache:init(),
%     {ok, MetricsPid} = router_metrics:start_link(#{}),

%     ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?METRICS_SC_ACTIVE, 1, []}),
%     ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?METRICS_SC_ACTIVE_COUNT, 2, []}),
%     ok = gen_event:notify(?METRICS_EVT_MGR, {data, ?METRICS_DC, 3, []}),
%     ok = router_metrics:routing_offer_observe(join, accepted, accepted, 4),
%     ok = router_metrics:routing_packet_observe(join, rejected, rejected, 5),
%     ok = router_metrics:packet_trip_observe_start(<<"packethash">>, <<"pubkeybin">>, 0),
%     ok = router_metrics:packet_trip_observe_end(<<"packethash">>, <<"pubkeybin">>, 6, packet, true),
%     ok = router_metrics:decoder_observe(decoder, ok, 7),
%     ok = router_metrics:function_observe('fun', 8),
%     ok = router_metrics:console_api_observe(api, ok, 9),
%     ok = router_metrics:downlink_inc(http, ok),
%     ok = router_metrics:ws_state(true),

%     ok = router_metrics:data_inc(PubKeyBin0, router_device:id(Device0), 10),
%     ok = router_metrics:data_inc(PubKeyBin1, router_device:id(Device1), 11),

%     timer:sleep(3000),

%     gen_server:stop(MetricsPid),
%     gen_server:stop(DBPid),
%     ets:delete(router_device_cache_ets),
%     application:stop(epgsql),
%     ?assert(meck:validate(router_utils)),
%     meck:unload(router_utils),
%     ok.

% uuid_v4() ->
%     <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
%     Str = io_lib:format(
%         "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
%         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]
%     ),
%     list_to_binary(Str).

-endif.
