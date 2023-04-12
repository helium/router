-module(router_device_devaddr_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    allocate/1,
    allocate_config_service_single_address/1,
    allocate_config_service_multiple_address/1,
    allocate_config_service_noncontigious_address/1,
    allocate_config_service_noncontigious_addresss_wrap/1,
    route_packet/1
]).

-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").
-include("console_test.hrl").

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
    [
        allocate,
        allocate_config_service_single_address,
        allocate_config_service_multiple_address,
        allocate_config_service_noncontigious_address,
        allocate_config_service_noncontigious_addresss_wrap,
        route_packet
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config0) ->
    Config1 = test_utils:init_per_testcase(TestCase, Config0),
    Config2 = test_utils:add_oui(Config1),
    Config2.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

allocate(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_device_devaddr),
        erlang:element(3, State) =/= []
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

allocate_config_service_single_address(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_device_devaddr),
        erlang:element(3, State) =/= []
    end),

    %% Override after picking up from chain
    ok = router_device_devaddr:set_devaddr_bases([{1, 1}]),

    DevAddrs = lists:map(
        fun(_I) ->
            {ok, DevAddr} = router_device_devaddr:allocate(undef, PubKeyBin),
            DevAddr
        end,
        lists:seq(1, 16)
    ),
    ?assertEqual(16, erlang:length(DevAddrs)),
    ?assertEqual(1, erlang:length(lists:usort(DevAddrs))),

    ok.

allocate_config_service_multiple_address(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_device_devaddr),
        erlang:element(3, State) =/= []
    end),

    %% Override after picking up from chain
    ok = router_device_devaddr:set_devaddr_bases([{1, 5}]),

    DevAddrs = lists:map(
        fun(_I) ->
            {ok, DevAddr} = router_device_devaddr:allocate(undef, PubKeyBin),
            DevAddr
        end,
        lists:seq(1, 16)
    ),
    ?assertEqual(16, erlang:length(DevAddrs)),
    ?assertEqual(5, erlang:length(lists:usort(DevAddrs))),
    ok.

allocate_config_service_noncontigious_address(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_device_devaddr),
        erlang:element(3, State) =/= []
    end),

    %% Override after picking up from chain
    ok = router_device_devaddr:set_devaddr_bases([{1, 3}, {5, 8}]),

    DevAddrs = lists:map(
        fun(_I) ->
            {ok, DevAddr} = router_device_devaddr:allocate(undef, PubKeyBin),
            DevAddr
        end,
        lists:seq(1, 16)
    ),
    ?assertEqual(16, erlang:length(DevAddrs)),
    ?assertEqual(
        [
            <<1, 0, 0, 72>>,
            <<2, 0, 0, 72>>,
            <<3, 0, 0, 72>>,
            <<5, 0, 0, 72>>,
            <<6, 0, 0, 72>>,
            <<7, 0, 0, 72>>,
            <<8, 0, 0, 72>>
        ],
        lists:usort(DevAddrs)
    ),

    ok.

allocate_config_service_noncontigious_addresss_wrap(_Config) ->
    %% Using a single pubkeybin and a standin for multiple pubkeybins that
    %% resolve the same h3 parent index. Make sure the devaddrs wrap independent
    %% of each other.
    meck:delete(router_device_devaddr, allocate, 2, false),

    [Key1, Key2, Key3] = lists:map(
        fun(_Idx) ->
            #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
            libp2p_crypto:pubkey_to_bin(PubKey)
        end,
        lists:seq(1, 3)
    ),

    meck:expect(router_device_devaddr, h3_parent_for_pubkeybin, fun(Key) ->
        {ok, maps:get(Key, #{Key1 => 1, Key2 => 2, Key3 => 3})}
    end),

    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_device_devaddr),
        erlang:element(3, State) =/= []
    end),

    %% Override after picking up from chain
    ok = router_device_devaddr:set_devaddr_bases([{1, 3}]),

    CollectNAddrsForKey = fun(N, Key) ->
        lists:map(
            fun(_I) ->
                {ok, DevAddr} = router_device_devaddr:allocate(undef, Key),
                DevAddr
            end,
            lists:seq(1, N)
        )
    end,

    AsDevaddrs = fun(Nums) ->
        lists:map(fun(Num) -> <<Num, 0, 0, $H>> end, Nums)
    end,

    ?assertEqual(AsDevaddrs([1, 2, 3, 1]), CollectNAddrsForKey(4, Key1)),
    ?assertEqual(AsDevaddrs([1, 2, 3]), CollectNAddrsForKey(3, Key2)),
    ?assertEqual(AsDevaddrs([1, 2]), CollectNAddrsForKey(2, Key3)),

    ?assertEqual(AsDevaddrs([2, 3, 1, 2]), CollectNAddrsForKey(4, Key1)),
    ?assertEqual(AsDevaddrs([1, 2, 3]), CollectNAddrsForKey(3, Key2)),
    ?assertEqual(AsDevaddrs([3, 1]), CollectNAddrsForKey(2, Key3)),

    ok.

route_packet(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    ok = test_utils:wait_until(fun() ->
        State = sys:get_state(router_device_devaddr),
        erlang:element(2, State) =/= undefined
    end),

    #{
        pubkey_bin := PubKeyBin,
        stream := Stream,
        hotspot_name := HotspotName
    } = test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),
    DevAddr = router_device:devaddr(Device0),

    ?assert(DevAddr =/= undefined),

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
        <<"type">> => <<"uplink">>,
        <<"replay">> => false,
        <<"uuid">> => fun erlang:is_binary/1,
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"downlink_url">> =>
            <<?CONSOLE_URL/binary, "/api/v1/down/", ?CONSOLE_HTTP_CHANNEL_ID/binary, "/",
                ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN/binary, "/", ?CONSOLE_DEVICE_ID/binary>>,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
        <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
        <<"metadata">> => #{
            <<"labels">> => ?CONSOLE_LABELS,
            <<"organization_id">> => ?CONSOLE_ORG_ID,
            <<"multi_buy">> => fun erlang:is_integer/1,
            <<"adr_allowed">> => false,
            <<"cf_list_enabled">> => false,
            <<"rx_delay_state">> => fun erlang:is_binary/1,
            <<"rx_delay">> => 0,
            <<"preferred_hotspots">> => fun erlang:is_list/1
        },
        <<"fcnt">> => 0,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"payload">> => <<>>,
        <<"payload_size">> => 0,
        <<"raw_packet">> => fun erlang:is_binary/1,
        <<"port">> => 1,
        <<"devaddr">> => lorawan_utils:binary_to_hex(DevAddr),
        <<"hotspots">> => [
            #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"reported_at">> => fun erlang:is_integer/1,
                <<"hold_time">> => fun erlang:is_integer/1,
                <<"status">> => <<"success">>,
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        ],
        <<"dc">> => #{
            <<"balance">> => fun erlang:is_integer/1,
            <<"nonce">> => fun erlang:is_integer/1
        }
    }),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
