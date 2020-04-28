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
    Routers = ?config(routers, Config),
    Addresses = ?config(miner_pubkey_bins, Config),
    RouterAddresses = ?config(router_pubkey_bins, Config),
    Balance = 5000,
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, Balance) || Addr <- Addresses ++ RouterAddresses],
    InitialDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addresses ++ RouterAddresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),

    %% Before doing anything, check that we're in test mode
    [RouterNode | _] = Routers,
    RouterChainModInfo = ct_rpc:call(RouterNode, blockchain, module_info, []),
    ?assert(lists:member({save_block, 2}, proplists:get_value(exports, RouterChainModInfo))),

    [Miner | _] = Miners,
    MinerModInfo = ct_rpc:call(Miner, miner, module_info, []),
    ?assert(lists:member({test_version, 0}, proplists:get_value(exports, MinerModInfo))),

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

    InitialVars = miner_test:make_vars(Keys, maps:merge(DefaultVars, SCVars)),
    ct:pal("InitialVars: ~p", [InitialVars]),

    DKGResults = miner_test:inital_dkg(Miners,
                                       InitialVars ++ InitialPaymentTransactions ++ AddGwTxns ++ InitialDCTxns,
                                       Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_test:miners_by_consensus_state(Miners),

    %% integrate genesis block on non_consensus_miners
    true = miner_test:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

    %% integrate genesis block on routers
    true = miner_test:integrate_genesis_block(hd(ConsensusMiners), Routers),

    %% confirm we have a height of 1 on all miners
    ok = miner_test:wait_for_gte(height_exactly, Miners, 1),

    %% confirm we have a height of 1 on routers
    ok = miner_test:wait_for_gte(height_exactly, Routers, 1),

    [{consensus_miners, ConsensusMiners},
     {non_consensus_miners, NonConsensusMiners}
    | Config].

end_per_testcase(_TestCase, Config) ->
    router_ct_utils:end_per_testcase(_TestCase, Config).

basic_test(Config) ->
    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),
    DefaultRouters = ?config(default_routers, Config),

    [ClientNode | _] = Miners,
    [RouterNode | _] = Routers,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm: ~p", [RouterSwarm]),
    RouterP2PAddress = ct_rpc:call(RouterNode, libp2p_swarm, p2p_address, [RouterSwarm]),
    ct:pal("RouterP2PAddress: ~p", [RouterP2PAddress]),

    %% EUIs = [{?DEVEUI, ?APPEUI}],
    {Filter, _} = xor16:to_bin(xor16:new([ <<DevEUI:64/integer-unsigned-little,
                                             AppEUI:64/integer-unsigned-little>> || {DevEUI, AppEUI} <- ?EUIS],
                                         fun xxhash:hash64/1)),

    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [RouterPubkeyBin], Filter, 8, 1, 0]),
    ct:pal("OUITxn: ~p", [OUITxn]),
    SignedOUITxn = ct_rpc:call(RouterNode,
                               blockchain_txn_oui_v1,
                               sign,
                               [OUITxn, RouterSigFun]),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedOUITxn]),

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_test:wait_for_txn(Routers, CheckTypeOUI, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Routers, CheckTxnOUI, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Miners, CheckTxnOUI, timer:seconds(30)),

    Height = miner_test:height(RouterNode),

    ct:pal("Height: ~p", [Height]),
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    ct:pal("RouterChain: ~p", [RouterChain]),
    Blocks = ct_rpc:call(RouterNode, blockchain, blocks, [RouterChain]),
    ct:pal("Blocks: ~p", [Blocks]),

    %% open a state channel
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, ExpireWithin, 1, 1]),
    ct:pal("SCOpenTxn: ~p", [SCOpenTxn]),
    SignedSCOpenTxn = ct_rpc:call(RouterNode,
                                  blockchain_txn_state_channel_open_v1,
                                  sign,
                                  [SCOpenTxn, RouterSigFun]),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedSCOpenTxn]),

    %% check that sc open txn appears on miners
    CheckTypeSCOpen = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_open_v1 end,
    CheckTxnSCOpen = fun(T) -> T == SignedSCOpenTxn end,
    ok = miner_test:wait_for_txn(Miners, CheckTypeSCOpen, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Miners, CheckTxnSCOpen, timer:seconds(30)),

    %% check state_channel appears on the ledger
    {ok, SC} = miner_test:get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
    true = miner_test:check_ledger_state_channel(SC, RouterPubkeyBin, ID),
    ct:pal("SC: ~p", [SC]),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({devaddr, 1}, Payload1),
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1}, Payload2),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, DefaultRouters]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, DefaultRouters]),

    %% wait ExpireWithin + 3 more blocks to be safe
    ok = miner_test:wait_for_gte(height, Miners, Height + ExpireWithin + 3),
    %% for the state_channel_close txn to appear
    CheckTypeSCClose = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end,
    ok = miner_test:wait_for_txn(Miners, CheckTypeSCClose, timer:seconds(30)),

    %% check state_channel is removed once the close txn appears
    {error, not_found} = miner_test:get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),

    %% Check whether the balances are updated in the eventual sc close txn
    BlockDetails = miner_test:get_txn_block_details(RouterNode, CheckTypeSCClose),
    SCCloseTxn = miner_test:get_txn(BlockDetails, CheckTypeSCClose),
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_test:get_txn_block_details(RouterNode, CheckTypeSCOpen),

    %% construct what the skewed merkle tree should look like
    ExpectedTree = skewed:add(Payload2, skewed:add(Payload1, skewed:new(OpenHash))),
    %% assert the root hashes should match
    ?assertEqual(blockchain_state_channel_v1:root_hash(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn)), skewed:root_hash(ExpectedTree)),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = miner_test:check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin, 2),
    true = miner_test:check_sc_num_dcs(SCCloseTxn, ClientNodePubkeyBin, 3),

    ok.
