-module(router_ics_gateway_location_worker_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").
-include("console_test.hrl").
-include("lorawan_vars.hrl").

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
    persistent_term:put(router_test_ics_gateway_service, self()),
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
    timer:sleep(5000),
    %% Let worker start
    test_utils:wait_until(fun() ->
        erlang:is_pid(erlang:whereis(router_ics_gateway_location_worker))
    end),

    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),

    ?assertEqual(
        {ok, h3:from_string("8828308281fffff")}, router_ics_gateway_location_worker:get(PubKeyBin1)
    ),

    [{location, Req1}] = rcv_loop([]),
    ?assertEqual(PubKeyBin1, Req1#iot_config_gateway_location_req_v1_pb.gateway),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

start_server(Port) ->
    _ = application:ensure_all_started(grpcbox),
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [iot_config_pb],
            services => #{
                'helium.iot_config.gateway' => router_test_ics_gateway_service
            }
        },
        listen_opts => #{port => Port, ip => {0, 0, 0, 0}}
    }),
    ServerPid.

rcv_loop(Acc) ->
    receive
        {router_test_ics_gateway_service, Type, Req} ->
            lager:notice("got router_test_ics_gateway_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.
