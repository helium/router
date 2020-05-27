%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Devaddr ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_devaddr).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         allocate/2]).

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

-record(state, {chain :: blockchain:blockchain(),
                oui :: integer(),
                subnets = [] :: list(),
                devaddr_used = #{} :: map()}).

                                                % -type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

allocate(Device, PubKeyBin) ->
    gen_server:call(?SERVER, {allocate, Device, PubKeyBin}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Chain = blockchain_worker:blockchain(),
    OUI = case application:get_env(router, oui, undefined) of
              undefined -> undefined;
              OUI0 when is_list(OUI0) ->
                  list_to_integer(OUI0);
              OUI0 ->
                  OUI0
          end,
    Subnets = subnets(OUI, Chain),
    {ok, #state{chain=Chain, oui=OUI, subnets=Subnets}}.

handle_call({allocate, _Device, _PubKeyBin}, _From, #state{chain=undefined, oui=OUI}=State) ->
    Chain = blockchain_worker:blockchain(),
    Subnets = subnets(OUI, Chain),
    {reply, {error, chain_undef}, State#state{chain=Chain, subnets=Subnets}};
handle_call({allocate, _Device, PubKeyBin}, _From, #state{chain=Chain, subnets=Subnets, devaddr_used=Used}=State) ->
    case pubkeybin_to_loc(PubKeyBin, Chain) of
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
                        Max = subnet_mask_to_size(Mask),
                        case LastBase+1 > Base+Max of
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

subnets(_OUI, undefined) ->
    [];
subnets(OUI, Chain) ->
    case blockchain_ledger_v1:find_routing(OUI, blockchain:ledger(Chain)) of
        {ok, RoutingEntry} ->
            blockchain_ledger_routing_v1:subnets(RoutingEntry);
        _ ->
            []
    end.

pubkeybin_to_loc(PubKeyBin, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubKeyBin, Ledger) of
        {error, _}=Error ->
            Error;
        {ok, Hotspot} ->
            Index = blockchain_ledger_gateway_v2:location(Hotspot),
            {ok, Index}
    end.

subnet_mask_to_size(Mask) ->
    (((Mask bxor ?BITS_23) bsl 2) + 2#11) + 1.

next_subnet(Subnets, Nth) ->
    case Nth+1 > erlang:length(Subnets) of
        true -> {1, lists:nth(1, Subnets)};
        false -> {Nth+1, lists:nth(Nth+1, Subnets)}
    end.