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
    persistent_term:put(router_test_ics_skf_service, self()),
    Port = 8085,
    ServerPid = start_server(Port),
    ok = application:set_env(
        router,
        ics,
        #{skf_enabled => "true", host => "localhost", port => Port},
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

    Devices = lists:map(
        fun(X) ->
            ID = router_utils:uuid_v4(),
            router_device:update(
                [
                    {devaddrs, [<<X:32/integer-unsigned-big>>]},
                    {keys, [{crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(16)}]}
                ],
                router_device:new(ID)
            )
        end,
        lists:seq(1, 2)
    ),

    meck:expect(router_device_cache, get, fun() ->
        lager:notice("router_device_cache:get()"),
        BadDevice = router_device:new(<<"bad_device">>),
        [BadDevice | Devices]
    end),

    router_test_ics_skf_service:send_list(
        #iot_config_session_key_filter_v1_pb{
            oui = 0,
            devaddr = 0,
            session_key = <<>>
        },
        true
    ),

    [{Type3, Req3}, {Type2, Req2}, {Type1, Req1}, {Type0, _Req0}] = rcv_loop([]),
    [Device1, Device2] = Devices,

    ?assertEqual(list, Type0),
    ?assertEqual(update, Type1),
    ?assertEqual(remove, Req1#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = 0, devaddr = 0, session_key = <<>>
        },
        Req1#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type2),
    ?assertEqual(add, Req2#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = 1,
            session_key = router_device:nwk_s_key(Device1)
        },
        Req2#iot_config_session_key_filter_update_req_v1_pb.filter
    ),
    ?assertEqual(update, Type3),
    ?assertEqual(add, Req3#iot_config_session_key_filter_update_req_v1_pb.action),
    ?assertEqual(
        #iot_config_session_key_filter_v1_pb{
            oui = router_utils:get_oui(),
            devaddr = 2,
            session_key = router_device:nwk_s_key(Device2)
        },
        Req3#iot_config_session_key_filter_update_req_v1_pb.filter
    ),

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
            services => #{
                'helium.iot_config.session_key_filter' => router_test_ics_skf_service
            }
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
