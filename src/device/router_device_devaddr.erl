%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Devaddr ==
%%
%% - Process registers itself to the blockchain as an event handler.
%% - Allocates DevAddrs
%% - Helpers for router_devices
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_device_devaddr).

-behavior(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    allocate/2,
    set_devaddr_bases/1,
    get_devaddr_bases/0,
    sort_devices/2,
    pubkeybin_to_loc/1,
    h3_parent_for_pubkeybin/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-record(state, {
    oui :: non_neg_integer(),
    devaddr_bases = [] :: list(non_neg_integer()),
    keys = #{} :: #{any() := non_neg_integer()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec allocate(router_device:device(), libp2p_crypto:pubkey_bin()) ->
    {ok, binary()} | {error, any()}.
allocate(Device, PubKeyBin) ->
    gen_server:call(?SERVER, {allocate, Device, PubKeyBin}).

-spec set_devaddr_bases(list({Min, Max})) -> ok when
    Min :: non_neg_integer(),
    Max :: non_neg_integer().
set_devaddr_bases(Ranges) ->
    ExpandedRanges = expand_ranges(Ranges),
    gen_server:call(?MODULE, {set_devaddr_bases, ExpandedRanges}).

-spec get_devaddr_bases() -> {ok, {non_neg_integer(), non_neg_integer()}}.
get_devaddr_bases() ->
    gen_server:call(?MODULE, get_devaddr_bases).

-spec sort_devices([router_device:device()], libp2p_crypto:pubkey_bin()) ->
    [router_device:device()].
sort_devices(Devices, PubKeyBin) ->
    case ?MODULE:pubkeybin_to_loc(PubKeyBin) of
        {error, _Reason} ->
            Devices;
        {ok, Index} ->
            [D || {_, D} <- lists:sort([{distance_between(D, Index), D} || D <- Devices])]
    end.

%% TODO: Maybe make this a ets table to avoid lookups all the time
-spec pubkeybin_to_loc(undefined | libp2p_crypto:pubkey_bin()) ->
    {ok, non_neg_integer()} | {error, any()}.
pubkeybin_to_loc(undefined) ->
    {error, undef_pubkeybin};
pubkeybin_to_loc(PubKeyBin) ->
    router_blockchain:get_hotspot_location_index(PubKeyBin).

-spec h3_parent_for_pubkeybin(undefined | libp2p_crypto:pubkey_bin()) -> non_neg_integer().
h3_parent_for_pubkeybin(PubKeyBin) ->
    Index =
        case ?MODULE:pubkeybin_to_loc(PubKeyBin) of
            {error, _} -> h3:from_geo({0.0, 0.0}, 12);
            {ok, IA} -> IA
        end,
    h3:to_geo(
        h3:parent(Index, router_utils:get_env_int(devaddr_allocate_resolution, 3))
    ).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    case router_blockchain:is_chain_dead() of
        true ->
            ok;
        false ->
            ok = blockchain_event:add_handler(self()),
            erlang:send_after(500, self(), post_init_chain)
    end,

    OUI =
        case router_utils:get_oui() of
            undefined -> error(no_oui_configured);
            OUI0 -> OUI0
        end,
    {ok, #state{oui = OUI}}.

handle_call({set_devaddr_bases, []}, _From, State) ->
    lager:info("trying to set empty devaddr bases, ignoring"),
    {reply, ok, State};
handle_call({set_devaddr_bases, Ranges}, _From, State) ->
    NewState = State#state{devaddr_bases = lists:usort(Ranges), keys = #{}},
    {reply, ok, NewState};
handle_call(get_devaddr_bases, _From, #state{devaddr_bases = DevaddrBases} = State) ->
    {reply, {ok, DevaddrBases}, State};
handle_call({allocate, _Device, _PubKeyBin}, _From, #state{devaddr_bases = []} = State) ->
    {reply, {error, no_subnets}, State};
handle_call(
    {allocate, _Device, PubKeyBin},
    _From,
    #state{devaddr_bases = Numbers, keys = Keys} = State
) ->
    Parent = ?MODULE:h3_parent_for_pubkeybin(PubKeyBin),

    CurrentIndex = maps:get(Parent, Keys, 0),
    DevaddrBase = lists:nth(CurrentIndex + 1, Numbers),
    NextIndex = (CurrentIndex + 1) rem length(Numbers),
    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),

    Reply = {ok, <<DevaddrBase:25/integer-unsigned-little, DevAddrPrefix:7/integer>>},

    {reply, Reply, State#state{keys = Keys#{Parent => NextIndex}}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init_chain, #state{oui = OUI, devaddr_bases = []} = State0) ->
    Subnets = router_blockchain:subnets_for_oui(OUI),
    Ranges = expand_ranges(subnets_to_ranges(Subnets)),
    {noreply, State0#state{devaddr_bases = Ranges}};
handle_info(
    {blockchain_event, {add_block, BlockHash, _Syncing, _Ledger}},
    #state{oui = OUI} = State
) ->
    {ok, Block} = router_blockchain:get_blockhash(BlockHash),
    FilterFun = fun(T) ->
        case blockchain_txn:type(T) of
            blockchain_txn_oui_v1 ->
                blockchain_txn_oui_v1:oui(T) == OUI;
            blockchain_txn_routing_v1 ->
                blockchain_txn_routing_v1:oui(T) == OUI;
            _ ->
                false
        end
    end,
    %% check if there's any txns that affect our OUI
    case blockchain_utils:find_txn(Block, FilterFun) of
        [] ->
            {noreply, State};
        _ ->
            Subnets = router_blockchain:subnets_for_oui(OUI),
            Ranges = expand_ranges(subnets_to_ranges(Subnets)),
            {noreply, State#state{devaddr_bases = Ranges}}
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec subnets_to_ranges(Subnets :: list(binary)) -> list({non_neg_integer(), non_neg_integer()}).
subnets_to_ranges(Subnets) ->
    lists:map(
        fun(<<Base:25/integer-unsigned-big, Mask:23/integer-unsigned-big>>) ->
            Max = blockchain_ledger_routing_v1:subnet_mask_to_size(Mask),
            {Base, Base + Max - 1}
        end,
        Subnets
    ).

-spec expand_ranges(list({Min, Max})) -> [non_neg_integer()] when
    Min :: non_neg_integer(),
    Max :: non_neg_integer().
expand_ranges(Ranges) ->
    lists:flatmap(
        fun({Start, End}) -> lists:seq(Start, End) end,
        Ranges
    ).

-spec distance_between(Device :: router_device:device(), Index :: h3:index()) -> non_neg_integer().
distance_between(Device, Index) ->
    case ?MODULE:pubkeybin_to_loc(router_device:location(Device)) of
        {error, _Reason} ->
            %% We default to blockchain_utils:distance/2's default
            1000;
        {ok, DeviceIndex} ->
            case h3:get_resolution(Index) == h3:get_resolution(DeviceIndex) of
                true ->
                    blockchain_utils:distance(Index, DeviceIndex);
                false ->
                    [IndexA, IndexB] = indexes_to_lowest_res([
                        Index,
                        DeviceIndex
                    ]),
                    blockchain_utils:distance(IndexA, IndexB)
            end
    end.

-spec indexes_to_lowest_res([h3:index()]) -> [h3:index()].
indexes_to_lowest_res(Indexes) ->
    Resolutions = [h3:get_resolution(I) || I <- Indexes],
    LowestRes = lists:min(Resolutions),
    [to_res(I, LowestRes) || I <- Indexes].

-spec to_res(h3:index(), non_neg_integer()) -> h3:index().
to_res(Index, Res) ->
    h3:from_geo(h3:to_geo(Index), Res).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

%% There H3 indexes (resolution 12) are aligned from farther left to right
-define(INDEX_A, 631210969893275647).
-define(INDEX_B, 631210973995593215).
-define(INDEX_C, 631210968861644799).
-define(INDEX_D, 631210968873637887).

-define(HOUSTON, 631707683692833279).
-define(SUNNYVALE, 631211238895226367).
-define(SAN_JOSE, 631211239494330367).

sort_devices_test() ->
    Hotspots = #{
        <<"A">> => ?INDEX_A,
        <<"B">> => ?INDEX_B,
        <<"C">> => ?INDEX_C,
        <<"D">> => ?INDEX_D
    },

    meck:new(router_blockchain, [passthrough]),
    meck:expect(router_blockchain, get_hotspot_location_index, fun(PubKeyBin) ->
        {ok, maps:get(PubKeyBin, Hotspots)}
    end),

    Randomized = lists:sort([{rand:uniform(), N} || N <- maps:keys(Hotspots)]),
    Devices = [router_device:location(ID, router_device:new(ID)) || {_, ID} <- Randomized],

    ?assertEqual([<<"A">>, <<"B">>, <<"C">>, <<"D">>], [
        router_device:id(D)
     || D <- sort_devices(Devices, <<"A">>)
    ]),

    ?assertEqual([<<"B">>, <<"A">>, <<"C">>, <<"D">>], [
        router_device:id(D)
     || D <- sort_devices(Devices, <<"B">>)
    ]),

    ?assertEqual([<<"C">>, <<"D">>, <<"B">>, <<"A">>], [
        router_device:id(D)
     || D <- sort_devices(Devices, <<"C">>)
    ]),

    ?assertEqual([<<"D">>, <<"C">>, <<"B">>, <<"A">>], [
        router_device:id(D)
     || D <- sort_devices(Devices, <<"D">>)
    ]),

    ?assert(meck:validate(router_blockchain)),
    meck:unload(router_blockchain),
    ok.

sort_devices_long_distance_test() ->
    Hotspots = #{
        <<"HOUSTON">> => ?HOUSTON,
        <<"SUNNYVALE">> => ?SUNNYVALE,
        <<"SAN_JOSE">> => ?SAN_JOSE
    },

    meck:new(router_blockchain, [passthrough]),
    meck:expect(router_blockchain, get_hotspot_location_index, fun(PubKeyBin) ->
        {ok, maps:get(PubKeyBin, Hotspots)}
    end),

    Randomized = lists:sort([{rand:uniform(), N} || N <- maps:keys(Hotspots)]),
    Devices = [router_device:location(ID, router_device:new(ID)) || {_, ID} <- Randomized],

    ?assertEqual([<<"SAN_JOSE">>, <<"SUNNYVALE">>, <<"HOUSTON">>], [
        router_device:id(D)
     || D <- sort_devices(Devices, <<"SAN_JOSE">>)
    ]),

    ?assertEqual([<<"SUNNYVALE">>, <<"SAN_JOSE">>, <<"HOUSTON">>], [
        router_device:id(D)
     || D <- sort_devices(Devices, <<"SUNNYVALE">>)
    ]),

    ?assertEqual([<<"HOUSTON">>, <<"SAN_JOSE">>, <<"SUNNYVALE">>], [
        router_device:id(D)
     || D <- sort_devices(Devices, <<"HOUSTON">>)
    ]),

    ?assert(meck:validate(router_blockchain)),
    meck:unload(router_blockchain),
    ok.

indexes_to_lowest_res_test() ->
    ?assertEqual(
        [?INDEX_A, ?INDEX_B, ?INDEX_C],
        indexes_to_lowest_res([?INDEX_A, ?INDEX_B, ?INDEX_C])
    ).

to_res_test() ->
    ?assertEqual(?INDEX_A, to_res(?INDEX_A, 12)),
    ?assertEqual(?INDEX_B, to_res(?INDEX_B, 12)),
    ?assertEqual(?INDEX_C, to_res(?INDEX_C, 12)),
    ?assertEqual(?INDEX_D, to_res(?INDEX_D, 12)),
    ok.

set_range_allocation_test_() ->
    {
        foreach,
        fun() ->
            meck:new(router_blockchain),
            meck:expect(router_blockchain, get_hotspot_location_index, fun(_) ->
                {error, use_default_index}
            end)
        end,
        fun(_) -> meck:unload() end,
        [
            ?_test(test_no_subnet()),
            ?_test(test_subnet_wrap()),
            ?_test(test_non_sequential_subnet()),
            ?_test(test_replace_range())
        ]
    }.

test_no_subnet() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    ?assertMatch(
        {reply, {error, no_subnets}, _State},
        handle_call({allocate, no_device, PubKeyBin}, self(), #state{})
    ),
    ok.

test_subnet_wrap() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    {Addrs, _State} = collect_n_addrs(10, PubKeyBin, #state{devaddr_bases = expand_ranges([{1, 5}])}),

    ?assertEqual(as_devaddrs([1, 2, 3, 4, 5, 1, 2, 3, 4, 5]), Addrs),
    ok.

test_non_sequential_subnet() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    State = #state{devaddr_bases = expand_ranges([{1, 2}, {9, 10}])},
    {Addrs, _State} = collect_n_addrs(9, PubKeyBin, State),

    ?assertEqual(as_devaddrs([1, 2, 9, 10, 1, 2, 9, 10, 1]), Addrs),
    ok.

test_replace_range() ->
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% ok = ?MODULE:set_devaddr_bases([{1, 3}]),
    State0 = #state{devaddr_bases = expand_ranges([{1, 3}])},
    {Addrs1, State1} = collect_n_addrs(5, PubKeyBin, State0),
    ?assertEqual(as_devaddrs([1, 2, 3, 1, 2]), Addrs1),

    {reply, ok, State2} = handle_call(
        {set_devaddr_bases, expand_ranges([{10, 30}])}, self(), State1
    ),
    {Addrs2, _State3} = collect_n_addrs(5, PubKeyBin, State2),
    ?assertEqual(as_devaddrs([10, 11, 12, 13, 14]), Addrs2),
    ok.

collect_n_addrs(N, Key, StartState) ->
    lists:foldl(
        fun(_Idx, {Addrs, State0}) ->
            {reply, {ok, Addr}, State1} = ?MODULE:handle_call(
                {allocate, no_device, Key}, self(), State0
            ),
            {Addrs ++ [Addr], State1}
        end,
        {[], StartState},
        lists:seq(1, N)
    ).

as_devaddrs(Xs) -> lists:reverse(as_devaddrs(Xs, [])).

as_devaddrs([], Acc) ->
    Acc;
as_devaddrs([X | Xs], Acc) ->
    as_devaddrs(Xs, [<<X, 0, 0, $H>> | Acc]).

-endif.
