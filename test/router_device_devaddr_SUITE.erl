-module(router_device_devaddr_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([allocate/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).

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
    [allocate].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

allocate(Config) ->
    Swarm = proplists:get_value(swarm, Config),
    Keys = proplists:get_value(keys, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    ConsensusMembers = proplists:get_value(consensus_member, Config),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    OUI1 = 1,
    {Filter, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn = blockchain_txn_oui_v1:new(OUI1, PubKeyBin, [PubKeyBin], Filter, 8, 1, 0),
    #{secret := PrivKey} = Keys,
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    SignedOUITxn = blockchain_txn_oui_v1:sign(OUITxn, SigFun),

    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
    _ = blockchain_gossip_handler:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    ok = test_utils:wait_until(fun() ->
                                       State = sys:get_state(router_device_devaddr),
                                       erlang:element(2, State) =/= undefined
                               end),

    DevAddrs = lists:foldl(fun(_I, Acc) ->
                                   {ok, DevAddr} = router_device_devaddr:allocate(undef, PubKeyBin),
                                   [DevAddr|Acc]
                           end,
                           [],
                           lists:seq(1, 10)),
    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, DevAddrs]),

    ct:fail(ok),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
