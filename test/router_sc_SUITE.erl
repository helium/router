-module(router_sc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("utils/router_ct_macros.hrl").
-include("lorawan_vars.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0,
         groups/0,
         init_per_group/2,
         end_per_group/2
        ]).

-export([
         maintain_channels_test/1,
         handle_packets_test/1,
         default_routers_test/1,
         no_oui_test/1,
         no_dc_entry_test/1
        ]).

-define(SFLOCS, [631210968910285823, 631210968909003263, 631210968912894463, 631210968907949567]).
-define(NYLOCS, [631243922668565503, 631243922671147007, 631243922895615999, 631243922665907711]).
-define(get_mod_version(SCMOD, Version), list_to_atom(lists:concat([SCMOD, Version]))).

%% common test callbacks

groups() ->
    [
     {sc_v1,
      [],
      test_cases()
     },
     {sc_v2,
      [],
      test_cases()
     }].

all() ->
    [{group, sc_v1}, {group, sc_v2}].

test_cases() ->
    [
     maintain_channels_test,
     handle_packets_test,
     default_routers_test,
     no_oui_test,
     no_dc_entry_test
    ].

init_per_suite(Config) ->
    %% init_per_suite is the FIRST thing that runs and is common for both groups

    SCVars = #{?max_open_sc => 2,                    %% Max open state channels per router, set to 2
               ?min_expire_within => 10,             %% Min state channel expiration (# of blocks)
               ?max_xor_filter_size => 1024*100,     %% Max xor filter size, set to 1024*100
               ?max_xor_filter_num => 5,             %% Max number of xor filters, set to 5
               ?max_subnet_size => 65536,            %% Max subnet size
               ?min_subnet_size => 8,                %% Min subnet size
               ?max_subnet_num => 20,                %% Max subnet num
               ?dc_payload_size => 24,               %% DC payload size for calculating DCs
               ?sc_grace_blocks => 5},               %% Grace period (in num of blocks) for state channels to get GCd
    [{sc_vars, SCVars} | Config].

end_per_suite(Config) ->
    Config.

init_per_group(sc_v1, Config) ->
    %% This is only for configuration and checking purposes
    [{sc_version, 1} | Config];
init_per_group(sc_v2, Config) ->
    SCVars = ?config(sc_vars, Config),
    SCV2Vars = maps:merge(SCVars,
                          #{?sc_version => 2,
                            ?sc_overcommit => 2
                           }),
    [{sc_vars, SCV2Vars}, {sc_version, 2} | Config].

end_per_group(_, _Config) ->
    ok.

init_per_testcase(TestCase, Config0) ->
    application:ensure_all_started(lager),
    Config = router_ct_utils:init_per_testcase(?MODULE, TestCase, Config0),
    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),
    Addresses = ?config(miner_pubkey_bins, Config),
    RouterAddresses = ?config(router_pubkey_bins, Config),
    Balance = 5000,
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, Balance) || Addr <- Addresses ++ RouterAddresses],

    InitialDCTxns = case TestCase of
                        no_dc_entry_test ->
                            %% Dont give the router any dcs
                            [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addresses];
                        _ ->
                            [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addresses ++ RouterAddresses]
                    end,

    Locations = ?SFLOCS ++ ?NYLOCS,
    AddressesWithLocations = lists:zip(Addresses, lists:sublist(Locations, length(Addresses))),
    AddGwTxns  = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- AddressesWithLocations],

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

    SCVars = ?config(sc_vars, Config),
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

    MinersAndPorts = ?config(ports, Config),
    RadioPorts = [ P || {_Miner, {_TP, P}} <- MinersAndPorts ],
    miner_test_fake_radio_backplane:start_link(8, 45000, lists:zip(RadioPorts, lists:sublist(Locations, length(RadioPorts)))),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_test:miners_by_consensus_state(Miners),

    %% integrate genesis block on non_consensus_miners
    true = miner_test:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

    %% integrate genesis block on routers
    true = miner_test:integrate_genesis_block(hd(ConsensusMiners), Routers),

    %% confirm we have a height of 1 on all miners
    ok = miner_test:wait_for_gte(height, Miners, 1),

    %% confirm we have a height of 1 on routers
    ok = miner_test:wait_for_gte(height, Routers, 1),

    miner_test_fake_radio_backplane ! go,

    NewConfig =  [{consensus_miners, ConsensusMiners}, {non_consensus_miners, NonConsensusMiners} |
                  Config],
    ct:pal("Config: ~p", [NewConfig]),
    NewConfig.

end_per_testcase(_TestCase, Config) ->
    router_ct_utils:end_per_testcase(_TestCase, Config).

maintain_channels_test(Config) ->
    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),
    SCVersion = ?config(sc_version, Config),
    [RouterNode | _] = Routers,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),

    DevEUI = ?DEVEUI,
    AppEUI = ?APPEUI,

    {Filter, _} = xor16:to_bin(xor16:new([<<DevEUI/binary, AppEUI/binary>>],
                                         fun xxhash:hash64/1)),

    OUI = 1,
    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [OUI, RouterPubkeyBin, [RouterPubkeyBin], Filter, 8]),

    %% fees are not enabled on the chain, but lets calculate anyway in case they do get added later
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    TxnFee = ct_rpc:call(RouterNode, blockchain_txn_oui_v1, calculate_fee, [OUITxn, RouterChain]),
    StakingFee = ct_rpc:call(RouterNode, blockchain_txn_oui_v1, calculate_staking_fee, [OUITxn, RouterChain]),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, TxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, StakingFee),
    ct:pal("OUITxn: ~p", [OUITxn1]),

    SignedOUITxn = ct_rpc:call(RouterNode,
                               blockchain_txn_oui_v1,
                               sign,
                               [OUITxn1, RouterSigFun]),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedOUITxn]),

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_test:wait_for_txn(Routers, CheckTypeOUI, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Routers, CheckTxnOUI, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Miners, CheckTxnOUI, timer:seconds(30)),

    %% check that the router sees that the oui counter is up-to-date
    RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
    {ok, 1} = ct_rpc:call(RouterNode, blockchain_ledger_v1, get_oui_counter, [RouterLedger]),

    RouterState = ct_rpc:call(RouterNode, sys, get_state, [router_sc_worker]),
    ct:pal("Before RouterState: ~p", [RouterState]),
    true = miner_test:wait_until(fun() ->
                                         RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
                                         MySCs = ct_rpc:call(RouterNode, blockchain_state_channels_server, state_channels, []),
                                         {ok, SCs} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_scs_by_owner, [RouterPubkeyBin, RouterLedger]),
                                         map_size(SCs) == 2 andalso map_size(MySCs) == 2
                                 end, 30, timer:seconds(1)),

    RouterState2 = ct_rpc:call(RouterNode, sys, get_state, [router_sc_worker]),
    ct:pal("Mid RouterState: ~p", [RouterState2]),

    %% Wait 200 blocks, for multiple sc open txns to have occured
    true = miner_test:wait_until(fun() ->
                                         {ok, RouterChainHeight} = ct_rpc:call(RouterNode, blockchain, height, [RouterChain]),
                                         RouterChainHeight > 450
                                 end, 300, timer:seconds(30)),

    %% Since we've set the default expiration = 45 in router_sc_worker
    %% at the very minimum, we should be at nonce = 4
    SCLedgerMod = ?get_mod_version(blockchain_ledger_state_channel_v, SCVersion),
    true = miner_test:wait_until(fun() ->
                                         RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
                                         {ok, LedgerSCs} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_scs_by_owner, [RouterPubkeyBin, RouterLedger]),
                                         {_, S} = hd(lists:sort(fun({_, S1}, {_, S2}) ->
                                                                        SCLedgerMod:nonce(S1) >= SCLedgerMod:nonce(S2)
                                                                end,
                                                                maps:to_list(LedgerSCs))),
                                         SCLedgerMod:nonce(S) >= 4
                                 end, 60, timer:seconds(5)),

    RouterState3 = ct_rpc:call(RouterNode, sys, get_state, [router_sc_worker]),
    ct:pal("Final RouterState: ~p", [RouterState3]),

    ok.

handle_packets_test(Config) ->
    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),

    [RouterNode | _] = Routers,
    ct:pal("Routernode is ~p", [RouterNode]),

    ClientPubkeyBins = [ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []) || Miner <- Miners],

    %% router_sc_worker must be inactive before oui txn
    false = ct_rpc:call(RouterNode, router_sc_worker, is_active, []),

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),

    DevEUI = lorawan_utils:reverse(?DEVEUI),
    AppEUI = lorawan_utils:reverse(?APPEUI),
    {Filter, _} = xor16:to_bin(xor16:new([<<DevEUI/binary, AppEUI/binary>>],
                                         fun xxhash:hash64/1)),

    OUI = 1,
    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [OUI, RouterPubkeyBin, [RouterPubkeyBin], Filter, 8]),
    %% fees are not enabled on the chain, but lets calculate anyway in case they do get added later
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    TxnFee = ct_rpc:call(RouterNode, blockchain_txn_oui_v1, calculate_fee, [OUITxn, RouterChain]),
    StakingFee = ct_rpc:call(RouterNode, blockchain_txn_oui_v1, calculate_staking_fee, [OUITxn, RouterChain]),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, TxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, StakingFee),
    ct:pal("OUITxn: ~p", [OUITxn1]),

    SignedOUITxn = ct_rpc:call(RouterNode,
                               blockchain_txn_oui_v1,
                               sign,
                               [OUITxn, RouterSigFun]),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedOUITxn]),

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_test:wait_for_txn(Routers ++ Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Routers ++ Miners, CheckTxnOUI, timer:seconds(30)),

    RouterState = ct_rpc:call(RouterNode, sys, get_state, [router_sc_worker]),
    ct:pal("Before RouterState: ~p", [RouterState]),

    %% router_sc_worker must have become active now
    true = ct_rpc:call(RouterNode, router_sc_worker, is_active, []),

    true = miner_test:wait_until(fun() ->
                                         RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
                                         MySCs = ct_rpc:call(RouterNode, blockchain_state_channels_server, state_channels, []),
                                         {ok, SCs} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_scs_by_owner, [RouterPubkeyBin, RouterLedger]),
                                         map_size(SCs) == 2 andalso map_size(MySCs) == 2
                                 end, 30, timer:seconds(1)),

    %% At this point, we're certain that two state channels have been opened by the router
    %% Use client node to send some packets
    DevNonce = crypto:strong_rand_bytes(2),
    Packet = test_utils:join_payload(?APPKEY, DevNonce),
    ok = miner_test_fake_radio_backplane:transmit(Packet, 902.300, 631210968910285823),
    ct:pal("transmitted packet ~p", [Packet]),

    miner_test_fake_radio_backplane:get_next_packet(),
    {DevAddr, NetKey, AppKey} = receive
                                    {fake_radio_backplane, ReplyPacket} ->
                                        ct:pal("got downlink ~p", [ReplyPacket]),
                                        ReplyPayload = maps:get(<<"data">>, ReplyPacket),
                                        {_NetID, DA, _DLSettings, _RxDelay, NK, AK} = test_utils:deframe_join_packet(#packet_pb{payload=base64:decode(ReplyPayload)}, DevNonce, ?APPKEY),
                                        {DA, NK, AK}
                                after 5000 ->
                                        ct:fail("no downlink")
                                end,

    ct:pal("DevAddr ~p", [DevAddr]),

    DataPacket = test_utils:frame_payload(?CONFIRMED_UP, DevAddr, NetKey, AppKey, 1, #{body => <<1:8/integer, "hello">>}),

    ok = miner_test_fake_radio_backplane:transmit(DataPacket, 902.300, 631210968910285823),
    ct:pal("transmitted packet ~p", [DataPacket]),

    miner_test_fake_radio_backplane:get_next_packet(),

    receive
        {fake_radio_backplane, ReplyPacket2} ->
            ct:pal("got downlink ~p", [ReplyPacket2])
    after
        5000 ->
            ct:fail("no downlink")
    end,


    %% Wait 100 blocks
    true = miner_test:wait_until(fun() ->
                                         {ok, RouterChainHeight} = ct_rpc:call(RouterNode, blockchain, height, [RouterChain]),
                                         RouterChainHeight > 100
                                 end, 60, timer:seconds(5)),

    %% Find all sc close txns

    RouterBlocks = ct_rpc:call(RouterNode, blockchain, blocks, [RouterChain]),

    Txns = lists:map(fun({I, B}) ->
                             Ts = blockchain_block:transactions(B),
                             {I, Ts}
                     end, maps:to_list(RouterBlocks)),

    SCCloseFiltered = lists:map(fun({I, Ts}) ->
                                        {I, lists:filter(fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end, Ts)}
                                end, Txns),

    ct:pal("SCCloseFiltered: ~p", [SCCloseFiltered]),

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
    2 = blockchain_state_channel_summary_v1:num_dcs(Summary),
    true = lists:member(blockchain_state_channel_summary_v1:client_pubkeybin(Summary), ClientPubkeyBins),

    ok.

default_routers_test(Config) ->
    Miners = ?config(miners, Config),

    %% Set default routers for miners
    RouterPubkeyBins = ?config(router_pubkey_bins, Config),
    DefaultRouters = [libp2p_crypto:pubkey_bin_to_p2p(P) || P <- RouterPubkeyBins],
    true = miner_test:set_miner_default_routers(Miners, DefaultRouters),

    %% Use client node to send some packets
    DevNonce = crypto:strong_rand_bytes(2),
    Packet = test_utils:join_payload(?APPKEY, DevNonce),
    ok = miner_test_fake_radio_backplane:transmit(Packet, 902.300, 631210968910285823),
    ct:pal("transmitted packet ~p", [Packet]),

    miner_test_fake_radio_backplane:get_next_packet(),
    {DevAddr, NetKey, AppKey} = receive
                                    {fake_radio_backplane, ReplyPacket} ->
                                        ct:pal("got downlink ~p", [ReplyPacket]),
                                        ReplyPayload = maps:get(<<"data">>, ReplyPacket),
                                        {_NetID, DA, _DLSettings, _RxDelay, NK, AK} = test_utils:deframe_join_packet(#packet_pb{payload=base64:decode(ReplyPayload)}, DevNonce, ?APPKEY),
                                        {DA, NK, AK}
                                after 5000 ->
                                        ct:fail("no downlink")
                                end,

    ct:pal("DevAddr ~p", [DevAddr]),

    DataPacket = test_utils:frame_payload(?CONFIRMED_UP, DevAddr, NetKey, AppKey, 1, #{body => <<1:8/integer, "hello">>}),

    ok = miner_test_fake_radio_backplane:transmit(DataPacket, 902.300, 631210968910285823),
    ct:pal("transmitted packet ~p", [DataPacket]),

    miner_test_fake_radio_backplane:get_next_packet(),

    receive
        {fake_radio_backplane, ReplyPacket2} ->
            ct:pal("got downlink ~p", [ReplyPacket2])
    after
        2000 ->
            ct:fail("no downlink")
    end,

    ok.

no_oui_test(Config) ->
    %% If there is no oui on chain, don't try to open any state channels

    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),

    [RouterNode | _] = Routers,

    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),

    %% no ouis on the ledger
    {ok, 0} = ct_rpc:call(RouterNode, blockchain_ledger_v1, get_oui_counter, [RouterLedger]),
    %% Check that router_sc_worker is inactive
    false = ct_rpc:call(RouterNode, router_sc_worker, is_active, []),
    0 = ct_rpc:call(RouterNode, router_sc_worker, active_count, []),

    %% Wait for 50 blocks
    ok = miner_test:wait_for_gte(height, Miners, 50),
    ok = miner_test:wait_for_gte(height, Routers, 50),

    %% Same checks again
    {ok, 0} = ct_rpc:call(RouterNode, blockchain_ledger_v1, get_oui_counter, [RouterLedger]),
    false = ct_rpc:call(RouterNode, router_sc_worker, is_active, []),
    0 = ct_rpc:call(RouterNode, router_sc_worker, active_count, []),

    ok.

no_dc_entry_test(Config) ->
    Miners = ?config(miners, Config),
    Routers = ?config(routers, Config),
    SCVersion = ?config(sc_version, Config),

    [PayerNode | _] = Miners,
    {ok, PayerPubkey, PayerSigFun, _} = ct_rpc:call(PayerNode, blockchain_swarm, keys, []),
    PayerPubkeyBin = libp2p_crypto:pubkey_to_bin(PayerPubkey),

    [RouterNode | _] = Routers,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),

    DevEUI = ?DEVEUI,
    AppEUI = ?APPEUI,

    {Filter, _} = xor16:to_bin(xor16:new([<<DevEUI/binary, AppEUI/binary>>],
                                         fun xxhash:hash64/1)),

    OUI = 1,
    OUITxn = ct_rpc:call(PayerNode,
                         blockchain_txn_oui_v1,
                         new,
                         [OUI, RouterPubkeyBin, [RouterPubkeyBin], Filter, 8, PayerPubkeyBin]),
    %% fees are not enabled on the chain, but lets calculate anyway in case they do get added later
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    TxnFee = ct_rpc:call(RouterNode, blockchain_txn_oui_v1, calculate_fee, [OUITxn, RouterChain]),
    StakingFee = ct_rpc:call(RouterNode, blockchain_txn_oui_v1, calculate_staking_fee, [OUITxn, RouterChain]),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, TxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, StakingFee),
    ct:pal("OUITxn: ~p", [OUITxn1]),

    SignedOUITxn0 = ct_rpc:call(RouterNode,
                                blockchain_txn_oui_v1,
                                sign,
                                [OUITxn1, RouterSigFun]),

    %% payer must also sign the oui txn
    SignedOUITxn = ct_rpc:call(PayerNode,
                               blockchain_txn_oui_v1,
                               sign_payer,
                               [SignedOUITxn0, PayerSigFun]),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    ok = ct_rpc:call(PayerNode, blockchain_worker, submit_txn, [SignedOUITxn]),

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_test:wait_for_txn(Routers ++ Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_test:wait_for_txn(Routers ++ Miners, CheckTxnOUI, timer:seconds(30)),

    %% check that the router sees that the oui counter is up-to-date
    RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
    {ok, 1} = ct_rpc:call(RouterNode, blockchain_ledger_v1, get_oui_counter, [RouterLedger]),

    RouterState = ct_rpc:call(RouterNode, sys, get_state, [router_sc_worker]),
    ct:pal("Before RouterState: ~p", [RouterState]),

    true = miner_test:wait_until(fun() ->
                                         RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
                                         MySCs = ct_rpc:call(RouterNode, blockchain_state_channels_server, state_channels, []),
                                         ct:pal("MySCs: ~p", [MySCs]),
                                         {ok, SCs} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_scs_by_owner, [RouterPubkeyBin, RouterLedger]),
                                         map_size(SCs) == 2 andalso map_size(MySCs) == 2
                                 end, 30, timer:seconds(1)),

    RouterState2 = ct_rpc:call(RouterNode, sys, get_state, [router_sc_worker]),
    ct:pal("Mid RouterState: ~p", [RouterState2]),

    %% Wait 200 blocks, for multiple sc open txns to have occured
    true = miner_test:wait_until(fun() ->
                                         {ok, RouterChainHeight} = ct_rpc:call(RouterNode, blockchain, height, [RouterChain]),
                                         RouterChainHeight > 200
                                 end, 60, timer:seconds(5)),

    %% Since we've set the default expiration = 45 in router_sc_worker
    %% at the very minimum, we should be at nonce = 4
    SCLedgerMod = ?get_mod_version(blockchain_ledger_state_channel_v, SCVersion),
    true = miner_test:wait_until(fun() ->
                                         RouterLedger = ct_rpc:call(RouterNode, blockchain, ledger, [RouterChain]),
                                         {ok, LedgerSCs} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_scs_by_owner, [RouterPubkeyBin, RouterLedger]),
                                         {_, S} = hd(lists:sort(fun({_, S1}, {_, S2}) ->
                                                                        SCLedgerMod:nonce(S1) >= SCLedgerMod:nonce(S2)
                                                                end,
                                                                maps:to_list(LedgerSCs))),
                                         SCLedgerMod:nonce(S) >= 4
                                 end, 60, timer:seconds(5)),

    RouterState3 = ct_rpc:call(RouterNode, sys, get_state, [router_sc_worker]),
    ct:pal("Final RouterState: ~p", [RouterState3]),

    ok.
