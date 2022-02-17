%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Multi Buy ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_multibuy).

-export([
    init/0,
    max/1, max/2,
    maybe_buy/2
]).

-define(ETS, router_device_multibuy_ets).
-define(ETS_MAX, router_device_multibuy_max_ets).
%% Errors
-define(MAX_PACKET, multi_buy_max_packet).
-define(DENY_MORE, multi_buy_deny_more).
-define(TIME_KEY(Key), {time, Key}).

-spec init() -> ok.
init() ->
    ets:new(?ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ets:new(?ETS_MAX, [
        public,
        named_table,
        set,
        {read_concurrency, true}
    ]),
    %% TODO: cleanup
    ok.

-spec max(Key :: binary()) -> integer() | not_found.
max(Key) ->
    case ets:lookup(?ETS_MAX, Key) of
        [{Key, Max}] -> Max;
        _ -> not_found
    end.

-spec max(Key :: binary(), integer()) -> ok.
max(Key, Max) ->
    true = ets:insert(?ETS_MAX, {Key, Max}),
    ok.

-spec maybe_buy(DeviceID :: router_device:id(), PHash :: binary()) ->
    ok | {error, ?DENY_MORE | ?MAX_PACKET}.
maybe_buy(DeviceID, PHash) ->
    Opts = [{device_id, DeviceID}],
    Max =
        case ?MODULE:max(PHash) of
            not_found ->
                case ?MODULE:max(DeviceID) of
                    not_found ->
                        lager:debug(Opts, "not max found for ~p", [PHash]),
                        1;
                    DeviceMax ->
                        lager:debug(Opts, "using DeviceMax(~p) for ~p", [DeviceMax, PHash]),
                        DeviceMax
                end;
            PHashMax ->
                lager:debug(Opts, "using PHashMax(~p) for ~p", [PHashMax, PHash]),
                PHashMax
        end,
    case Max of
        %% If max was set to 0 we know someone denied more packets
        %% Maybe invalid, maybe put inactive since first packet arrived...
        Max when Max =< 0 ->
            {error, ?DENY_MORE};
        Max ->
            %% If counter goes over max we got our last packet
            %% When we buy first packet we make sure to mark time for later cleanup
            case ets:update_counter(?ETS, PHash, {2, 1}, {default, 0}) of
                1 ->
                    true = ets:insert(?ETS, {?TIME_KEY(PHash), erlang:system_time(millisecond)}),
                    ok;
                C when C > Max ->
                    {error, ?MAX_PACKET};
                _C ->
                    ok
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_SLEEP, 250).
-define(TEST_PERF, 1000).

max_test() ->
    _ = catch ets:delete(?ETS),
    _ = catch ets:delete(?ETS_MAX),

    ok = ?MODULE:init(),

    DeviceID = router_utils:uuid_v4(),
    Max = 5,
    ?assertEqual(not_found, ?MODULE:max(DeviceID)),
    ?assertEqual(ok, ?MODULE:max(DeviceID, Max)),
    ?assertEqual(Max, ?MODULE:max(DeviceID)),

    ok.

maybe_buy_test() ->
    _ = catch ets:delete(?ETS),
    _ = catch ets:delete(?ETS_MAX),

    ok = ?MODULE:init(),

    %% Setup Max packet for device
    DeviceID = router_utils:uuid_v4(),
    Max = 5,
    ?assertEqual(ok, ?MODULE:max(DeviceID, Max)),

    Parent = self(),
    %% Setup phash and number of packet to be sent
    PHash = crypto:strong_rand_bytes(32),
    Packets = 100,
    lists:foreach(
        fun(X) ->
            %% Each "packet sending" is spawn and sleep for a random timer defined by
            %% ?TEST_SLEEP it will then attempt to buy and send back its result to Parent
            erlang:spawn(
                fun() ->
                    timer:sleep(rand:uniform(?TEST_SLEEP)),
                    {Time, Result} = timer:tc(?MODULE, maybe_buy, [DeviceID, PHash]),
                    Parent ! {maybe_buy_test, X, Time, Result}
                end
            )
        end,
        lists:seq(1, Packets)
    ),
    %% Aggregate results
    Results = maybe_buy_test_rcv_loop(#{}),
    %% Filter result to only find OKs and make sure we only have MAX OKs
    OK = maps:filter(fun(_K, {_, V}) -> V =:= ok end, Results),
    ?assertEqual(Max, maps:size(OK)),
    %% Filter result to only find Errors and make sure we have Packets-MAX Errors
    Errors = maps:filter(
        fun(_K, {_, V}) -> V =:= {error, ?MAX_PACKET} end,
        Results
    ),
    ?assertEqual(Packets - Max, maps:size(Errors)),
    %% At this point a time marker should have been set in the table with that PHash
    ?assertMatch([{?TIME_KEY(PHash), _}], ets:lookup(?ETS, ?TIME_KEY(PHash))),
    %% performance check in MICRO seconds
    TotalTime = lists:sum([T || {T, _} <- maps:values(Results)]),
    ?assert(TotalTime / Packets < ?TEST_PERF),
    ok.

maybe_buy_only_1_test() ->
    _ = catch ets:delete(?ETS),
    _ = catch ets:delete(?ETS_MAX),

    ok = ?MODULE:init(),

    %% Setup Max packet for device
    DeviceID = router_utils:uuid_v4(),
    Max = 1,
    ?assertEqual(ok, ?MODULE:max(DeviceID, Max)),

    Parent = self(),
    %% Setup phash and number of packet to be sent
    PHash = crypto:strong_rand_bytes(32),
    Packets = 100,
    lists:foreach(
        fun(X) ->
            %% Each "packet sending" is spawn and sleep for a random timer defined by
            %% ?TEST_SLEEP it will then attempt to buy and send back its result to Parent
            erlang:spawn(
                fun() ->
                    timer:sleep(rand:uniform(?TEST_SLEEP)),
                    {Time, Result} = timer:tc(?MODULE, maybe_buy, [DeviceID, PHash]),
                    Parent ! {maybe_buy_test, X, Time, Result}
                end
            )
        end,
        lists:seq(1, Packets)
    ),
    %% Aggregate results
    Results = maybe_buy_test_rcv_loop(#{}),
    %% Filter result to only find OKs and make sure we only have MAX OKs
    OK = maps:filter(fun(_K, {_, V}) -> V =:= ok end, Results),
    ?assertEqual(Max, maps:size(OK)),
    %% Filter result to only find Errors and make sure we have Packets-MAX Errors
    Errors = maps:filter(
        fun(_K, {_, V}) -> V =:= {error, ?MAX_PACKET} end,
        Results
    ),
    ?assertEqual(Packets - Max, maps:size(Errors)),
    %% At this point a time marker should have been set in the table with that PHash
    ?assertMatch([{?TIME_KEY(PHash), _}], ets:lookup(?ETS, ?TIME_KEY(PHash))),
    %% performance check in MICRO seconds
    TotalTime = lists:sum([T || {T, _} <- maps:values(Results)]),
    ?assert(TotalTime / Packets < ?TEST_PERF),
    ok.

maybe_buy_deny_more_test() ->
    _ = catch ets:delete(?ETS),
    _ = catch ets:delete(?ETS_MAX),

    ok = ?MODULE:init(),

    %% Setup Max packet for device
    DeviceID = router_utils:uuid_v4(),
    Max = 0,
    ?assertEqual(ok, ?MODULE:max(DeviceID, Max)),

    Parent = self(),
    %% Setup phash and number of packet to be sent
    PHash = crypto:strong_rand_bytes(32),
    Packets = 100,
    lists:foreach(
        fun(X) ->
            %% Each "packet sending" is spawn and sleep for a random timer defined by
            %% ?TEST_SLEEP it will then attempt to buy and send back its result to Parent
            erlang:spawn(
                fun() ->
                    timer:sleep(rand:uniform(?TEST_SLEEP)),
                    {Time, Result} = timer:tc(?MODULE, maybe_buy, [DeviceID, PHash]),
                    Parent ! {maybe_buy_test, X, Time, Result}
                end
            )
        end,
        lists:seq(1, Packets)
    ),
    %% Aggregate results
    Results = maybe_buy_test_rcv_loop(#{}),
    %% Filter result to only find OKs and make sure we only have MAX OKs
    OK = maps:filter(fun(_K, {_, V}) -> V =:= ok end, Results),
    ?assertEqual(0, maps:size(OK)),
    %% Filter result to only find Errors and make sure we have Packets-MAX Errors
    Errors = maps:filter(
        fun(_K, {_, V}) -> V =:= {error, ?DENY_MORE} end,
        Results
    ),
    ?assertEqual(Packets, maps:size(Errors)),
    %% At this point a time marker should have been set in the table with that PHash
    ?assertMatch([], ets:lookup(?ETS, ?TIME_KEY(PHash))),
    %% performance check in MICRO seconds
    TotalTime = lists:sum([T || {T, _} <- maps:values(Results)]),
    ?assert(TotalTime / Packets < ?TEST_PERF),
    ok.

maybe_buy_phash_max_test() ->
    _ = catch ets:delete(?ETS),
    _ = catch ets:delete(?ETS_MAX),

    ok = ?MODULE:init(),

    %% Setup Max packet for device
    DeviceID = router_utils:uuid_v4(),
    DeviceMax = 5,
    ?assertEqual(ok, ?MODULE:max(DeviceID, DeviceMax)),

    Parent = self(),
    %% Setup phash and number of packet to be sent
    PHash = crypto:strong_rand_bytes(32),
    %% For some reason this packet it bad change PHashMax
    PHashMax = 0,
    ?assertEqual(ok, ?MODULE:max(PHash, PHashMax)),
    Packets = 100,
    lists:foreach(
        fun(X) ->
            %% Each "packet sending" is spawn and sleep for a random timer defined by
            %% ?TEST_SLEEP it will then attempt to buy and send back its result to Parent
            erlang:spawn(
                fun() ->
                    timer:sleep(rand:uniform(?TEST_SLEEP)),
                    {Time, Result} = timer:tc(?MODULE, maybe_buy, [DeviceID, PHash]),
                    Parent ! {maybe_buy_test, X, Time, Result}
                end
            )
        end,
        lists:seq(1, Packets)
    ),
    %% Aggregate results
    Results = maybe_buy_test_rcv_loop(#{}),
    %% Filter result to only find OKs and make sure we only have MAX OKs
    OK = maps:filter(fun(_K, {_, V}) -> V =:= ok end, Results),
    ?assertEqual(PHashMax, maps:size(OK)),
    %% Filter result to only find Errors and make sure we have Packets-MAX Errors
    Errors = maps:filter(
        fun(_K, {_, V}) -> V =:= {error, ?DENY_MORE} end,
        Results
    ),
    ?assertEqual(Packets - PHashMax, maps:size(Errors)),
    %% At this point a time marker should have been set in the table with that PHash
    ?assertMatch([], ets:lookup(?ETS, ?TIME_KEY(PHash))),
    %% performance check in MICRO seconds
    TotalTime = lists:sum([T || {T, _} <- maps:values(Results)]),
    ?assert(TotalTime / Packets < ?TEST_PERF),
    ok.

maybe_buy_test_rcv_loop(Acc) ->
    receive
        {maybe_buy_test, X, Time, Result} ->
            maybe_buy_test_rcv_loop(maps:put(X, {Time, Result}, Acc))
    after ?TEST_SLEEP -> Acc
    end.

-endif.
