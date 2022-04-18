%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Hotspot Reputation ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_hotspot_reputation).

-define(ETS, router_hotspot_reputation_ets).
-define(OFFER_ETS, router_hotspot_reputation_offers_ets).
-define(DEFAULT_TIMER, timer:minutes(2)).
-define(DEFAULT_THRESHOLD, 10).

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([
    enabled/0,
    init/0,
    track_offer/1,
    track_packet/1,
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

-spec init() -> ok.
init() ->
    case ?MODULE:enabled() of
        false ->
            lager:info("router_hotspot_reputation disabled");
        true ->
            lager:info("router_hotspot_reputation enabled"),
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
                {write_concurrency, true}
            ],
            _ = ets:new(?OFFER_ETS, Opts2),
            ok = spawn_crawl_offers(?DEFAULT_TIMER),
            ok
    end.

-spec track_offer(Offer :: blockchain_state_channel_offer_v1:offer()) -> ok.
track_offer(Offer) ->
    case ?MODULE:enabled() of
        false ->
            ok;
        true ->
            erlang:spawn(fun() ->
                lager:info("router_hotspot_reputation enabled"),
                Hotspot = blockchain_state_channel_offer_v1:hotspot(Offer),
                PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
                Now = erlang:system_time(millisecond),
                true = ets:insert(?OFFER_ETS, {{Hotspot, PHash}, Now})
            end)
    end,
    ok.

-spec track_packet(SCPacket :: blockchain_state_channel_packet_v1:packet()) -> ok.
track_packet(SCPacket) ->
    case ?MODULE:enabled() of
        false ->
            ok;
        true ->
            erlang:spawn(fun() ->
                Hotspot = blockchain_state_channel_packet_v1:hotspot(SCPacket),
                Packet = blockchain_state_channel_packet_v1:packet(SCPacket),
                PHash = blockchain_helium_packet_v1:packet_hash(Packet),
                true = ets:delete(?OFFER_ETS, {Hotspot, PHash})
            end)
    end,
    ok.

-spec reputations() -> list().
reputations() ->
    ets:tab2list(?ETS).

-spec reputation(Hotspot :: libp2p_crypto:pubkey_bin()) -> non_neg_integer().
reputation(Hotspot) ->
    case ets:lookup(?ETS, Hotspot) of
        [] -> 0;
        [{Hotspot, Reputation}] -> Reputation
    end.

-spec denied(Hotspot :: libp2p_crypto:pubkey_bin()) -> boolean().
denied(Hotspot) ->
    Threshold = router_utils:get_env_int(hotspot_reputation_threshold, ?DEFAULT_THRESHOLD),
    ?MODULE:reputation(Hotspot) >= Threshold.

-spec reset(Hotspot :: libp2p_crypto:pubkey_bin()) -> ok.
reset(Hotspot) ->
    true = ets:insert(?ETS, {Hotspot, 0}),
    ok.

-spec crawl_offers(Timer :: non_neg_integer()) -> ok.
crawl_offers(Timer) ->
    Now = erlang:system_time(millisecond) - Timer,
    %% MS = ets:fun2ms(fun({Key, Time}) when Time < Now -> Key end),
    MS = [{{'$1', '$2'}, [{'<', '$2', {const, Now}}], ['$1']}],
    Expired = ets:select(?OFFER_ETS, MS),
    lager:info("crawling offer, found ~p", [erlang:length(Expired)]),
    lists:foreach(
        fun({Hotspot, PHash}) ->
            true = ets:delete(?OFFER_ETS, {Hotspot, PHash}),
            Counter = ets:update_counter(?ETS, Hotspot, {2, 1}, {default, 0}),
            lager:info("hotspot ~p = ~p", [blockchain_utils:addr2name(Hotspot), Counter])
        end,
        Expired
    ),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec spawn_crawl_offers(Timer :: non_neg_integer()) -> ok.
spawn_crawl_offers(Timer) ->
    _ = erlang:spawn(fun() ->
        ok = timer:sleep(Timer),
        ok = crawl_offers(Timer),
        ok = spawn_crawl_offers(Timer)
    end),
    ok.

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

    ?assertEqual(0, ?MODULE:reputation(Hotspot)),
    timer:sleep(110),
    ok = ?MODULE:crawl_offers(100),

    ?assertEqual(1, ?MODULE:reputation(Hotspot)),

    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    ?assertEqual([], ets:lookup(?ETS, {Hotspot, PHash})),

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

    ?assertEqual(100, ?MODULE:reputation(Hotspot)),
    ?assertEqual(true, ?MODULE:denied(Hotspot)),

    ?assertEqual([{Hotspot, 100}], ?MODULE:reputations()),

    ok = ?MODULE:reset(Hotspot),

    ?assertEqual(0, ?MODULE:reputation(Hotspot)),
    ?assertEqual(false, ?MODULE:denied(Hotspot)),

    ets:delete(?ETS),
    ets:delete(?OFFER_ETS),
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

    ?assertEqual(0, ?MODULE:reputation(Hotspot)),

    PHash = blockchain_state_channel_offer_v1:packet_hash(Offer),
    ?assertEqual([], ets:lookup(?ETS, {Hotspot, PHash})),

    ?assertEqual([], ?MODULE:reputations()),

    ets:delete(?ETS),
    ets:delete(?OFFER_ETS),
    application:stop(lager),

    ok.

-endif.
