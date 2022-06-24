%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Hotspot Reputation ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_hotspot_reputation).

-define(ETS, router_hotspot_reputation_ets).
-define(OFFER_ETS, router_hotspot_reputation_offers_ets).
-define(DEFAULT_TIMER, timer:minutes(2)).
-define(DEFAULT_THRESHOLD, 50).

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([
    enabled/0,
    threshold/0,
    init/0,
    track_offer/1,
    track_packet/1,
    track_unknown_device/2,
    reputations/0,
    reputation/1,
    denied/1,
    reset/1,
    crawl_offers/1
]).

%% ------------------------------------------------------------------
%% API Functions
%% ------------------------------------------------------------------

-spec enabled() -> boolean().
enabled() ->
    case application:get_env(router, hotspot_reputation_enabled, false) of
        "true" -> true;
        true -> true;
        _ -> false
    end.

-spec threshold() -> non_neg_integer().
threshold() ->
    ru_reputation:threshold().

-spec init() -> ok.
init() ->
    ok = ru_reputation:init(),
    Threshold = router_utils:get_env_int(hotspot_reputation_threshold, ?DEFAULT_THRESHOLD),
    _ = ru_reputation:threshold(Threshold),
    ok.

-spec track_offer(Offer :: blockchain_state_channel_offer_v1:offer()) -> ok.
track_offer(Offer) ->
    Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    ok = ru_reputation:track_offer(Hotspot, PHash),
    ok.

-spec track_packet(SCPacket :: blockchain_state_channel_packet_v1:packet()) -> ok.
track_packet(SCPacket) ->
    Hotspot = blockchain_state_channel_packet_v1:hotspot(SCPacket),
    Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
    PHash = blockchain_helium_packet_v1:packet_hash(Packet),
    ok = ru_reputation:track_packet(Hotspot, PHash),
    ok.

-spec track_unknown_device(
    Packet :: blockchain_helium_packet_v1:packet(),
    Hotspot :: libp2p_crypto:pubkey_bin()
) -> ok.
track_unknown_device(_Packet, Hotspot) ->
    ru_reputation:track_unknown(Hotspot),
    ok.

-spec reputations() -> list().
reputations() ->
    ru_reputation:reputations().

-spec reputation(Hotspot :: libp2p_crypto:pubkey_bin()) -> {non_neg_integer(), non_neg_integer()}.
reputation(Hotspot) ->
    ru_reputation:reputation(Hotspot).

-spec denied(Hotspot :: libp2p_crypto:pubkey_bin()) -> boolean().
denied(Hotspot) ->
    ru_reputation:denied(Hotspot).

-spec reset(Hotspot :: libp2p_crypto:pubkey_bin()) -> ok.
reset(Hotspot) ->
    ru_reputation:reset(Hotspot).

-spec crawl_offers(Timer :: non_neg_integer()) -> ok.
crawl_offers(Timer) ->
    ru_reputation:crawl_offers(Timer).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

bad_hotspot_test() ->
    application:ensure_all_started(lager),
    application:set_env(router, hotspot_reputation_enabled, true),

    ok = ?MODULE:init(),

    Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
    Hotspot = crypto:strong_rand_bytes(32),
    Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),
    ok = ?MODULE:track_offer(Offer),

    ?assertEqual({0, 0}, ?MODULE:reputation(Hotspot)),
    timer:sleep(110),
    ok = ?MODULE:crawl_offers(100),

    ?assertEqual({1, 0}, ?MODULE:reputation(Hotspot)),

    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    ?assertEqual([], ets:lookup(ru_reputation_ets, {Hotspot, PHash})),

    lists:foreach(
        fun(X) ->
            P = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<X>>),
            O = blockchain_state_channel_offer_v1:from_packet(P, Hotspot, 'US915'),
            _ = erlang:spawn(?MODULE, track_offer, [O])
        end,
        lists:seq(1, 99)
    ),

    timer:sleep(110),
    ok = ?MODULE:crawl_offers(100),

    ?assertEqual({100, 0}, ?MODULE:reputation(Hotspot)),
    ?assertEqual(true, ?MODULE:denied(Hotspot)),

    ?assertEqual([{Hotspot, 100, 0}], ?MODULE:reputations()),

    Packet1 = blockchain_helium_packet_v1:new(
        {eui, 16#deadbeef, 16#DEADC0DE}, crypto:strong_rand_bytes(32)
    ),
    Offer1 = blockchain_state_channel_offer_v1:from_packet(Packet1, Hotspot, 'US915'),
    ok = ?MODULE:track_offer(Offer1),
    timer:sleep(100),
    ok = ?MODULE:track_unknown_device(Packet1, Hotspot),
    timer:sleep(100),
    ?assertEqual({100, 1}, ?MODULE:reputation(Hotspot)),
    ?assertEqual([{Hotspot, 100, 1}], ?MODULE:reputations()),

    ok = ?MODULE:reset(Hotspot),

    ?assertEqual({0, 0}, ?MODULE:reputation(Hotspot)),
    ?assertEqual(false, ?MODULE:denied(Hotspot)),

    ets:delete(ru_reputation_ets),
    ets:delete(ru_reputation_offers_ets),
    application:stop(lager),

    ok.

good_hotspot_test() ->
    application:ensure_all_started(lager),
    application:set_env(router, hotspot_reputation_enabled, true),

    ok = ?MODULE:init(),

    Packet = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#DEADC0DE}, <<"payload">>),
    Hotspot = crypto:strong_rand_bytes(32),
    Offer = blockchain_state_channel_offer_v1:from_packet(Packet, Hotspot, 'US915'),
    ok = ?MODULE:track_offer(Offer),

    SCPacket = blockchain_state_channel_packet_v1:new(Packet, Hotspot, 'US915'),
    ok = ?MODULE:track_packet(SCPacket),
    timer:sleep(110),

    ok = ?MODULE:crawl_offers(100),

    ?assertEqual({0, 0}, ?MODULE:reputation(Hotspot)),

    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    ?assertEqual([], ets:lookup(ru_reputation_ets, {Hotspot, PHash})),

    ?assertEqual([], ?MODULE:reputations()),

    ets:delete(ru_reputation_ets),
    ets:delete(ru_reputation_offers_ets),
    application:stop(lager),

    ok.

-endif.
