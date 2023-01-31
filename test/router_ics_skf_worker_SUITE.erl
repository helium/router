-module(router_ics_skf_worker_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1
]).

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
    [
        main_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_route_service, self()),
    Port = 8085,
    ServerPid = start_server(Port),
    ok = application:set_env(
        router,
        ics,
        #{host => "localhost", port => Port},
        [{persistent, true}]
    ),
    test_utils:init_per_testcase(TestCase, [{ics_server, ServerPid} | Config]).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config),
    ServerPid = proplists:get_value(ics_server, Config),
    case erlang:is_process_alive(ServerPid) of
        true -> gen_server:stop(ServerPid);
        false -> ok
    end,
    _ = application:stop(grpcbox),
    ok = application:set_env(
        router,
        ics,
        #{},
        [{persistent, true}]
    ),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

main_test(_Config) ->
    meck:new(router_console_api, [passthrough]),
    meck:new(router_device_cache, [passthrough]),

    timer:sleep(5000),

    ?assertEqual([], rcv_loop([])),

    meck:unload(router_console_api),
    meck:unload(router_device_cache),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

start_server(Port) ->
    _ = application:ensure_all_started(grpcbox),
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [iot_config_pb],
            services => #{'helium.iot_config.skf' => router_test_ics_skf_service}
        },
        listen_opts => #{port => Port, ip => {0, 0, 0, 0}}
    }),
    ServerPid.

rcv_loop(Acc) ->
    receive
        {router_test_ics_skf_service, Type, Req} ->
            lager:notice("got router_test_ics_skf_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.
