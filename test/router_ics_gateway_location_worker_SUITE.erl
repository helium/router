-module(router_ics_gateway_location_worker_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/iot_config_pb.hrl").
-include("console_test.hrl").

-export([
    all/0,
    groups/0,
    init_per_testcase/2,
    end_per_testcase/2,
    init_per_group/2,
    end_per_group/2
]).

-export([
    main_test/1
]).

-record(location, {
    gateway :: libp2p_crypto:pubkey_bin(),
    timestamp :: non_neg_integer(),
    h3_index :: h3:index()
}).

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
        {group, chain_alive},
        {group, chain_dead}
    ].

groups() ->
    [
        {chain_alive, [main_test]},
        {chain_dead, [main_test]}
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_group(GroupName, Config) ->
    test_utils:init_per_group(GroupName, Config).

init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_gateway_service, self()),
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_group(GroupName, Config) ->
    test_utils:end_per_group(GroupName, Config).

end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

main_test(_Config) ->
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    ExpectedIndex = h3:from_string("8828308281fffff"),
    ok = router_test_ics_gateway_service:register_gateway_location(
        PubKeyBin1,
        "8828308281fffff"
    ),

    Before = erlang:system_time(millisecond),

    %% Let worker start
    ok = test_utils:wait_until(fun() ->
        try router_ics_gateway_location_worker:get(PubKeyBin1) of
            {ok, ExpectedIndex} -> true;
            _ -> false
        catch
            _:_ ->
                false
        end
    end),

    [LocationRec] = ets:lookup(router_ics_gateway_location_worker_ets, PubKeyBin1),

    ?assertEqual(PubKeyBin1, LocationRec#location.gateway),
    ?assertEqual(ExpectedIndex, LocationRec#location.h3_index),

    Timestamp = LocationRec#location.timestamp,
    Now = erlang:system_time(millisecond),

    ?assert(Timestamp > Before),
    ?assert(Timestamp =< Now),

    [{location, Req1}] = rcv_loop([]),
    ?assertEqual(PubKeyBin1, Req1#iot_config_gateway_location_req_v1_pb.gateway),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

rcv_loop(Acc) ->
    receive
        {router_test_ics_gateway_service, Type, Req} ->
            lager:notice("got router_test_ics_gateway_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.
