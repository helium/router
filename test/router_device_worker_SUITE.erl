-module(router_device_worker_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([refresh_channels_test/1,
         crashing_channel_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).
-define(ETS, ?MODULE).
-define(BACKOFF_MIN, timer:seconds(15)).
-define(BACKOFF_MAX, timer:minutes(5)).
-define(BACKOFF_INIT,
        {backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
         erlang:make_ref()}).

-record(state, {db :: rocksdb:db_handle(),
                cf :: rocksdb:cf_handle(),
                device :: router_device:device(),
                join_cache = #{} :: map(),
                frame_cache = #{} :: map(),
                event_mgr :: pid(),
                channels = #{} :: map(),
                channels_backoffs = #{} :: map()}).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [refresh_channels_test, crashing_channel_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(router, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, router_device_api_module, router_device_api_console),
    ok = application:set_env(router, console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, console_secret, <<"secret">>),
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    %% FormatStr = ["[", date, " ", time, "] ", pid, " [", severity,"]",  {nodeid, [" [", nodeid, "]"], ""}, " [",
    %%             {module, ""}, {function, [":", function], ""}, {line, [":", line], ""}, "] ", message, "\n"],
    %% ok = application:set_env(lager, handlers, [{lager_console_backend, [{level, debug}, {formatter_config, FormatStr}]}]),
    Tab = ets:new(?ETS, [public, set]),
    AppKey = crypto:strong_rand_bytes(16),
    ElliOpts = [
                {callback, console_callback},
                {callback_args, #{forward => self(), ets => Tab,
                                  app_key => AppKey, app_eui => ?APPEUI, dev_eui => ?DEVEUI}},
                {port, 3000}
               ],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),
    [{app_key, AppKey}, {ets, Tab}, {elli, Pid}, {base_dir, BaseDir}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(250),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    e2qc:teardown(console_cache),
    ok = application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

refresh_channels_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {no_channel, true}),

    %% Starting worker with no channels
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),

    %% Waiting for worker to init properly
    timer:sleep(250),

    %% Checking worker's channels, should only be "no_channel"
    State0 = sys:get_state(WorkerPid),
    ?assertEqual(#{<<"no_channel">> => router_channel:new(<<"no_channel">>,
                                                          router_no_channel,
                                                          <<"no_channel">>,
                                                          #{},
                                                          DeviceID,
                                                          WorkerPid)},
                 State0#state.channels),

    %% Add 2 http channels and force a refresh
    HTTPChannel1 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"show_dupes">> => false,
                     <<"id">> => <<"HTTP_1">>,
                     <<"name">> => <<"HTTP_NAME_1">>},
    HTTPChannel2 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"show_dupes">> => false,
                     <<"id">> => <<"HTTP_2">>,
                     <<"name">> => <<"HTTP_NAME_2">>},
    ets:insert(Tab, {no_channel, false}),
    ets:insert(Tab, {channels, [HTTPChannel1, HTTPChannel2]}),
    WorkerPid ! refresh_channels,
    timer:sleep(250),
    State1 = sys:get_state(WorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State1#state.device, WorkerPid, HTTPChannel1),
                   <<"HTTP_2">> => convert_channel(State1#state.device, WorkerPid, HTTPChannel2)},
                 State1#state.channels),

    %% Modify HTTP Channel 2
    HTTPChannel2_1 = #{<<"type">> => <<"http">>,
                       <<"credentials">> => #{<<"headers">> => #{},
                                              <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                              <<"method">> => <<"PUT">>},
                       <<"show_dupes">> => false,
                       <<"id">> => <<"HTTP_2">>,
                       <<"name">> => <<"HTTP_NAME_2">>},
    ets:insert(Tab, {channels, [HTTPChannel1, HTTPChannel2_1]}),
    WorkerPid ! refresh_channels,
    timer:sleep(250),
    State2 = sys:get_state(WorkerPid),
    ?assertEqual(2, maps:size(State2#state.channels)),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State2#state.device, WorkerPid, HTTPChannel1),
                   <<"HTTP_2">> => convert_channel(State2#state.device, WorkerPid, HTTPChannel2_1)},
                 State2#state.channels),

    %% Remove HTTP Channel 1 and update 2 back to normal
    ets:insert(Tab, {channels, [HTTPChannel2]}),
    WorkerPid ! refresh_channels,
    timer:sleep(250),
    State3 = sys:get_state(WorkerPid),
    ?assertEqual(#{<<"HTTP_2">> => convert_channel(State3#state.device, WorkerPid, HTTPChannel2)},
                 State3#state.channels),

    gen_server:stop(WorkerPid),
    ok.

crashing_channel_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    HTTPChannel1 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"show_dupes">> => false,
                     <<"id">> => <<"HTTP_1">>,
                     <<"name">> => <<"HTTP_NAME_1">>},
    ets:insert(Tab, {no_channel, false}),
    ets:insert(Tab, {channels, [HTTPChannel1]}),

    meck:new(router_http_channel, [passthrough]),
    meck:expect(router_http_channel, handle_info, fun(Msg, _State) -> erlang:throw(Msg) end),

    %% Starting worker with no channels
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),

    %% Waiting for worker to init properly
    timer:sleep(250),

    %% Check that HTTP 1 is in there
    State0 = sys:get_state(WorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State0#state.device, WorkerPid, HTTPChannel1)},
                 State0#state.channels),
    {Backoff0, _} = maps:get(<<"HTTP_1">>, State0#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff0)),

    %% Crash channel
    EvtMgr = State0#state.event_mgr,
    ?assert(erlang:is_pid(EvtMgr)),
    EvtMgr ! crash_http_channel,
    timer:sleep(250),

    %% Check that HTTP 1 is still in there after crash
    State1 = sys:get_state(WorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State1#state.device, WorkerPid, HTTPChannel1)},
                 State1#state.channels),
    {Backoff1, _} = maps:get(<<"HTTP_1">>, State1#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff1)),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"failure">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"channel_crash">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"channel_id">> => <<"HTTP_1">>,
                                            <<"channel_name">> => <<"HTTP_NAME_1">>}),

    %% Crash channel and crash on init
    meck:expect(router_http_channel, init, fun(_Args) -> {error, init_failed} end),
    timer:sleep(10),
    EvtMgr ! crash_http_channel,
    timer:sleep(250),

    %% Check that HTTP 1 is gone and that backoff increased
    State2 = sys:get_state(WorkerPid),
    ?assertEqual(#{}, State2#state.channels),
    {Backoff2, _} = maps:get(<<"HTTP_1">>, State2#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN * 2, backoff:get(Backoff2)),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"failure">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"channel_crash">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"channel_id">> => <<"HTTP_1">>,
                                            <<"channel_name">> => <<"HTTP_NAME_1">>}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"failure">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"start_channel_failure">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"channel_id">> => <<"HTTP_1">>,
                                            <<"channel_name">> => <<"HTTP_NAME_1">>}),

    %% Fix crash and wait for HTTP channel to come back
    meck:unload(router_http_channel),
    timer:sleep(?BACKOFF_MIN * 2 + 250),
    State3 = sys:get_state(WorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State3#state.device, WorkerPid, HTTPChannel1)},
                 State1#state.channels),
    {Backoff3, _} = maps:get(<<"HTTP_1">>, State3#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff3)),

    gen_server:stop(WorkerPid),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------


-spec convert_channel(router_device:device(), pid(), map()) -> false | router_channel:channel().
convert_channel(Device, DeviceWorkerPid, #{<<"type">> := <<"http">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_http_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{url =>  kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             headers => maps:to_list(kvc:path([<<"credentials">>, <<"headers">>], JSONChannel)),
             method => list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], JSONChannel)))},
    DeviceID = router_device:id(Device),
    Dupes = kvc:path([<<"show_dupes">>], JSONChannel, false),
    Channel = router_channel:new(ID, Handler, Name, Dupes, Args, DeviceID, DeviceWorkerPid),
    Channel;
convert_channel(Device, DeviceWorkerPid, #{<<"type">> := <<"mqtt">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_mqtt_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{endpoint => kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Dupes = kvc:path([<<"show_dupes">>], JSONChannel, false),
    Channel = router_channel:new(ID, Handler, Name, Dupes, Args, DeviceID, DeviceWorkerPid),
    Channel;
convert_channel(Device, DeviceWorkerPid, #{<<"type">> := <<"aws">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_aws_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{aws_access_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_access_key">>], JSONChannel)),
             aws_secret_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_secret_key">>], JSONChannel)),
             aws_region => binary_to_list(kvc:path([<<"credentials">>, <<"aws_region">>], JSONChannel)),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Dupes = kvc:path([<<"show_dupes">>], JSONChannel, false),
    Channel = router_channel:new(ID, Handler, Name, Dupes, Args, DeviceID, DeviceWorkerPid),
    Channel;
convert_channel(_Device, _DeviceWorkerPid, _Channel) ->
    false.
