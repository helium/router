-module(router_device_devaddr_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([allocate/1, route_packet/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

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
    [allocate, route_packet].

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
    OUITxn = blockchain_txn_oui_v1:new(OUI1, PubKeyBin, [PubKeyBin], Filter, 8),
    OUITxnFee = blockchain_txn_oui_v1:calculate_fee(OUITxn, Chain),
    OUITxnStakingFee = blockchain_txn_oui_v1:calculate_staking_fee(OUITxn, Chain),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, OUITxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, OUITxnStakingFee),

    #{secret := PrivKey} = Keys,
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    SignedOUITxn = blockchain_txn_oui_v1:sign(OUITxn1, SigFun),

    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
    _ = blockchain_gossip_handler:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_device_devaddr),
        erlang:element(2, State) =/= undefined andalso
            erlang:element(4, State) =/= []
    end),

    DevAddrs = lists:foldl(
        fun(_I, Acc) ->
            {ok, DevAddr} = router_device_devaddr:allocate(undef, PubKeyBin),
            [DevAddr | Acc]
        end,
        [],
        lists:seq(1, 16)
    ),
    ?assertEqual(16, erlang:length(DevAddrs)),

    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    Expected = [
        <<(I - 1):25/integer-unsigned-little, DevAddrPrefix:7/integer>>
        || I <- lists:seq(1, 8)
    ],
    ?assertEqual(lists:sort(Expected ++ Expected), lists:sort(DevAddrs)),
    ok.

route_packet(Config) ->
    Swarm = proplists:get_value(swarm, Config),
    Keys = proplists:get_value(keys, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    ConsensusMembers = proplists:get_value(consensus_member, Config),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    OUI1 = 1,
    {Filter, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn = blockchain_txn_oui_v1:new(OUI1, PubKeyBin, [PubKeyBin], Filter, 8),
    OUITxnFee = blockchain_txn_oui_v1:calculate_fee(OUITxn, Chain),
    OUITxnStakingFee = blockchain_txn_oui_v1:calculate_staking_fee(OUITxn, Chain),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, OUITxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, OUITxnStakingFee),

    #{secret := PrivKey} = Keys,
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    SignedOUITxn = blockchain_txn_oui_v1:sign(OUITxn1, SigFun),

    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
    _ = blockchain_gossip_handler:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_device_devaddr),
        erlang:element(2, State) =/= undefined
    end),

    AppKey = proplists:get_value(app_key, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for report device status on that join request
    test_utils:wait_report_device_status(#{
        <<"category">> => <<"activation">>,
        <<"description">> => '_',
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"frame_up">> => 0,
        <<"frame_down">> => 0,
        <<"payload_size">> => fun erlang:is_integer/1,
        <<"port">> => '_',
        <<"devaddr">> => '_',
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"selected">> => true,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"channels">> => []
    }),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),
    DevAddr = router_device:devaddr(Device0),

    ?assert(DevAddr =/= undefined),
    ?assert(DevAddr =/= router_device_devaddr:default_devaddr()),

    Stream !
        {send,
            test_utils:frame_packet(
                ?UNCONFIRMED_UP,
                PubKeyBin,
                router_device:nwk_s_key(Device0),
                router_device:app_s_key(Device0),
                0,
                #{devaddr => DevAddr}
            )},

    %% Waiting for data from HTTP channel
    test_utils:wait_channel_data(#{
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> =>
            <<?CONSOLE_URL/binary, "/api/v1/down/", ?CONSOLE_HTTP_CHANNEL_ID/binary, "/",
                ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN/binary, "/", ?CONSOLE_DEVICE_ID/binary>>,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"port">> => 1,
        <<"devaddr">> => lorawan_utils:binary_to_hex(DevAddr),
        <<"dc">> => fun erlang:is_map/1,
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ]
    }),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
