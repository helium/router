-module(test_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
         init/1, init_chain/2,
         generate_keys/1, generate_keys/2,
         wait_until/1, wait_until/3,
         create_block/2,
         tmp_dir/0, tmp_dir/1,
         nonl/1,
         atomic_save/2
        ]).

init(BaseDir) ->
    ok = application:set_env(router, base_dir, BaseDir),
    {ok, Sup} = router_sup:start_link(),
    ?assert(erlang:is_pid(Sup)),
    SwarmKey = filename:join([BaseDir, "router", "swarm_key"]),
    {ok, #{secret := PrivKey, public := PubKey}} = libp2p_crypto:load_keys(SwarmKey),
    {ok, Sup, {PrivKey, PubKey}}.

init_chain(Balance, {PrivKey, PubKey}) ->
    % Generate fake blockchain nodes (just the keys)
    RandomKeys = ?MODULE:generate_keys(10),
    Address = blockchain_swarm:pubkey_bin(),
    GenesisMembers = [
                      {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
                     ] ++ RandomKeys,

                                                % Create genesis block
    {InitialVars, Keys} = create_vars(#{}),

    GenPaymentTxs = [blockchain_txn_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- GenesisMembers],

    GenSecPaymentTxs = [blockchain_txn_security_coinbase_v1:new(Addr, Balance)
                        || {Addr, _} <- GenesisMembers],

    Addresses = [Addr || {Addr, _} <- GenesisMembers],

    Locations = lists:foldl(
                  fun(I, Acc) ->
                          [h3:from_geo({37.780586, -122.469470 + I/100}, 12)|Acc]
                  end,
                  [],
                  lists:seq(1, length(Addresses))
                 ),
    InitialGatewayTxn = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0)
                         || {Addr, Loc} <- lists:zip(Addresses, Locations)],

    ConsensusMembers = lists:sublist(GenesisMembers, 7),
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new(
                            [Addr || {Addr, _} <- ConsensusMembers], <<"proof">>, 1, 0),
    Txs = InitialVars ++
        GenPaymentTxs ++
        GenSecPaymentTxs ++
        InitialGatewayTxn ++
        [GenConsensusGroupTx],
    lager:info("initial transactions: ~p", [Txs]),

    GenesisBlock = blockchain_block:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_block:hash_block(HeadBlock)),
    ?assertEqual({ok, GenesisBlock}, blockchain:head_block(Chain)),
    ?assertEqual({ok, blockchain_block:hash_block(GenesisBlock)}, blockchain:genesis_hash(Chain)),
    ?assertEqual({ok, GenesisBlock}, blockchain:genesis_block(Chain)),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    {ok, GenesisMembers, ConsensusMembers, Keys}.

generate_keys(N) ->
    generate_keys(N, ecc_compact).

generate_keys(N, Type) ->
    lists:foldl(
      fun(_, Acc) ->
              #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(Type),
              SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
              [{libp2p_crypto:pubkey_to_bin(PubKey), {PubKey, PrivKey, SigFun}}|Acc]
      end
     ,[]
     ,lists:seq(1, N)
     ).

wait_until(Fun) ->
    wait_until(Fun, 40, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.

create_block(ConsensusMembers, Txs) ->
    Blockchain = blockchain_worker:blockchain(),
    {ok, PrevHash} = blockchain:head_hash(Blockchain),
    {ok, HeadBlock} = blockchain:head_block(Blockchain),
    Height = blockchain_block:height(HeadBlock) + 1,
    Time = blockchain_block:time(HeadBlock) + 1,
    Block0 = blockchain_block_v1:new(#{prev_hash => PrevHash,
                                       height => Height,
                                       transactions => lists:sort(fun blockchain_txn:sort/2, Txs),
                                       signatures => [],
                                       time => Time,
                                       hbbft_round => 0,
                                       election_epoch => 1,
                                       epoch_start => 0
                                      }),
    BinBlock = blockchain_block:serialize(Block0),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:set_signatures(Block0, Signatures),
    Block1.

signatures(ConsensusMembers, BinBlock) ->
    lists:foldl(
      fun({A, {_, _, F}}, Acc) ->
              Sig = F(BinBlock),
              [{A, Sig}|Acc];
         %% NOTE: This clause matches the consensus members generated for the dist suite
         ({A, _, F}, Acc) ->
              Sig = F(BinBlock),
              [{A, Sig}|Acc]
      end
     ,[]
     ,ConsensusMembers
     ).

tmp_dir() ->
    ?MODULE:nonl(os:cmd("mktemp -d")).

tmp_dir(Dir) ->
    filename:join(tmp_dir(), Dir).

nonl([$\n|T]) -> nonl(T);
nonl([H|T]) -> [H|nonl(T)];
nonl([]) -> [].

%%--------------------------------------------------------------------
%% @doc
%% @end
%%-------------------------------------------------------------------
-spec atomic_save(file:filename_all(), binary() | string()) -> ok | {error, any()}.
atomic_save(File, Bin) ->
    ok = filelib:ensure_dir(File),
    TmpFile = File ++ "-tmp",
    ok = file:write_file(TmpFile, Bin),
    file:rename(TmpFile, File).

%%====================================================================
%% Internal functions
%%====================================================================

create_vars(Vars) ->
    #{secret := Priv, public := Pub} =
        libp2p_crypto:generate_keys(ecc_compact),

    Vars1 = raw_vars(Vars),
    ct:pal("vars ~p", [Vars1]),

    BinPub = libp2p_crypto:pubkey_to_bin(Pub),

    Txn = blockchain_txn_vars_v1:new(Vars1, 2, #{master_key => BinPub}),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    Txn1 = blockchain_txn_vars_v1:key_proof(Txn, Proof),
    {[Txn1], {master_key, {Priv, Pub}}}.


raw_vars(Vars) ->
    DefVars = #{
                ?chain_vars_version => 2,
                ?vars_commit_delay => 10,
                ?election_version => 2,
                ?election_restart_interval => 5,
                ?election_replacement_slope => 20,
                ?election_replacement_factor => 4,
                ?election_selection_pct => 70,
                ?election_removal_pct => 85,
                ?election_cluster_res => 8,
                ?block_version => v1,
                ?predicate_threshold => 0.85,
                ?num_consensus_members => 7,
                ?monthly_reward => 50000 * 1000000,
                ?securities_percent => 0.35,
                ?poc_challengees_percent => 0.19 + 0.16,
                ?poc_challengers_percent => 0.09 + 0.06,
                ?poc_witnesses_percent => 0.02 + 0.03,
                ?consensus_percent => 0.10,
                ?min_assert_h3_res => 12,
                ?max_staleness => 100000,
                ?alpha_decay => 0.007,
                ?beta_decay => 0.0005,
                ?block_time => 30000,
                ?election_interval => 30,
                ?poc_challenge_interval => 30,
                ?h3_exclusion_ring_dist => 2,
                ?h3_max_grid_distance => 13,
                ?h3_neighbor_res => 12,
                ?min_score => 0.15,
                ?reward_version => 1
               },

    maps:merge(DefVars, Vars).
