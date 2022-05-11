%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Device Stats ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_device_stats).

-define(ETS, router_device_stats_ets).
-define(OFFER_ETS, router_device_stats_offers_ets).
-define(DEFAULT_TIMER, timer:minutes(2)).

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([
    init/0,
    track_offer/2,
    track_packet/3,
    lookup_hotspot/1,
    lookup_device/1,
    cleanup_offers/1
]).

%% ------------------------------------------------------------------
%% API Functions
%% ------------------------------------------------------------------

-spec init() -> ok.
init() ->
    Opts1 = [
        public,
        named_table,
        set,
        {read_concurrency, true}
    ],
    _ = ets:new(?ETS, Opts1),
    Opts2 = [
        public,
        named_table,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ],
    _ = ets:new(?OFFER_ETS, Opts2),
    ok = spawn_cleanup_offers(?DEFAULT_TIMER),
    ok.

-spec track_offer(
    Offer :: blockchain_state_channel_offer_v1:offer(), Device :: router_device:device()
) -> ok.
track_offer(Offer, Device) ->
    erlang:spawn(fun() ->
        Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
        PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
        Now = erlang:system_time(millisecond),
        true = ets:insert(?OFFER_ETS, {{Hotspot, PHash}, router_device:id(Device), Now})
    end),
    ok.

-spec track_packet(
    Packet :: blockchain_helium_packet_v1:packet(),
    Hotspot :: libp2p_crypto:pubkey_bin(),
    Device :: router_device:device()
) -> ok.
track_packet(Packet, Hotspot, Device) ->
    erlang:spawn(fun() ->
        PHash = blockchain_helium_packet_v1:packet_hash(Packet),
        DeviceID = router_device:id(Device),
        case ets:lookup(?OFFER_ETS, {Hotspot, PHash}) of
            [{{Hotspot, PHash}, DeviceID, _Time}] ->
                true = ets:delete(?OFFER_ETS, {Hotspot, PHash});
            [{{Hotspot, PHash}, _OtherDeviceID, _Time}] ->
                _ = ets:update_counter(?ETS, {DeviceID, Hotspot}, {2, 1}, {default, 0});
            [] ->
                ok
        end
    end),
    ok.

-spec lookup_hotspot(Hotspot :: any()) -> list().
lookup_hotspot(Hotspot) ->
    MS = [{{{'$1', '$2'}, '$3'}, [{'==', '$2', Hotspot}], ['$_']}],
    [
        {D, blockchain_utils:addr2name(H), libp2p_crypto:bin_to_b58(H), C}
     || {{D, H}, C} <- ets:select(?ETS, MS)
    ].

-spec lookup_device(DeviceID :: router_device:id()) -> list().
lookup_device(DeviceID) ->
    MS = [{{{'$1', '$2'}, '$3'}, [{'==', '$1', DeviceID}], ['$_']}],
    [
        {D, blockchain_utils:addr2name(H), libp2p_crypto:bin_to_b58(H), C}
     || {{D, H}, C} <- ets:select(?ETS, MS)
    ].

-spec cleanup_offers(Timer :: non_neg_integer()) -> ok.
cleanup_offers(Timer) ->
    Now = erlang:system_time(millisecond) - Timer,
    %% MS = ets:fun2ms(fun({Key, DeviceID, Time}) when Time < Now -> Key end),
    MS = [{{{'$1', '$2'}, '$3', '$4'}, [{'<', '$4', Now}], [true]}],
    _ = ets:select_delete(?OFFER_ETS, MS),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec spawn_cleanup_offers(Timer :: non_neg_integer()) -> ok.
spawn_cleanup_offers(Timer) ->
    _ = erlang:spawn(fun() ->
        ok = timer:sleep(Timer),
        ok = cleanup_offers(Timer),
        ok = spawn_cleanup_offers(Timer)
    end),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

ok_test() ->
    ok = ?MODULE:init(),

    Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
    Hotspot = crypto:strong_rand_bytes(32),
    Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),
    Device = router_device:new(<<"device">>),

    ok = ?MODULE:track_offer(Offer, Device),
    ok = ?MODULE:track_packet(Packet, Hotspot, Device),

    timer:sleep(10),

    ?assertEqual([], ?MODULE:lookup_hotspot(Hotspot)),
    ?assertEqual([], ?MODULE:lookup_device(router_device:id(Device))),

    ets:delete(?ETS),
    ets:delete(?OFFER_ETS),

    ok.

fail_test() ->
    ok = ?MODULE:init(),

    Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
    Hotspot = crypto:strong_rand_bytes(32),
    Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),
    Device0 = router_device:new(<<"device0">>),

    ok = ?MODULE:track_offer(Offer, Device0),

    Device1 = router_device:new(<<"device1">>),
    ok = ?MODULE:track_packet(Packet, Hotspot, Device1),

    timer:sleep(10),

    ?assertEqual(
        [
            {
                router_device:id(Device1),
                blockchain_utils:addr2name(Hotspot),
                libp2p_crypto:bin_to_b58(Hotspot),
                1
            }
        ],
        ?MODULE:lookup_hotspot(Hotspot)
    ),
    ?assertEqual(
        [
            {
                router_device:id(Device1),
                blockchain_utils:addr2name(Hotspot),
                libp2p_crypto:bin_to_b58(Hotspot),
                1
            }
        ],
        ?MODULE:lookup_device(router_device:id(Device1))
    ),

    ets:delete(?ETS),
    ets:delete(?OFFER_ETS),

    ok.

cleanup_offers_test() ->
    ok = ?MODULE:init(),

    Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
    Hotspot = crypto:strong_rand_bytes(32),
    Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),
    Device = router_device:new(<<"device">>),

    ok = ?MODULE:track_offer(Offer, Device),

    timer:sleep(110),

    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    ?assertMatch(1, erlang:length(ets:lookup(?OFFER_ETS, {Hotspot, PHash}))),

    ok = cleanup_offers(100),

    ?assertMatch(0, erlang:length(ets:lookup(?OFFER_ETS, {Hotspot, PHash}))),

    ?assertEqual([], ?MODULE:lookup_hotspot(Hotspot)),
    ?assertEqual([], ?MODULE:lookup_device(router_device:id(Device))),

    ets:delete(?ETS),
    ets:delete(?OFFER_ETS),

    ok.

-endif.
