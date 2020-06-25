%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Devaddr ==
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
-export([start_link/1,
         default_devaddr/0,
         allocate/2,
         sort_devices/2,
         pubkeybin_to_loc/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS, router_device_devaddr_ets).
-define(BITS_23, 8388607). %% 

-record(state, {chain = undefined :: blockchain:blockchain() | undefined,
                oui :: non_neg_integer(),
                subnets = [] :: [binary()],
                devaddr_used = #{} :: map()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec default_devaddr() -> binary().
default_devaddr() ->
    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    application:get_env(router, default_devaddr, <<33554431:25/integer-unsigned-little, DevAddrPrefix:7/integer>>).

-spec allocate(router_device:device(), libp2p_crypto:pubkey_bin()) ->  {ok, binary()} | {error, any()}.
allocate(Device, PubKeyBin) ->
    gen_server:call(?SERVER, {allocate, Device, PubKeyBin}).

-spec sort_devices([router_device:device()], libp2p_crypto:pubkey_bin()) -> [router_device:device()].
sort_devices(Devices, PubKeyBin) ->
    Chain = blockchain_worker:blockchain(),
    case ?MODULE:pubkeybin_to_loc(PubKeyBin, Chain) of
        {error, _Reason} ->
            Devices;
        {ok, Index} ->
            lists:sort(fun(A, B) -> sort_devices_fun(A, B, Index) end, Devices)
    end.

%% TODO: Maybe make this a ets table to avoid lookups all the time
-spec pubkeybin_to_loc(undefined | libp2p_crypto:pubkey_bin(), undefined | blockchain:blockchain()) -> {ok, non_neg_integer()} | {error, any()}.
pubkeybin_to_loc(undefined, _Chain) ->
    {error, undef_pubkeybin};
pubkeybin_to_loc(_PubKeyBin, undefined) ->
    {error, no_chain};
pubkeybin_to_loc(PubKeyBin, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubKeyBin, Ledger) of
        {error, _}=Error ->
            Error;
        {ok, Hotspot} ->
            Index = blockchain_ledger_gateway_v2:location(Hotspot),
            {ok, Index}
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    OUI = case application:get_env(router, oui, undefined) of
              undefined -> undefined;
              OUI0 when is_list(OUI0) ->
                  list_to_integer(OUI0);
              OUI0 ->
                  OUI0
          end,
    self() ! post_init,
    {ok, #state{oui=OUI}}.

handle_call({allocate, _Device, _PubKeyBin}, _From, #state{subnets=[]}=State) ->
    {reply, {error, no_subnet}, State};
handle_call({allocate, _Device, PubKeyBin}, _From, #state{chain=Chain, subnets=Subnets, devaddr_used=Used}=State) ->
    case ?MODULE:pubkeybin_to_loc(PubKeyBin, Chain) of
        {error, _}=Error ->
            {reply, Error, State};
        {ok, Index} ->
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
                        case LastBase+1 >= Base+Max of
                            true ->
                                {NextNth, NextSubnet} = next_subnet(Subnets, Nth),
                                <<NextBase:25/integer-unsigned-big, _:23/integer-unsigned-big>> = NextSubnet,
                                {NextNth, NextBase};
                            false ->
                                {Nth, LastBase+1} 
                        end
                end,
            DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
            Reply = {ok, <<DevaddrBase:25/integer-unsigned-little, DevAddrPrefix:7/integer>>},
            {reply, Reply, State#state{devaddr_used=maps:put(Parent, {NthSubnet, DevaddrBase}, Used)}}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{chain=undefined, oui=OUI}=State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            Subnets = subnets(OUI, Chain),
            {noreply, State#state{chain=Chain, subnets=Subnets}}
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
    case Nth+1 > erlang:length(Subnets) of
        true -> {1, lists:nth(1, Subnets)};
        false -> {Nth+1, lists:nth(Nth+1, Subnets)}
    end.

-spec sort_devices_fun(router_device:device(), router_device:device(), h3:index()) -> boolean().
sort_devices_fun(DeviceA, DeviceB, Index) ->
    Chain = blockchain_worker:blockchain(),
    IndexA = case ?MODULE:pubkeybin_to_loc(router_device:location(DeviceA), Chain) of
                 {error, _} -> undefined;
                 {ok, IA} -> IA
             end,
    IndexB = case ?MODULE:pubkeybin_to_loc(router_device:location(DeviceB), Chain) of
                 {error, _} -> undefined;
                 {ok, IB} -> IB
             end,
    case
        h3:get_resolution(IndexA) == h3:get_resolution(IndexB) andalso
        h3:get_resolution(IndexA) == h3:get_resolution(Index)
    of
        false ->
            {IndexA1, Indexb1, Index1} = indexes_to_lowest_res(IndexA, IndexB, Index),
            h3:grid_distance(IndexA1, Index1) > h3:grid_distance(Indexb1, Index1);
        true ->
            h3:grid_distance(IndexA, Index) > h3:grid_distance(IndexB, Index)
    end.

-spec indexes_to_lowest_res(h3:index(), h3:index(), h3:index()) -> {h3:index(), h3:index(), h3:index()}.
indexes_to_lowest_res(IndexA, IndexB, IndexC) ->
    Resolutions = [h3:get_resolution(IndexA), h3:get_resolution(IndexB), h3:get_resolution(IndexC)],
    LowestRes = lists:min(Resolutions),
    {to_res(IndexA, LowestRes), to_res(IndexB, LowestRes), to_res(IndexC, LowestRes)}.

-spec to_res(h3:index(), non_neg_integer()) -> h3:index().
to_res(Index, Res) ->
    h3:from_geo(h3:to_geo(Index), Res).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.