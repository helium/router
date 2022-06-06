-module(router_device_routing_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    multi_buy_test/1,
    packet_hash_cache_test/1,
    join_offer_from_strange_hotspot_test/1,
    join_offer_from_preferred_hotspot_test/1,
    join_offer_with_no_preferred_hotspot_test/1,
    packet_offer_from_strange_hotspot_test/1,
    packet_offer_from_preferred_hotspot_test/1,
    packet_offer_with_no_preferred_hotspot_test/1,
    handle_packet_from_strange_hotspot_test/1,
    handle_packet_from_preferred_hotspot_test/1,
    handle_packet_with_no_preferred_hotspot_test/1,
    handle_join_packet_from_strange_hotspot_test/1,
    handle_join_packet_from_preferred_hotspot_test/1,
    handle_join_packet_with_no_preferred_hotspot_test/1,
    handle_packet_fcnt_32_bit_rollover_test/1,
    handle_packet_wrong_fcnt_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("router_device_worker.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").
-include("include/router_device.hrl").

-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0, 0, 0, 2, 0, 0, 0, 1>>).
-define(DEVEUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).
-define(ETS, ?MODULE).

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
        multi_buy_test,
        packet_hash_cache_test,
        join_offer_from_strange_hotspot_test,
        join_offer_from_preferred_hotspot_test,
        join_offer_with_no_preferred_hotspot_test,
        packet_offer_from_strange_hotspot_test,
        packet_offer_from_preferred_hotspot_test,
        packet_offer_with_no_preferred_hotspot_test,
        handle_packet_from_strange_hotspot_test,
        handle_packet_from_preferred_hotspot_test,
        handle_packet_with_no_preferred_hotspot_test,
        handle_join_packet_from_strange_hotspot_test,
        handle_join_packet_from_preferred_hotspot_test,
        handle_join_packet_with_no_preferred_hotspot_test,
        handle_packet_fcnt_32_bit_rollover_test,
        handle_packet_wrong_fcnt_test
    ].

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

%%
%% Preferred Hotspots: join offers and handle_offer/2
%%

test_join_offer(Config, PreferredHotspots, ExpectedResult) ->
    MultibuyFun =
        case PreferredHotspots of
            [] -> fun(_, _) -> ok end;
            _ -> fun(_, _) -> throw("Multibuy isn't allowed here!") end
        end,

    meck:delete(router_device_devaddr, allocate, 2, false),

    meck:new(router_device_multibuy, [passthrough]),
    meck:expect(router_device_multibuy, maybe_buy, MultibuyFun),

    test_utils:add_oui(Config),
    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {preferred_hotspots, PreferredHotspots}),

    DevNonce = crypto:strong_rand_bytes(2),
    AppKey = proplists:get_value(app_key, Config),

    SCPacket0 = test_utils:join_packet(PubKeyBin, AppKey, DevNonce, #{
        dont_encode => true, routing => true
    }),
    Offer0 = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket0),
        blockchain_state_channel_packet_v1:hotspot(SCPacket0),
        blockchain_state_channel_packet_v1:region(SCPacket0)
    ),

    ?assertEqual(
        ExpectedResult, router_device_routing:handle_offer(Offer0, self())
    ),

    meck:unload(router_device_multibuy),
    ok.

join_offer_from_strange_hotspot_test(Config) ->
    %% Device has preferred hotspots that don't include our default hotspot.
    %% The offer should be rejected.

    test_join_offer(Config, [<<"SomeOtherPubKeyBin">>], {error, not_preferred_hotspot}).

join_offer_from_preferred_hotspot_test(Config) ->
    %% Device has preferred hotspots that do include our default hotspot.
    %% The offer should be accepted.

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    test_join_offer(Config, [PubKeyBin], ok).

join_offer_with_no_preferred_hotspot_test(Config) ->
    %% Device has no preferred hotspots.
    %% The offer should be accepted and multibuy is allowed.

    test_join_offer(Config, [], ok).

%%
%% Preferred Hotspots: packet offers and handle_offer/2
%%

test_packet_offer(Config, PreferredHotspots, ExpectedResult) ->
    MultiBuyFun =
        case PreferredHotspots of
            [] -> fun(_, _) -> ok end;
            _ -> fun(_, _) -> throw("MultiBuy shouldn't happen here!") end
        end,

    meck:delete(router_device_devaddr, allocate, 2, false),
    meck:new(router_device_multibuy, [passthrough]),
    meck:expect(router_device_multibuy, maybe_buy, MultiBuyFun),

    test_utils:add_oui(Config),

    #{pubkey_bin := StrangerPubKeyBin} = test_utils:join_device(Config),
    test_utils:wait_state_channel_message(1250),

    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Device has a preferred hotspot that isn't the one created in init_per_testcase().
    Device1 = router_device:update(
        [
            {metadata, #{preferred_hotspots => PreferredHotspots}}
        ],
        Device0
    ),
    {ok, _} = router_device_cache:save(Device1),

    NwkSKey = router_device:nwk_s_key(Device1),
    AppSKey = router_device:app_s_key(Device1),

    SCPacket0 = test_utils:frame_packet(?UNCONFIRMED_UP, StrangerPubKeyBin, NwkSKey, AppSKey, 0, #{
        dont_encode => true, routing => true, devaddr => router_device:devaddr(Device1)
    }),
    Offer0 = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket0),
        blockchain_state_channel_packet_v1:hotspot(SCPacket0),
        blockchain_state_channel_packet_v1:region(SCPacket0)
    ),

    ?assertEqual(
        ExpectedResult, router_device_routing:handle_offer(Offer0, self())
    ),

    meck:unload(router_device_multibuy),
    ok.

packet_offer_from_strange_hotspot_test(Config) ->
    %% Device has preferred hotspots that don't include our default hotspot.
    %% The offer should be rejected.

    test_packet_offer(Config, [<<"SomeOtherPubKeyBin">>], {error, not_preferred_hotspot}).

packet_offer_from_preferred_hotspot_test(Config) ->
    %% Device has preferred hotspots that do include our default hotspot.
    %% The offer should be accepted.

    #{pubkey_bin := PubKeyBin} = test_utils:join_device(Config),
    test_utils:wait_state_channel_message(1250),
    test_packet_offer(Config, [PubKeyBin], ok).

packet_offer_with_no_preferred_hotspot_test(Config) ->
    %% Device has no preferred hotspots.
    %% The offer should be accepted.

    test_packet_offer(Config, [], ok).

%%
%% Preferred Hotspots: frame packets and handle_packet/3
%%

test_frame_packet(Config, PreferredHotspots, ExpectedResult) ->
    MultiBuyFun =
        case PreferredHotspots of
            [] -> fun(_, _) -> ok end;
            _ -> fun(_, _) -> throw("Multibuy shouldn't happen here!") end
        end,

    meck:delete(router_device_devaddr, allocate, 2, false),
    meck:new(router_device_multibuy, [passthrough]),
    meck:expect(router_device_multibuy, maybe_buy, MultiBuyFun),

    test_utils:add_oui(Config),

    #{pubkey_bin := PubKeyBin} = test_utils:join_device(Config),
    test_utils:wait_state_channel_message(1250),

    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    Device1 = router_device:update(
        [
            {metadata, #{preferred_hotspots => PreferredHotspots}}
        ],
        Device0
    ),
    {ok, _} = router_device_cache:save(Device1),

    NwkSKey = router_device:nwk_s_key(Device1),
    AppSKey = router_device:app_s_key(Device1),
    FCnt = router_device:fcnt_next_val(Device1),

    SCPacket0 = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, NwkSKey, AppSKey, FCnt, #{
        dont_encode => true, routing => true, devaddr => router_device:devaddr(Device1)
    }),

    ?assertEqual(
        ExpectedResult,
        router_device_routing:handle_packet(SCPacket0, erlang:system_time(millisecond), self())
    ),

    ?assert(meck:validate(router_device_multibuy)),
    meck:unload(router_device_multibuy),
    ok.

handle_packet_from_strange_hotspot_test(Config) ->
    %% Device has preferred hotspots that don't include our default hotspot.
    %% The packet should be rejected.

    test_frame_packet(Config, [<<"SomeOtherPubKeyBin">>], {error, not_preferred_hotspot}).

handle_packet_from_preferred_hotspot_test(Config) ->
    %% Device has preferred hotspots that do include our default hotspot.
    %% The packet should be accepted.

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    test_frame_packet(Config, [PubKeyBin], ok).

handle_packet_with_no_preferred_hotspot_test(Config) ->
    %% Device has no preferred hotspots.
    %% The packet should be accepted.

    test_frame_packet(Config, [], ok).

%%
%% Preferred Hotspots: join packets and handle_packet/3
%%

test_join_packet(Config, PreferredHotspots, ExpectedResult) ->
    MultiBuyFun =
        case PreferredHotspots of
            [] -> fun(_, _) -> ok end;
            _ -> fun(_, _) -> throw("Multibuy shouldn't happen here!") end
        end,

    meck:delete(router_device_devaddr, allocate, 2, false),
    meck:new(router_device_multibuy, [passthrough]),
    meck:expect(router_device_multibuy, maybe_buy, MultiBuyFun),

    test_utils:add_oui(Config),

    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {preferred_hotspots, PreferredHotspots}),

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    AppKey = proplists:get_value(app_key, Config),
    DevNonce = crypto:strong_rand_bytes(2),

    SCPacket0 = test_utils:join_packet(PubKeyBin, AppKey, DevNonce, #{
        dont_encode => true, routing => true
    }),

    ?assertEqual(
        ExpectedResult,
        router_device_routing:handle_packet(SCPacket0, erlang:system_time(millisecond), self())
    ),

    ?assert(meck:validate(router_device_multibuy)),
    meck:unload(router_device_multibuy),
    ok.

handle_join_packet_from_strange_hotspot_test(Config) ->
    %% Device has preferred hotspots that don't include our default hotspot.
    %% The join packet should be rejected.

    test_join_packet(Config, [<<"SomeOtherPubkeyBin">>], {error, not_preferred_hotspot}).

handle_join_packet_from_preferred_hotspot_test(Config) ->
    %% Device has preferred hotspots that do include our default hotspot.
    %% The join packet should be accepted.

    Swarm = proplists:get_value(swarm, Config),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    test_join_packet(Config, [PubKeyBin], ok).

handle_join_packet_with_no_preferred_hotspot_test(Config) ->
    %% Device has no preferred hotspots.
    %% The join packet should be accepted.

    test_join_packet(Config, [], ok).

%%
%% End of Preferred Hotspots
%%

packet_hash_cache_test(Config) ->
    %% -------------------------------------------------------------------
    %% Hotspots
    #{public := PubKey0} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin0 = libp2p_crypto:pubkey_to_bin(PubKey0),
    {ok, _HotspotName0} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin0)),

    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    {ok, _HotspotName1} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    %% -------------------------------------------------------------------
    %% Device
    #{} = test_utils:join_device(Config),
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    %% Change name of devices
    Device1 = router_device:update([{name, <<"new-name-1">>}], Device0),
    Device2 = router_device:update([{name, <<"new-name-2">>}], Device1),
    {ok, _} = router_device_cache:save(Device1),
    %% NOTE: purposefully not putting device-2 in the cache
    %% {ok, Device2} = router_device_cache:save(Device2),

    ?assertEqual(
        router_device:devaddr(Device0),
        router_device:devaddr(Device1),
        "all devices have same devaddr"
    ),
    ?assertEqual(
        router_device:devaddr(Device1),
        router_device:devaddr(Device2),
        "all devices have same devaddr"
    ),

    %% -------------------------------------------------------------------
    %% "make me an offer I cannot refuse" - Sufjan Stevens (right?)
    NwkSessionKey = router_device:nwk_s_key(Device2),
    AppSessionKey = router_device:app_s_key(Device2),
    SCPacket = test_utils:frame_packet(
        ?UNCONFIRMED_UP,
        PubKeyBin0,
        NwkSessionKey,
        AppSessionKey,
        0,
        #{dont_encode => true, routing => true}
    ),
    Offer = blockchain_state_channel_offer_v1:from_packet(
        blockchain_state_channel_packet_v1:packet(SCPacket),
        blockchain_state_channel_packet_v1:hotspot(SCPacket),
        blockchain_state_channel_packet_v1:region(SCPacket)
    ),
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),

    %% -------------------------------------------------------------------
    %% Query for devices
    Chain = router_utils:get_blockchain(),
    DevAddr = router_device:devaddr(Device1),

    %% make sure things go wrong first
    ?assertNotEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin0, Chain)
    ),
    ?assertNotEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin1, Chain)
    ),

    %% make it better
    router_device_routing:cache_device_for_hash(PHash, Device2),

    %% now we should go right
    ?assertEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin0, Chain)
    ),
    ?assertEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin1, Chain)
    ),

    %% go back to nothing
    router_device_routing:force_evict_packet_hash(PHash),

    %% back to being wrong, and it feels so right
    ?assertNotEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin0, Chain)
    ),
    ?assertNotEqual(
        {ok, Device2},
        router_device_routing:get_device_for_offer(Offer, DevAddr, PubKeyBin1, Chain)
    ),

    ok.

multi_buy_test(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),
    %% We're going to use the actual devaddr allocation, make sure we have a
    %% chain before starting this test.
    ok = test_utils:wait_until(fun() ->
        case whereis(router_device_devaddr) of
            undefined -> false;
            Pid -> element(2, sys:get_state(Pid)) /= undefined
        end
    end),

    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        router_handler_test:version(),
        router_handler_test,
        [self()]
    ),
    PubKeyBin1 = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    %% Inserting OUI into chain for routing
    _ = test_utils:add_oui(Config),

    %% device should join under OUI 1
    %% Send join packet
    DevNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin1, AppKey, DevNonce)},
    timer:sleep(router_utils:join_timeout()),

    %% Waiting for report device status on that join request
    test_utils:wait_for_console_event(<<"join_request">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"join_request">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"dc">> => fun erlang:is_map/1,
            <<"fcnt">> => 0,
            <<"payload_size">> => 0,
            <<"payload">> => <<>>,
            <<"raw_packet">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),

    %% Waiting for report device status on that join request
    test_utils:wait_for_console_event(<<"join_accept">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"join_accept">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => ?CONSOLE_DEVICE_ID,
        <<"data">> => #{
            <<"fcnt">> => 0,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin1)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => 30,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW500">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    %% Check that device is in cache now
    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device} = router_device:get_by_id(DB, CF, WorkerID),

    %% Hotspot 2
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey2),
    {ok, _HotspotName2} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin2)),

    %% Hotspot 3
    #{public := PubKey3} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin3 = libp2p_crypto:pubkey_to_bin(PubKey3),
    {ok, _HotspotName3} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin3)),

    %% Hotspot 4
    #{public := PubKey4} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin4 = libp2p_crypto:pubkey_to_bin(PubKey4),
    {ok, _HotspotName4} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin4)),

    %% Hotspot 5
    #{public := PubKey5} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin5 = libp2p_crypto:pubkey_to_bin(PubKey5),
    {ok, _HotspotName5} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin5)),

    HandleOfferForHotspotFun = fun(PubKeyBin, Device0, FCnt) ->
        SCPacket = test_utils:frame_packet(
            ?UNCONFIRMED_UP,
            PubKeyBin,
            router_device:nwk_s_key(Device0),
            router_device:app_s_key(Device0),
            FCnt,
            #{dont_encode => true, routing => true, devaddr => router_device:devaddr(Device0)}
        ),
        Offer = blockchain_state_channel_offer_v1:from_packet(
            blockchain_state_channel_packet_v1:packet(SCPacket),
            blockchain_state_channel_packet_v1:hotspot(SCPacket),
            blockchain_state_channel_packet_v1:region(SCPacket)
        ),
        router_device_routing:handle_offer(Offer, self())
    end,

    %% Multi buy for device is set to 2
    DeviceID = router_device:id(Device),
    ok = router_device_multibuy:max(DeviceID, 2),

    %% Send the same packet from all hotspots
    ok = HandleOfferForHotspotFun(PubKeyBin1, Device, 0),
    ok = HandleOfferForHotspotFun(PubKeyBin2, Device, 0),
    {error, multi_buy_max_packet} = HandleOfferForHotspotFun(PubKeyBin3, Device, 0),
    {error, multi_buy_max_packet} = HandleOfferForHotspotFun(PubKeyBin4, Device, 0),

    %% Change multi-buy to 4
    ok = router_device_multibuy:max(DeviceID, 4),

    %% Send the same packet from all hotspots
    ok = HandleOfferForHotspotFun(PubKeyBin1, Device, 1),
    ok = HandleOfferForHotspotFun(PubKeyBin2, Device, 1),
    ok = HandleOfferForHotspotFun(PubKeyBin3, Device, 1),
    ok = HandleOfferForHotspotFun(PubKeyBin4, Device, 1),
    {error, multi_buy_max_packet} = HandleOfferForHotspotFun(PubKeyBin5, Device, 1),

    ok.

handle_packet_fcnt_32_bit_rollover_test(Config) ->
    WaitForDeviceWorker = fun() ->
        timer:sleep(500)
    end,
    meck:delete(router_device_devaddr, allocate, 2, false),
    test_utils:add_oui(Config),

    #{pubkey_bin := PubKeyBin} = test_utils:join_device(Config),
    test_utils:wait_state_channel_message(1250),

    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    Device1 = router_device:update([{fcnt, 16#FFFFFFFE}], Device0),
    {ok, _} = router_device_cache:save(Device1),

    NwkSKey = router_device:nwk_s_key(Device1),
    AppSKey = router_device:app_s_key(Device1),
    FCnt = router_device:fcnt_next_val(Device1),

    ?assertEqual(16#FFFFFFFF, FCnt),

    %% Let's try sending the highest possible FCnt.
    SCPacket = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, NwkSKey, AppSKey, FCnt, #{
        dont_encode => true,
        routing => true,
        devaddr => router_device:devaddr(Device1)
    }),

    ?assertEqual(
        ok, router_device_routing:handle_packet(SCPacket, erlang:system_time(millisecond), self())
    ),

    WaitForDeviceWorker(),

    %% Packet was routed.
    %% fcnt should now be 16#FFFFFFFF
    %% next fcnt should now be 0

    {ok, Device2} = router_device:get_by_id(DB, CF, WorkerID),
    ?assertEqual(16#FFFFFFFF, router_device:fcnt(Device2)),
    ?assertEqual(0, router_device:fcnt_next_val(Device2)),

    %% If we send 16#FFFFFFFF again, that should work because it's a legitimate replay.
    ?assertEqual(
        ok, router_device_routing:handle_packet(SCPacket, erlang:system_time(millisecond), self())
    ),

    %% Fun fact: there exists a race condition here where the worker
    %% may reject our replayed packet because the frame cache TTL is
    %% set very low during testing.  The worker is expected to save
    %% the device record with the updated fcnt in any case.  That's
    %% why we sleep instead of waiting for a console message
    %% indicating the worker has processed the frame: because we don't
    %% know what to expect here, an `uplink` or an `uplink_dropped`.
    WaitForDeviceWorker(),

    %% Now, let's try sending 0.
    SCPacket2 = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, NwkSKey, AppSKey, 0, #{
        dont_encode => true,
        routing => true,
        devaddr => router_device:devaddr(Device1)
    }),
    ?assertEqual(
        ok, router_device_routing:handle_packet(SCPacket2, erlang:system_time(millisecond), self())
    ),

    WaitForDeviceWorker(),

    %% That worked.
    %% fcnt should now be 0
    %% next fcnt should now be 1

    {ok, Device3} = router_device:get_by_id(DB, CF, WorkerID),
    ?assertEqual(0, router_device:fcnt(Device3)),
    ?assertEqual(1, router_device:fcnt_next_val(Device3)),
    ok.

handle_packet_wrong_fcnt_test(Config) ->
    meck:delete(router_device_devaddr, allocate, 2, false),
    test_utils:add_oui(Config),

    #{pubkey_bin := PubKeyBin} = test_utils:join_device(Config),
    test_utils:wait_state_channel_message(1250),

    {ok, DB, CF} = router_db:get_devices(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get_by_id(DB, CF, WorkerID),

    Device1 = router_device:update([{fcnt, 16#FFFFFFFE}], Device0),
    {ok, _} = router_device_cache:save(Device1),

    NwkSKey = router_device:nwk_s_key(Device1),
    AppSKey = router_device:app_s_key(Device1),
    FCnt = 99,

    SCPacket = test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, NwkSKey, AppSKey, FCnt, #{
        dont_encode => true,
        routing => true,
        devaddr => router_device:devaddr(Device1)
    }),

    {error, unknown_device} = router_device_routing:handle_packet(
        SCPacket, erlang:system_time(millisecond), self()
    ),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
