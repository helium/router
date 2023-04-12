-module(router_blockchain).

-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
    is_chain_dead/0,
    %% router stuff
    calculate_dc_amount/1,
    get_hotspot_lat_lon/1,
    get_hotspot_location_index/1,
    subnets_for_oui/1,
    routing_for_oui/1,
    get_ouis/0,
    find_gateway_owner/1,
    track_offer/2,
    %% special
    privileged_maybe_get_blockchain/0,
    %% blockchain stuff ========
    height/0,
    sync_height/0,
    head_block/0,
    head_block_time/0,
    get_blockhash/1,
    %% xor filter =======
    max_xor_filter_num/0,
    calculate_routing_txn_fee/1,
    %% sc worker =======
    sc_version/0,
    max_open_sc/0,
    find_dc_entry/1,
    calculate_state_channel_open_fee/1,
    save_key/1,
    get_key/0
]).

-define(ROUTER_KEY, router_key).

%% ===================================================================
%% To be supplemented with Config Service
%% ===================================================================

-spec is_chain_dead() -> boolean().
is_chain_dead() ->
    router_utils:get_env_bool(is_chain_dead, false).

%% DC Tracker
%% Router Console Events
-spec calculate_dc_amount(PayloadSize :: non_neg_integer()) -> pos_integer() | {error, any()}.
calculate_dc_amount(PayloadSize) ->
    case ?MODULE:is_chain_dead() of
        false -> blockchain_utils:calculate_dc_amount(ledger(), PayloadSize);
        %% 1 DC per 24 bytes of data
        true -> erlang:ceil(PayloadSize / 24)
    end.

%% Router Console Events
%% Channel Payloads
-spec get_hotspot_lat_lon(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {float(), float()} | {unknown, unknown}.
get_hotspot_lat_lon(PubKeyBin) ->
    case ?MODULE:is_chain_dead() orelse application:get_env(router, enable_ics_location, false) of
        false ->
            case ?MODULE:get_hotspot_location_index(PubKeyBin) of
                {error, _} ->
                    {unknown, unknown};
                {ok, Loc} ->
                    h3:to_geo(Loc)
            end;
        true ->
            case router_ics_gateway_location_worker:get(PubKeyBin) of
                {error, _} ->
                    {unknown, unknown};
                {ok, Index} ->
                    h3:to_geo(Index)
            end
    end.

%% Assigning DevAddrs
-spec get_hotspot_location_index(PubKeybin :: libp2p_crypto:pubkey_bin()) ->
    {ok, non_neg_integer()} | {error, any()}.
get_hotspot_location_index(PubKeyBin) ->
    case ?MODULE:is_chain_dead() orelse application:get_env(router, enable_ics_location, false) of
        false ->
            case persistent_term:get(hotspot_location_cache, undefined) of
                undefined ->
                    case blockchain_ledger_v1:find_gateway_location(PubKeyBin, ledger()) of
                        {ok, undefined} -> {error, undef_index};
                        {error, _} = Error -> Error;
                        {ok, Index} -> {ok, Index}
                    end;
                Cache ->
                    cream:cache(Cache, PubKeyBin, fun() ->
                        case blockchain_ledger_v1:find_gateway_location(PubKeyBin, ledger()) of
                            {ok, undefined} -> {error, undef_index};
                            {error, _} = Error -> Error;
                            {ok, Index} -> {ok, Index}
                        end
                    end)
            end;
        true ->
            router_ics_gateway_location_worker:get(PubKeyBin)
    end.

%% Assigning DevAddrs
%% Validating DevAddrs (redundant?)
-spec subnets_for_oui(OUI :: non_neg_integer()) -> [binary()].
subnets_for_oui(OUI) ->
    case ?MODULE:routing_for_oui(OUI) of
        {ok, RoutingEntry} ->
            blockchain_ledger_routing_v1:subnets(RoutingEntry);
        _ ->
            []
    end.

-spec routing_for_oui(OUI :: non_neg_integer()) ->
    {ok, blockchain_ledger_routing_v1:routing()} | {error, any()}.
routing_for_oui(OUI) ->
    blockchain_ledger_v1:find_routing(OUI, ledger()).

-spec get_ouis() -> [{binary(), binary()}].
get_ouis() ->
    blockchain_ledger_v1:snapshot_ouis(ledger()).

-spec find_gateway_owner(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, libp2p_crypto:pubkey_bin()} | {error, any()}.
find_gateway_owner(PubKeyBin) ->
    blockchain_ledger_v1:find_gateway_owner(PubKeyBin, ledger()).

-spec track_offer(Offer :: blockchain_state_channel_offer_v1:offer(), HandlerPid :: pid()) ->
    ok | reject.
track_offer(Offer, HandlerPid) ->
    case ?MODULE:is_chain_dead() of
        true -> ok;
        false -> blockchain_state_channels_server:track_offer(Offer, ledger(), HandlerPid)
    end.

%% ===================================================================
%% Metrics only
%% ===================================================================

-spec privileged_maybe_get_blockchain() -> blockchain:blockchain() | undefined.
privileged_maybe_get_blockchain() ->
    Key = router_blockchain,
    persistent_term:get(Key, undefined).

%% ===================================================================
%% DNR
%% ===================================================================
-spec height() -> {ok, non_neg_integer()} | {error, any()}.
height() ->
    blockchain:height(blockchain()).

-spec sync_height() -> {ok, non_neg_integer()} | {error, any()}.
sync_height() ->
    blockchain:sync_height(blockchain()).

-spec head_block() -> {ok, blockchain_block:block()} | {error, any()}.
head_block() ->
    Chain = blockchain(),
    blockchain:head_block(Chain).

-spec head_block_time() -> non_neg_integer().
head_block_time() ->
    {ok, Block} = head_block(),
    blockchain_block:time(Block).

-spec get_blockhash(Hash :: blockchain_block:hash() | integer()) ->
    {ok, blockchain_block:block()} | {error, any()}.
get_blockhash(Hash) ->
    blockchain:get_block(Hash, blockchain()).

%% XOR Filter=======

-spec max_xor_filter_num() -> {ok, non_neg_integer()} | {error, any()}.
max_xor_filter_num() ->
    blockchain:config(?max_xor_filter_num, ledger()).

-spec calculate_routing_txn_fee(blockchain_txn_routing_v1:txn_routing()) -> non_neg_integer().
calculate_routing_txn_fee(Txn) ->
    blockchain_txn_routing_v1:calculate_fee(Txn, blockchain()).

%% XOR Filter=======

-spec sc_version() -> {ok, non_neg_integer()} | {error, any()}.
sc_version() ->
    blockchain:config(?sc_version, ledger()).

-spec max_open_sc() -> {ok, non_neg_integer()} | {error, any()}.
max_open_sc() ->
    blockchain:config(?max_open_sc, ledger()).

-spec find_dc_entry(PubkeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, blockchain_ledger_data_credits_entry_v1:data_credits_entry()} | {error, any()}.
find_dc_entry(PubKeyBin) ->
    blockchain_ledger_v1:find_dc_entry(PubKeyBin, ledger()).

-spec calculate_state_channel_open_fee(
    blockchain_txn_state_channel_open_v1:txn_state_channel_open()
) -> non_neg_integer().
calculate_state_channel_open_fee(Txn) ->
    blockchain_txn_state_channel_open_v1:calculate_fee(Txn, blockchain()).

-spec save_key(
    Key :: {libp2p_crypto:public_key(), libp2p_crypto:sig_fun(), libp2p_crypto:ecdh_fun()}
) -> ok.
save_key(Key) ->
    ok = persistent_term:put(?ROUTER_KEY, Key).

-spec get_key() ->
    {libp2p_crypto:public_key(), libp2p_crypto:sig_fun(), libp2p_crypto:ecdh_fun()} | undefined.
get_key() ->
    persistent_term:get(?ROUTER_KEY, undefined).

%% ===================================================================
%% Unexported, no touchy
%% ===================================================================

-spec blockchain() -> blockchain:blockchain().
blockchain() ->
    Key = router_blockchain,
    case persistent_term:get(Key, undefined) of
        undefined ->
            Chain = blockchain_worker:blockchain(),
            ok = persistent_term:put(Key, Chain),
            Chain;
        Chain ->
            Chain
    end.

-spec ledger() -> blockchain:ledger().
ledger() ->
    blockchain:ledger(blockchain()).
