-module(router_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).


-export([
         routing_test/1
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
     routing_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = "data/test_SUITE/" ++ erlang:atom_to_list(TestCase),
    Balance = 5000,
    {ok, Sup, {PrivKey, PubKey}} = test_utils:init(BaseDir),
    {ok, GenesisMembers, ConsensusMembers, Keys} = test_utils:init_chain(Balance, {PrivKey, PubKey}),

    Chain = blockchain_worker:blockchain(),
    Swarm = blockchain_swarm:swarm(),
    N = length(ConsensusMembers),

                                                % Check ledger to make sure everyone has the right balance
    Ledger = blockchain:ledger(Chain),
    Entries = blockchain_ledger_v1:entries(Ledger),
    _ = lists:foreach(fun(Entry) ->
                              Balance = blockchain_ledger_entry_v1:balance(Entry),
                              0 = blockchain_ledger_entry_v1:nonce(Entry)
                      end, maps:values(Entries)),

    [
     {basedir, BaseDir},
     {balance, Balance},
     {sup, Sup},
     {pubkey, PubKey},
     {privkey, PrivKey},
     {chain, Chain},
     {swarm, Swarm},
     {n, N},
     {consensus_members, ConsensusMembers},
     {genesis_members, GenesisMembers},
     Keys
     | Config
    ].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_, Config) ->
    Sup = proplists:get_value(sup, Config),
                                                % Make sure blockchain saved on file = in memory
    case erlang:is_process_alive(Sup) of
        true ->
            true = erlang:exit(Sup, normal),
            ok = test_utils:wait_until(fun() -> false =:= erlang:is_process_alive(Sup) end);
        false ->
            ok
    end,
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

routing_test(Config) ->
    BaseDir = proplists:get_value(basedir, Config),
    ConsensusMembers = proplists:get_value(consensus_members, Config),
    BaseDir = proplists:get_value(basedir, Config),
    Chain = proplists:get_value(chain, Config),
    Swarm = proplists:get_value(swarm, Config),
    Ledger = blockchain:ledger(Chain),

    [_, {Payer, {_, PayerPrivKey, _}}|_] = ConsensusMembers,
    SigFun = libp2p_crypto:mk_sig_fun(PayerPrivKey),

    meck:new(blockchain_txn_oui_v1, [no_link, passthrough]),
    meck:expect(blockchain_txn_oui_v1, is_valid, fun(_, _) -> ok end),

    OUI1 = 1,
    Addresses0 = [erlang:list_to_binary(libp2p_swarm:p2p_address(Swarm))],
    OUITxn0 = blockchain_txn_oui_v1:new(Payer, Addresses0, OUI1, 0, 0),
    SignedOUITxn0 = blockchain_txn_oui_v1:sign(OUITxn0, SigFun),

    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    Block0 = test_utils:create_block(ConsensusMembers, [SignedOUITxn0]),
    _ = blockchain_gossip_handler:add_block(Swarm, Block0, Chain, self()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    Routing0 = blockchain_ledger_routing_v1:new(OUI1, Payer, Addresses0, 0),
    ?assertEqual({ok, Routing0}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    Addresses1 = [<<"/p2p/random">>],
    OUITxn2 = blockchain_txn_routing_v1:new(OUI1, Payer, Addresses1, 0, 1),
    SignedOUITxn2 = blockchain_txn_routing_v1:sign(OUITxn2, SigFun),
    Block1 = test_utils:create_block(ConsensusMembers, [SignedOUITxn2]),
    _ = blockchain_gossip_handler:add_block(Swarm, Block1, Chain, self()),

    ok = test_utils:wait_until(fun() -> {ok, 3} == blockchain:height(Chain) end),

    Routing1 = blockchain_ledger_routing_v1:new(OUI1, Payer, Addresses1, 1),
    ?assertEqual({ok, Routing1}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    OUI2 = 2,
    Addresses0 = [erlang:list_to_binary(libp2p_swarm:p2p_address(Swarm))],
    OUITxn3 = blockchain_txn_oui_v1:new(Payer, Addresses0, OUI2, 0, 0),
    SignedOUITxn3 = blockchain_txn_oui_v1:sign(OUITxn3, SigFun),

    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI2, Ledger)),

    Block2 = test_utils:create_block(ConsensusMembers, [SignedOUITxn3]),
    _ = blockchain_gossip_handler:add_block(Swarm, Block2, Chain, self()),

    ok = test_utils:wait_until(fun() -> {ok, 4} == blockchain:height(Chain) end),

    Routing2 = blockchain_ledger_routing_v1:new(OUI2, Payer, Addresses0, 0),
    ?assertEqual({ok, Routing2}, blockchain_ledger_v1:find_routing(OUI2, Ledger)),

    ?assertEqual({ok, [2, 1]}, blockchain_ledger_v1:find_ouis(Payer, Ledger)),

    ?assert(meck:validate(blockchain_txn_oui_v1)),
    meck:unload(blockchain_txn_oui_v1),
    ok.
