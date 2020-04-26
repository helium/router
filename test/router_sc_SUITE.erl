-module(router_sc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("router_ct_macros.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
         basic_test/1
        ]).

%% common test callbacks

all() -> [
          basic_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(TestCase, Config0) ->
    Config = router_ct_utils:init_per_testcase(?MODULE, TestCase, Config0),
    Miners = ?config(miners, Config),
    Addresses = ?config(miner_pubkey_bins, Config),
    Balance = 5000,
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    InitialDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),
    Routers = ?config(routers, Config),

    SCVars = #{?max_open_sc => 2,                    %% Max open state channels per router, set to 2
               ?min_expire_within => 10,             %% Min state channel expiration (# of blocks)
               ?max_xor_filter_size => 1024*100,     %% Max xor filter size, set to 1024*100
               ?max_xor_filter_num => 5,             %% Max number of xor filters, set to 5
               ?max_subnet_size => 65536,            %% Max subnet size
               ?min_subnet_size => 8,                %% Min subnet size
               ?max_subnet_num => 20,                %% Max subnet num
               ?sc_grace_blocks => 5},               %% Grace period (in num of blocks) for state channels to get GCd

    DefaultVars = #{?block_time => BlockTime,
                    %% rule out rewards
                    ?election_interval => infinity,
                    ?num_consensus_members => NumConsensusMembers,
                    ?batch_size => BatchSize,
                    ?dkg_curve => Curve},

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = router_ct_utils:make_vars(Keys, maps:merge(DefaultVars, SCVars)),
    ct:pal("InitialVars: ~p", [InitialVars]),

    DKGResults = router_ct_utils:inital_dkg(Miners,
                                            InitialVars ++ InitialPaymentTransactions ++ AddGwTxns ++ InitialDCTxns,
                                            Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = router_ct_utils:miners_by_consensus_state(Miners),

    %% integrate genesis block on non_consensus_miners
    true = router_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

    %% integrate genesis block on routers
    true = router_ct_utils:integrate_genesis_block(hd(ConsensusMiners), Routers),

    %% confirm we have a height of 1 on all miners
    ok = router_ct_utils:wait_for_gte(height_exactly, Miners, 1),

    %% confirm we have a height of 1 on routers
    ok = router_ct_utils:wait_for_gte(height_exactly, Routers, 1),

    [{consensus_miners, ConsensusMiners},
     {non_consensus_miners, NonConsensusMiners}
    | Config].

end_per_testcase(_TestCase, Config) ->
    router_ct_utils:end_per_testcase(_TestCase, Config).

basic_test(Config) ->
    Miners = ?config(miners, Config),
    ct:pal("Config: ~p", [Config]),
    ct:pal("Miners: ~p", [Miners]),

    ok.
