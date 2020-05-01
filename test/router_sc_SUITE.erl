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
         maintain_channels_test/1,
         handle_packets_test/1
        ]).

%% common test callbacks

all() -> [
          maintain_channels_test,
          handle_packets_test
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
    ct:pal("MinerModInfo: ~p", [MinerModInfo]),
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

    NewConfig =  [{consensus_miners, ConsensusMiners}, {non_consensus_miners, NonConsensusMiners} |
                  Config],
    ct:pal("Config: ~p", [NewConfig]),
    NewConfig.

end_per_testcase(_TestCase, Config) ->
    router_ct_utils:end_per_testcase(_TestCase, Config).

maintain_channels_test(Config) ->
    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),

    [RouterNode | _] = Routers,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),

    DevEUI = ?DEVEUI,
    AppEUI = ?APPEUI,

    {Filter, _} = xor16:to_bin(xor16:new([<<DevEUI:64/integer-unsigned-little, AppEUI:64/integer-unsigned-little>>],
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

    RouterState = ct_rpc:call(RouterNode, router_sc_worker, state, []),
    ct:pal("Before RouterState: ~p", [RouterState]),

    true = miner_test:wait_until(fun() ->
                                         RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
                                         RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
                                         MySCs = ct_rpc:call(RouterNode, blockchain_state_channels_server, state_channels, []),
                                         {ok, SCs} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_scs_by_owner, [RouterPubkeyBin, RouterLedger]),
                                         map_size(SCs) == 2 andalso map_size(MySCs) == 2
                                 end, 30, timer:seconds(1)),

    RouterState2 = ct_rpc:call(RouterNode, router_sc_worker, state, []),
    ct:pal("Mid RouterState: ~p", [RouterState2]),

    %% Wait 200 blocks, for multiple sc open txns to have occured
    true = miner_test:wait_until(fun() ->
                                         RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
                                         {ok, RouterChainHeight} = ct_rpc:call(RouterNode, blockchain, height, [RouterChain]),
                                         RouterChainHeight > 200
                                 end, 60, timer:seconds(5)),

    %% Since we've set the default expiration = 45 in router_sc_worker
    %% at the very minimum, we should be at nonce = 4
    true = miner_test:wait_until(fun() ->
                                         RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
                                         RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
                                         {ok, LedgerSCs} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_scs_by_owner, [RouterPubkeyBin, RouterLedger]),
                                         {_, S} = hd(lists:sort(fun({_, S1}, {_, S2}) ->
                                                                        blockchain_ledger_state_channel_v1:nonce(S1) >= blockchain_ledger_state_channel_v1:nonce(S2)
                                                                end,
                                                                maps:to_list(LedgerSCs))),
                                         blockchain_ledger_state_channel_v1:nonce(S) >= 4
                                 end, 60, timer:seconds(5)),

    RouterState3 = ct_rpc:call(RouterNode, router_sc_worker, state, []),
    ct:pal("Final RouterState: ~p", [RouterState3]),

    ok.

handle_packets_test(Config) ->
    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),

    [RouterNode | _] = Routers,
    [ClientNode | _] = Miners,

    ClientPubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),

    DevEUI = ?DEVEUI,
    AppEUI = ?APPEUI,
    {Filter, _} = xor16:to_bin(xor16:new([<<DevEUI:64/integer-unsigned-little, AppEUI:64/integer-unsigned-little>>],
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

    RouterState = ct_rpc:call(RouterNode, router_sc_worker, state, []),
    ct:pal("Before RouterState: ~p", [RouterState]),

    true = miner_test:wait_until(fun() ->
                                         RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
                                         RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
                                         MySCs = ct_rpc:call(RouterNode, blockchain_state_channels_server, state_channels, []),
                                         {ok, SCs} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_scs_by_owner, [RouterPubkeyBin, RouterLedger]),
                                         map_size(SCs) == 2 andalso map_size(MySCs) == 2
                                 end, 30, timer:seconds(1)),

    %% At this point, we're certain that two state channels have been opened by the router
    %% Use client node to send some packets
    Packet = <<?JOIN_REQUEST:3, 0:5, AppEUI:64/integer-unsigned-little, DevEUI:64/integer-unsigned-little, 1111:16/integer-unsigned-big, 0:32/integer-unsigned-big>>,
    ok = ct_rpc:call(ClientNode, miner_test_fake_radio_backplane, transmit, [Packet, 911.200, 631210968910285823]),

    %% Wait 100 blocks
    true = miner_test:wait_until(fun() ->
                                         RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
                                         {ok, RouterChainHeight} = ct_rpc:call(RouterNode, blockchain, height, [RouterChain]),
                                         RouterChainHeight > 100
                                 end, 60, timer:seconds(5)),

    %% Find all sc close txns
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    RouterBlocks = ct_rpc:call(RouterNode, blockchain, blocks, [RouterChain]),

    Txns = lists:map(fun({I, B}) ->
                             Ts = blockchain_block:transactions(B),
                             {I, Ts}
                     end, maps:to_list(RouterBlocks)),

    SCCloseFiltered = lists:map(fun({I, Ts}) ->
                                        {I, lists:filter(fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end, Ts)}
                                end, Txns),

    SCCloses = lists:flatten(lists:foldl(fun({_I, List}, Acc) ->
                                                 case length(List) /= 0 of
                                                     true -> [Acc | List];
                                                     false -> Acc
                                                 end
                                         end, [], SCCloseFiltered)),

    ct:pal("SCCloses: ~p", [SCCloses]),

    Summary = hd(lists:flatten(lists:foldl(fun(SCCloseTxn, Acc) ->
                                                   SC = blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn),
                                                   Summaries = blockchain_state_channel_v1:summaries(SC),
                                                   [Summaries | Acc]
                                           end,
                                           [],
                                           SCCloses))),

    ct:pal("Summary: ~p", [Summary]),

    2 = blockchain_state_channel_summary_v1:num_packets(Summary),
    3 = blockchain_state_channel_summary_v1:num_dcs(Summary),
    ClientPubkeyBin = blockchain_state_channel_summary_v1:client_pubkeybin(Summary),

    ok.
