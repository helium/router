-module(router_utils).

-export([get_router_oui/1,
         get_hotspot_location/2,
         to_bin/1]).

-spec get_router_oui(Chain :: blockchain:blockchain()) -> non_neg_integer() | undefined.
get_router_oui(Chain) ->
    Ledger = blockchain:ledger(Chain),
    PubkeyBin = blockchain_swarm:pubkey_bin(),
    case blockchain_ledger_v1:get_oui_counter(Ledger) of
        {error, _} -> undefined;
        {ok, 0} -> undefined;
        {ok, _OUICounter} ->
            %% there are some ouis on chain
            find_oui(PubkeyBin, Ledger)
    end.

-spec get_hotspot_location(PubKeyBin :: libp2p_crypto:pubkey_bin(), Blockchain :: blockchain:blockchain()) -> {float(), float()} | {unknown, unknown}.
get_hotspot_location(PubKeyBin, Blockchain) ->
    Ledger = blockchain:ledger(Blockchain),
    case blockchain_ledger_v1:find_gateway_info(PubKeyBin, Ledger) of
        {error, _} -> {unknown, unknown};
        {ok, Hotspot} ->
            Loc = blockchain_ledger_gateway_v2:location(Hotspot),
            h3:to_geo(Loc)
    end.

to_bin(Bin) when is_binary(Bin) ->
    Bin;
to_bin(List) when is_list(List) ->
    erlang:list_to_binary(List).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_oui(PubkeyBin :: libp2p_crypto:pubkey_bin(),
               Ledger :: blockchain_ledger_v1:ledger()) -> non_neg_integer() | undefined.
find_oui(PubkeyBin, Ledger) ->
    MyOUIs = blockchain_ledger_v1:find_router_ouis(PubkeyBin, Ledger),
    case application:get_env(router, oui, undefined) of
        undefined ->
            %% still check on chain
            case MyOUIs of
                [] -> undefined;
                [OUI] -> OUI;
                [H|_T] ->
                    H
            end;
        OUI0 when is_list(OUI0) ->
            %% app env comes in as a string
            OUI = list_to_integer(OUI0),
            check_oui_on_chain(OUI, MyOUIs);
        OUI ->
            check_oui_on_chain(OUI, MyOUIs)
    end.


-spec check_oui_on_chain(non_neg_integer(), [non_neg_integer()]) -> non_neg_integer() | undefined.
check_oui_on_chain(OUI, OUIsOnChain) ->
    case lists:member(OUI, OUIsOnChain) of
        false ->
            undefined;
        true ->
            OUI
    end.
