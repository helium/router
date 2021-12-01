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
    sort_devices/3,
    pubkeybin_to_loc/2,
    net_id/1
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
-define(ETS, router_device_devaddr_ets).
%%
-define(BITS_23, 8388607).

-record(state, {
    chain = undefined :: blockchain:blockchain() | undefined,
    oui :: non_neg_integer(),
    subnets = [] :: [binary()],
    devaddr_used = #{} :: map()
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

-spec sort_devices([router_device:device()], libp2p_crypto:pubkey_bin(), blockchain:blockchain()) ->
    [router_device:device()].
sort_devices(Devices, PubKeyBin, Chain) ->
    case ?MODULE:pubkeybin_to_loc(PubKeyBin, Chain) of
        {error, _Reason} ->
            Devices;
        {ok, Index} ->
            [D || {_, D} <- lists:sort([{distance_between(D, Index, Chain), D} || D <- Devices])]
    end.

%% TODO: Maybe make this a ets table to avoid lookups all the time
-spec pubkeybin_to_loc(
    undefined | libp2p_crypto:pubkey_bin(),
    undefined | blockchain:blockchain()
) -> {ok, non_neg_integer()} | {error, any()}.
pubkeybin_to_loc(undefined, _Chain) ->
    {error, undef_pubkeybin};
pubkeybin_to_loc(_PubKeyBin, undefined) ->
    {error, no_chain};
pubkeybin_to_loc(PubKeyBin, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubKeyBin, Ledger) of
        {error, _} = Error ->
            Error;
        {ok, Hotspot} ->
            case blockchain_ledger_gateway_v2:location(Hotspot) of
                undefined -> {error, undef_index};
                Index -> {ok, Index}
            end
    end.

-spec net_id(number() | binary()) -> {ok, non_neg_integer()} | {error, invalid_net_id_type}.
net_id(DevAddr) when erlang:is_number(DevAddr) ->
    net_id(<<DevAddr:32/integer-unsigned>>);
net_id(DevAddr) ->
    try
        Type = net_id_type(DevAddr),
        NetID =
            case Type of
                0 -> get_net_id(DevAddr, 1, 6);
                1 -> get_net_id(DevAddr, 2, 6);
                2 -> get_net_id(DevAddr, 3, 9);
                3 -> get_net_id(DevAddr, 4, 11);
                4 -> get_net_id(DevAddr, 5, 12);
                5 -> get_net_id(DevAddr, 6, 13);
                6 -> get_net_id(DevAddr, 7, 15);
                7 -> get_net_id(DevAddr, 8, 17)
            end,
        {ok, NetID bor (Type bsl 21)}
    catch
        throw:invalid_net_id_type:_ ->
            {error, invalid_net_id_type}
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ok = blockchain_event:add_handler(self()),
    OUI =
        case router_utils:get_oui() of
            undefined -> error(no_oui_configured);
            OUI0 -> OUI0
        end,
    self() ! post_init,
    {ok, #state{oui = OUI}}.

handle_call({allocate, _Device, _PubKeyBin}, _From, #state{subnets = []} = State) ->
    {reply, {error, no_subnet}, State};
handle_call(
    {allocate, _Device, PubKeyBin},
    _From,
    #state{chain = Chain, subnets = Subnets, devaddr_used = Used} = State
) ->
    Index =
        case ?MODULE:pubkeybin_to_loc(PubKeyBin, Chain) of
            {error, _} -> h3:from_geo({0.0, 0.0}, 12);
            {ok, IA} -> IA
        end,
    Parent = h3:to_geo(h3:parent(Index, 1)),
    {NthSubnet, DevaddrBase} =
        case maps:get(Parent, Used, undefined) of
            undefined ->
                <<Base:25/integer-unsigned-big, _Mask:23/integer-unsigned-big>> = hd(Subnets),
                {1, Base};
            {Nth, LastBase} ->
                Subnet = lists:nth(Nth, Subnets),
                <<Base:25/integer-unsigned-big, Mask:23/integer-unsigned-big>> = Subnet,
                Max = blockchain_ledger_routing_v1:subnet_mask_to_size(Mask),
                case LastBase + 1 >= Base + Max of
                    true ->
                        {NextNth, NextSubnet} = next_subnet(Subnets, Nth),
                        <<NextBase:25/integer-unsigned-big, _:23/integer-unsigned-big>> =
                            NextSubnet,
                        {NextNth, NextBase};
                    false ->
                        {Nth, LastBase + 1}
                end
        end,
    Ledger = blockchain:ledger(Chain),
    NetIDList = blockchain_ledger_v1:get_netids(Ledger),
    DevAddr = lorawan:devaddr_from_subnet(DevaddrBase, NetIDList),
    Reply = {ok, DevAddr},
    {reply, Reply, State#state{devaddr_used = maps:put(Parent, {NthSubnet, DevaddrBase}, Used)}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {blockchain_event, {add_block, BlockHash, _Syncing, _Ledger}},
    #state{chain = Chain, oui = OUI} = State
) ->
    {ok, Block} = blockchain:get_block(BlockHash, Chain),
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
            Subnets = subnets(OUI, Chain),
            {noreply, State#state{subnets = Subnets}}
    end;
handle_info({blockchain_event, {integrate_genesis_block, _BlockHash}}, #state{oui = OUI} = State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            Subnets = subnets(OUI, Chain),
            {noreply, State#state{chain = Chain, subnets = Subnets}}
    end;
handle_info(post_init, #state{chain = undefined, oui = OUI} = State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            Subnets = subnets(OUI, Chain),
            {noreply, State#state{chain = Chain, subnets = Subnets}}
    end;
handle_info(post_init, State) ->
    {noreply, State};
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

-spec subnets(non_neg_integer(), blockchain:blockchain()) -> [binary()].
subnets(OUI, Chain) ->
    case blockchain_ledger_v1:find_routing(OUI, blockchain:ledger(Chain)) of
        {ok, RoutingEntry} ->
            blockchain_ledger_routing_v1:subnets(RoutingEntry);
        _ ->
            []
    end.

-spec next_subnet([binary()], non_neg_integer()) -> {non_neg_integer(), binary()}.
next_subnet(Subnets, Nth) ->
    case Nth + 1 > erlang:length(Subnets) of
        true -> {1, lists:nth(1, Subnets)};
        false -> {Nth + 1, lists:nth(Nth + 1, Subnets)}
    end.

-spec distance_between(
    Device :: router_device:device(),
    Index :: h3:index(),
    Chain :: blockchain:blockchain()
) -> non_neg_integer().
distance_between(Device, Index, Chain) ->
    case ?MODULE:pubkeybin_to_loc(router_device:location(Device), Chain) of
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

-spec net_id_type(binary()) -> 0..7.
net_id_type(<<First:8/integer-unsigned, _/binary>>) ->
    net_id_type(First, 7).

-spec net_id_type(non_neg_integer(), non_neg_integer()) -> 0..7.
net_id_type(_, -1) ->
    throw(invalid_net_id_type);
net_id_type(Prefix, Index) ->
    case Prefix band (1 bsl Index) of
        0 -> 7 - Index;
        _ -> net_id_type(Prefix, Index - 1)
    end.

-spec get_net_id(binary(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
get_net_id(DevAddr, PrefixLength, NwkIDBits) ->
    <<Temp:32/integer-unsigned>> = DevAddr,
    %% Remove type prefix
    One = uint32(Temp bsl PrefixLength),
    %% Remove NwkAddr suffix
    Two = uint32(One bsr (32 - NwkIDBits)),

    IgnoreSize = 32 - NwkIDBits,
    <<_:IgnoreSize, NetID:NwkIDBits/integer-unsigned>> = <<Two:32/integer-unsigned>>,
    NetID.

-spec uint32(integer()) -> integer().
uint32(Num) ->
    Num band 4294967295.

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
    meck:new(blockchain, [passthrough]),
    meck:expect(blockchain, ledger, fun(chain) -> ledger end),
    meck:new(blockchain_ledger_v1, [passthrough]),
    meck:expect(blockchain_ledger_v1, find_gateway_info, fun(PubKeyBin, ledger) ->
        {ok, blockchain_ledger_gateway_v2:new(PubKeyBin, maps:get(PubKeyBin, Hotspots))}
    end),

    Randomized = lists:sort([{rand:uniform(), N} || N <- maps:keys(Hotspots)]),
    Devices = [router_device:location(ID, router_device:new(ID)) || {_, ID} <- Randomized],

    ?assertEqual([<<"A">>, <<"B">>, <<"C">>, <<"D">>], [
        router_device:id(D)
        || D <- sort_devices(Devices, <<"A">>, chain)
    ]),

    ?assertEqual([<<"B">>, <<"A">>, <<"C">>, <<"D">>], [
        router_device:id(D)
        || D <- sort_devices(Devices, <<"B">>, chain)
    ]),

    ?assertEqual([<<"C">>, <<"D">>, <<"B">>, <<"A">>], [
        router_device:id(D)
        || D <- sort_devices(Devices, <<"C">>, chain)
    ]),

    ?assertEqual([<<"D">>, <<"C">>, <<"B">>, <<"A">>], [
        router_device:id(D)
        || D <- sort_devices(Devices, <<"D">>, chain)
    ]),

    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain),
    ?assert(meck:validate(blockchain_ledger_v1)),
    meck:unload(blockchain_ledger_v1),
    ok.

sort_devices_long_distance_test() ->
    Hotspots = #{
        <<"HOUSTON">> => ?HOUSTON,
        <<"SUNNYVALE">> => ?SUNNYVALE,
        <<"SAN_JOSE">> => ?SAN_JOSE
    },
    meck:new(blockchain, [passthrough]),
    meck:expect(blockchain, ledger, fun(chain) -> ledger end),
    meck:new(blockchain_ledger_v1, [passthrough]),
    meck:expect(blockchain_ledger_v1, find_gateway_info, fun(PubKeyBin, ledger) ->
        {ok, blockchain_ledger_gateway_v2:new(PubKeyBin, maps:get(PubKeyBin, Hotspots))}
    end),

    Randomized = lists:sort([{rand:uniform(), N} || N <- maps:keys(Hotspots)]),
    Devices = [router_device:location(ID, router_device:new(ID)) || {_, ID} <- Randomized],

    ?assertEqual([<<"SAN_JOSE">>, <<"SUNNYVALE">>, <<"HOUSTON">>], [
        router_device:id(D)
        || D <- sort_devices(Devices, <<"SAN_JOSE">>, chain)
    ]),

    ?assertEqual([<<"SUNNYVALE">>, <<"SAN_JOSE">>, <<"HOUSTON">>], [
        router_device:id(D)
        || D <- sort_devices(Devices, <<"SUNNYVALE">>, chain)
    ]),

    ?assertEqual([<<"HOUSTON">>, <<"SAN_JOSE">>, <<"SUNNYVALE">>], [
        router_device:id(D)
        || D <- sort_devices(Devices, <<"HOUSTON">>, chain)
    ]),

    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain),
    ?assert(meck:validate(blockchain_ledger_v1)),
    meck:unload(blockchain_ledger_v1),
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

net_id_test() ->
    lists:foreach(
        fun(#{expect := Expect, bin := Bin, num := Num, msg := Msg}) ->
            %% Make sure Bin and Num are the same thing
            Bin = <<Num:32>>,
            ?assertEqual(Expect, net_id(Bin), "BIN: " ++ Msg),
            ?assertEqual(Expect, net_id(Num), "NUM: " ++ Msg)
        end,
        [
            #{
                expect => {ok, 16#00002D},
                num => 1543503871,
                bin => <<91, 255, 255, 255>>,
                %% truncated byte output == hex == integer
                msg => "[45] == 2D == 45 type 0"
            },
            #{
                expect => {ok, 16#20002D},
                num => 2919235583,
                bin => <<173, 255, 255, 255>>,
                msg => "[45] == 2D == 45 type 1"
            },
            #{
                expect => {ok, 16#40016D},
                num => 3605004287,
                bin => <<214, 223, 255, 255>>,
                msg => "[1,109] == 16D == 365 type 2"
            },
            #{
                expect => {ok, 16#6005B7},
                num => 3949985791,
                bin => <<235, 111, 255, 255>>,
                msg => "[5,183] == 5B7 == 1463 type 3"
            },
            #{
                expect => {ok, 16#800B6D},
                num => 4122411007,
                bin => <<245, 182, 255, 255>>,
                msg => "[11, 109] == B6D == 2925 type 4"
            },
            #{
                expect => {ok, 16#A016DB},
                num => 4208689151,
                bin => <<250, 219, 127, 255>>,
                msg => "[22,219] == 16DB == 5851 type 5"
            },
            #{
                expect => {ok, 16#C05B6D},
                num => 4251826175,
                bin => <<253, 109, 183, 255>>,
                msg => "[91, 109] == 5B6D == 23405 type 6"
            },
            #{
                expect => {ok, 16#E16DB6},
                num => 4273396607,
                bin => <<254, 182, 219, 127>>,
                msg => "[1,109,182] == 16DB6 == 93622 type 7"
            },
            #{
                expect => {error, invalid_net_id_type},
                num => 4294967295,
                bin => <<255, 255, 255, 255>>,
                msg => "Invalid DevAddr"
            },
            #{
                expect => {ok, 16#000000},
                %% Way under 32 bit number
                num => 46377,
                bin => <<0, 0, 181, 41>>,
                msg => "[0] == 0 == 0"
            },
            #{
                expect => {ok, 16#200029},
                num => 2838682043,
                bin => <<169, 50, 217, 187>>,
                msg => "[41] == 29 == 41 type 1"
            }
        ]
    ).

-endif.
