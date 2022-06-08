%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Device ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_device).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("router_device.hrl").
-include("router_device_worker.hrl").

%% ------------------------------------------------------------------
%% router_device Type Exports
%% ------------------------------------------------------------------
-export([
    new/1,
    id/1,
    name/1, name/2,
    app_eui/1, app_eui/2,
    dev_eui/1, dev_eui/2,
    keys/1, keys/2,
    nwk_s_key/1,
    app_s_key/1,
    devaddr/1,
    devaddrs/1, devaddrs/2,
    dev_nonces/1, dev_nonces/2,
    fcnt/1, fcnt/2,
    fcntdown/1, fcntdown/2,
    offset/1, offset/2,
    channel_correction/1, channel_correction/2,
    queue/1, queue/2,
    region/1, region/2,
    last_known_datarate/1, last_known_datarate/2,
    ecc_compact/1, ecc_compact/2,
    location/1, location/2,
    metadata/1, metadata/2,
    is_active/1, is_active/2,
    preferred_hotspots/1,
    update/2,
    serialize/1,
    deserialize/1
]).
-export([
    can_queue_payload/3
]).

%% ------------------------------------------------------------------
%% RocksDB Device Exports
%% ------------------------------------------------------------------
-export([
    get/2, get/3,
    get_by_id/3,
    save/3,
    delete/3
]).

-define(QUEUE_SIZE_LIMIT, 20).

-type device() :: #device_v7{}.

-export_type([device/0]).

%% ------------------------------------------------------------------
%% Device Functions
%% ------------------------------------------------------------------

-spec new(binary()) -> device().
new(ID) ->
    #device_v7{
        id = ID
    }.

-spec id(device()) -> binary() | undefined.
id(Device) ->
    Device#device_v7.id.

-spec name(device()) -> binary() | undefined.
name(Device) ->
    Device#device_v7.name.

-spec name(binary(), device()) -> device().
name(Name, Device) ->
    Device#device_v7{name = Name}.

-spec app_eui(device()) -> binary() | undefined.
app_eui(Device) ->
    Device#device_v7.app_eui.

-spec app_eui(binary(), device()) -> device().
app_eui(EUI, Device) ->
    Device#device_v7{app_eui = EUI}.

-spec dev_eui(device()) -> binary() | undefined.
dev_eui(Device) ->
    Device#device_v7.dev_eui.

-spec dev_eui(binary(), device()) -> device().
dev_eui(EUI, Device) ->
    Device#device_v7{dev_eui = EUI}.

-spec keys(device()) -> list({binary() | undefined, binary() | undefined}).
keys(#device_v7{keys = Keys}) ->
    Keys.

-spec keys(list({binary(), binary()}), device()) -> device().
keys(Keys, Device) ->
    Device#device_v7{keys = lists:sublist(Keys, 25)}.

-spec nwk_s_key(device()) -> binary() | undefined.
nwk_s_key(#device_v7{keys = []}) ->
    undefined;
nwk_s_key(#device_v7{keys = [{NwkSKey, _AppSKey} | _]}) ->
    NwkSKey.

-spec app_s_key(device()) -> binary() | undefined.
app_s_key(#device_v7{keys = []}) ->
    undefined;
app_s_key(#device_v7{keys = [{_NwkSKey, AppSKey} | _]}) ->
    AppSKey.

-spec devaddr(device()) -> binary() | undefined.
devaddr(Device) ->
    case Device#device_v7.devaddrs of
        [] -> undefined;
        [D | _] -> D
    end.

-spec devaddrs(device()) -> [binary()].
devaddrs(Device) ->
    Device#device_v7.devaddrs.

-spec devaddrs([binary()], device()) -> device().
devaddrs(Devaddrs, Device) ->
    Device#device_v7{devaddrs = lists:sublist(Devaddrs, 25)}.

-spec dev_nonces(device()) -> [binary()].
dev_nonces(Device) ->
    Device#device_v7.dev_nonces.

-spec dev_nonces([binary()], device()) -> device().
dev_nonces(Nonces, Device) ->
    Device#device_v7{dev_nonces = lists:sublist(Nonces, 25)}.

-spec fcnt(device()) -> non_neg_integer().
fcnt(Device) ->
    Device#device_v7.fcnt.

-spec fcnt(non_neg_integer(), device()) -> device().
fcnt(Fcnt, Device) ->
    Device#device_v7{fcnt = Fcnt}.

-spec fcntdown(device()) -> non_neg_integer().
fcntdown(Device) ->
    Device#device_v7.fcntdown.

-spec fcntdown(non_neg_integer(), device()) -> device().
fcntdown(Fcnt, Device) ->
    Device#device_v7{fcntdown = Fcnt}.

-spec offset(device()) -> non_neg_integer().
offset(Device) ->
    Device#device_v7.offset.

-spec offset(non_neg_integer(), device()) -> device().
offset(Offset, Device) ->
    Device#device_v7{offset = Offset}.

-spec channel_correction(device()) -> boolean().
channel_correction(Device) ->
    Device#device_v7.channel_correction.

-spec channel_correction(boolean(), device()) -> device().
channel_correction(Correct, Device) ->
    Device#device_v7{channel_correction = Correct}.

-spec queue(device()) -> [#downlink{} | any()].
queue(Device) ->
    Device#device_v7.queue.

-spec queue([#downlink{}], device()) -> device().
queue(Q, Device) ->
    Device#device_v7{queue = Q}.

-spec region(device()) -> atom().
region(Device) ->
    Device#device_v7.region.

-spec region(atom(), device()) -> device().
region(Region, Device) ->
    Device#device_v7{region = Region}.

-spec last_known_datarate(device()) -> integer().
last_known_datarate(Device) ->
    Device#device_v7.last_known_datarate.

-spec last_known_datarate(integer(), device()) -> device().
last_known_datarate(DR, Device) ->
    Device#device_v7{last_known_datarate = DR}.

-spec ecc_compact(device()) -> map().
ecc_compact(Device) ->
    %% NOTE: https://github.com/erlang/otp/commit/37a58368d7876e325710a4c269f0af27b40434c6#diff-b190dfbfb70f8d4c5a3c13699d85f65523bf79dd630117ccf6cd535ee6945996
    %% That commit to OTP/24 added another field to the #'ECPrivateKey'{} record.
    %% Until we can update all of them in our db, let's upgrade to the new record when they're requested.
    case Device#device_v7.ecc_compact of
        #{secret := {ecc_compact, {'ECPrivateKey', Version, PrivKey, Params, PubKey}}} = Map ->
            Map#{
                secret =>
                    {ecc_compact, {'ECPrivateKey', Version, PrivKey, Params, PubKey, asn1_NOVALUE}}
            };
        M ->
            M
    end.

-spec ecc_compact(map(), device()) -> device().
ecc_compact(Keys, Device) ->
    Device#device_v7{ecc_compact = Keys}.

-spec location(device()) -> libp2p_crypto:pubkey_bin() | undefined.
location(Device) ->
    Device#device_v7.location.

-spec location(libp2p_crypto:pubkey_bin() | undefined, device()) -> device().
location(PubkeyBin, Device) ->
    Device#device_v7{location = PubkeyBin}.

-spec metadata(device()) -> map().
metadata(Device) ->
    Device#device_v7.metadata.

-spec metadata(map(), device()) -> device().
metadata(Meta1, #device_v7{metadata = Meta0} = Device) ->
    Device#device_v7{metadata = maps:merge(Meta0, Meta1)}.

-spec is_active(device()) -> boolean().
is_active(Device) ->
    Device#device_v7.is_active.

-spec is_active(boolean(), device()) -> device().
is_active(IsActive, Device) ->
    Device#device_v7{is_active = IsActive}.

-spec preferred_hotspots(device()) -> [libp2p_crypto:pubkey_bin()].
preferred_hotspots(Device) ->
    maps:get(preferred_hotspots, Device#device_v7.metadata, []).

-spec update([{atom(), any()}], device()) -> device().
update([], Device) ->
    Device;
update([{name, Value} | T], Device) ->
    update(T, ?MODULE:name(Value, Device));
update([{app_eui, Value} | T], Device) ->
    update(T, ?MODULE:app_eui(Value, Device));
update([{dev_eui, Value} | T], Device) ->
    update(T, ?MODULE:dev_eui(Value, Device));
update([{keys, Value} | T], Device) ->
    update(T, ?MODULE:keys(Value, Device));
update([{devaddrs, Value} | T], Device) ->
    update(T, ?MODULE:devaddrs(Value, Device));
update([{dev_nonces, Value} | T], Device) ->
    update(T, ?MODULE:dev_nonces(Value, Device));
update([{fcnt, Value} | T], Device) ->
    update(T, ?MODULE:fcnt(Value, Device));
update([{fcntdown, Value} | T], Device) ->
    update(T, ?MODULE:fcntdown(Value, Device));
update([{offset, Value} | T], Device) ->
    update(T, ?MODULE:offset(Value, Device));
update([{channel_correction, Value} | T], Device) ->
    update(T, ?MODULE:channel_correction(Value, Device));
update([{queue, Value} | T], Device) ->
    update(T, ?MODULE:queue(Value, Device));
update([{region, Value} | T], Device) ->
    update(T, ?MODULE:region(Value, Device));
update([{last_known_datarate, Value} | T], Device) ->
    update(T, ?MODULE:last_known_datarate(Value, Device));
update([{ecc_compact, Value} | T], Device) ->
    update(T, ?MODULE:ecc_compact(Value, Device));
update([{location, Value} | T], Device) ->
    update(T, ?MODULE:location(Value, Device));
update([{metadata, Value} | T], Device) ->
    update(T, ?MODULE:metadata(Value, Device));
update([{is_active, Value} | T], Device) ->
    update(T, ?MODULE:is_active(Value, Device)).

-spec serialize(device()) -> binary().
serialize(Device) ->
    erlang:term_to_binary(Device).

-spec deserialize(binary()) -> device().
deserialize(Binary) ->
    case erlang:binary_to_term(Binary) of
        %% TODO promote `rx_delay' out of `metadata', so metadata can
        %% then merely signal when Console changed that value.
        #device_v7{} = V7 ->
            V7;
        #device_v6{} = V6 ->
            Devaddrs =
                case V6#device_v6.devaddr of
                    undefined -> [];
                    DevAddr -> [DevAddr]
                end,
            #device_v7{
                id = V6#device_v6.id,
                name = V6#device_v6.name,
                dev_eui = V6#device_v6.dev_eui,
                app_eui = V6#device_v6.app_eui,
                keys = V6#device_v6.keys,
                devaddrs = Devaddrs,
                dev_nonces = V6#device_v6.dev_nonces,
                fcnt = V6#device_v6.fcnt,
                fcntdown = V6#device_v6.fcntdown,
                offset = V6#device_v6.offset,
                channel_correction = V6#device_v6.channel_correction,
                queue = V6#device_v6.queue,
                region = undefined,
                last_known_datarate = undefined,
                ecc_compact = V6#device_v6.ecc_compact,
                location = V6#device_v6.location,
                metadata = V6#device_v6.metadata,
                is_active = V6#device_v6.is_active
            };
        #device_v5{} = V5 ->
            Devaddrs =
                case V5#device_v5.devaddr of
                    undefined -> [];
                    DevAddr -> [DevAddr]
                end,
            #device_v7{
                id = V5#device_v5.id,
                name = V5#device_v5.name,
                dev_eui = V5#device_v5.dev_eui,
                app_eui = V5#device_v5.app_eui,
                keys = V5#device_v5.keys,
                devaddrs = Devaddrs,
                dev_nonces = V5#device_v5.dev_nonces,
                fcnt = V5#device_v5.fcnt,
                fcntdown = V5#device_v5.fcntdown,
                offset = V5#device_v5.offset,
                channel_correction = V5#device_v5.channel_correction,
                queue = V5#device_v5.queue,
                region = undefined,
                last_known_datarate = undefined,
                ecc_compact = V5#device_v5.ecc_compact,
                location = V5#device_v5.location,
                metadata = V5#device_v5.metadata,
                is_active = V5#device_v5.is_active
            };
        #device_v4{} = V4 ->
            Devaddrs =
                case V4#device_v4.devaddr of
                    undefined -> [];
                    DevAddr -> [DevAddr]
                end,
            #device_v7{
                id = V4#device_v4.id,
                name = V4#device_v4.name,
                dev_eui = V4#device_v4.dev_eui,
                app_eui = V4#device_v4.app_eui,
                keys = [{V4#device_v4.nwk_s_key, V4#device_v4.app_s_key}],
                devaddrs = Devaddrs,
                dev_nonces = [V4#device_v4.join_nonce],
                fcnt = V4#device_v4.fcnt,
                fcntdown = V4#device_v4.fcntdown,
                offset = V4#device_v4.offset,
                channel_correction = V4#device_v4.channel_correction,
                queue = V4#device_v4.queue,
                region = undefined,
                last_known_datarate = undefined,
                ecc_compact = V4#device_v4.keys,
                location = V4#device_v4.location,
                metadata = V4#device_v4.metadata,
                is_active = V4#device_v4.is_active
            };
        #device_v3{} = V3 ->
            Devaddrs =
                case V3#device_v3.devaddr of
                    undefined -> [];
                    DevAddr -> [DevAddr]
                end,
            #device_v7{
                id = V3#device_v3.id,
                name = V3#device_v3.name,
                dev_eui = V3#device_v3.dev_eui,
                app_eui = V3#device_v3.app_eui,
                keys = [{V3#device_v3.nwk_s_key, V3#device_v3.app_s_key}],
                devaddrs = Devaddrs,
                dev_nonces = [V3#device_v3.join_nonce],
                fcnt = V3#device_v3.fcnt,
                fcntdown = V3#device_v3.fcntdown,
                offset = V3#device_v3.offset,
                channel_correction = V3#device_v3.channel_correction,
                queue = V3#device_v3.queue,
                region = undefined,
                last_known_datarate = undefined,
                ecc_compact = V3#device_v3.keys,
                location = V3#device_v3.location,
                metadata = V3#device_v3.metadata,
                is_active = true
            };
        #device_v2{} = V2 ->
            #device_v7{
                id = V2#device_v2.id,
                name = V2#device_v2.name,
                dev_eui = V2#device_v2.dev_eui,
                app_eui = V2#device_v2.app_eui,
                keys = [{V2#device_v2.nwk_s_key, V2#device_v2.app_s_key}],
                devaddrs = [],
                dev_nonces = [V2#device_v2.join_nonce],
                fcnt = V2#device_v2.fcnt,
                fcntdown = V2#device_v2.fcntdown,
                offset = V2#device_v2.offset,
                channel_correction = V2#device_v2.channel_correction,
                queue = V2#device_v2.queue,
                region = undefined,
                last_known_datarate = undefined,
                ecc_compact = V2#device_v2.keys,
                location = undefined,
                metadata = V2#device_v2.metadata,
                is_active = true
            };
        #device_v1{} = V1 ->
            Keys =
                case V1#device_v1.key of
                    undefined -> libp2p_crypto:generate_keys(ecc_compact);
                    Key -> Key
                end,
            #device_v7{
                id = V1#device_v1.id,
                name = V1#device_v1.name,
                dev_eui = V1#device_v1.dev_eui,
                app_eui = V1#device_v1.app_eui,
                keys = [{V1#device_v1.nwk_s_key, V1#device_v1.app_s_key}],
                devaddrs = [],
                dev_nonces = [V1#device_v1.join_nonce],
                fcnt = V1#device_v1.fcnt,
                fcntdown = V1#device_v1.fcntdown,
                offset = V1#device_v1.offset,
                channel_correction = V1#device_v1.channel_correction,
                queue = V1#device_v1.queue,
                region = undefined,
                last_known_datarate = undefined,
                ecc_compact = Keys,
                metadata = #{},
                is_active = true
            };
        #device{} = V0 ->
            #device_v7{
                id = V0#device.id,
                name = V0#device.name,
                dev_eui = V0#device.dev_eui,
                app_eui = V0#device.app_eui,
                keys = [{V0#device.nwk_s_key, V0#device.app_s_key}],
                devaddrs = [],
                dev_nonces = [V0#device.join_nonce],
                fcnt = V0#device.fcnt,
                fcntdown = V0#device.fcntdown,
                offset = V0#device.offset,
                channel_correction = V0#device.channel_correction,
                queue = V0#device.queue,
                region = undefined,
                last_known_datarate = undefined,
                ecc_compact = libp2p_crypto:generate_keys(ecc_compact),
                metadata = #{},
                is_active = true
            }
    end.

-spec can_queue_payload(binary(), downlink_region() | undefined, device()) ->
    {error, any()}
    | {
        CanQueue :: boolean(),
        PayloadSize :: non_neg_integer(),
        MaxSize :: non_neg_integer(),
        Datarate :: integer()
    }.
can_queue_payload(_Payload, undefined, #device_v7{region = undefined}) ->
    {error, device_region_unknown};
can_queue_payload(Payload, DownlinkRegion, Device) ->
    Queue = ?MODULE:queue(Device),
    Limit = get_queue_size_limit(),
    case erlang:length(Queue) >= Limit of
        true ->
            {error, queue_size_limit};
        false ->
            Region = router_utils:either(DownlinkRegion, ?MODULE:region(Device)),
            UpDRIndex = ?MODULE:last_known_datarate(Device),
            Plan = lora_plan:region_to_plan(Region),
            DownDRIndex = lora_plan:up_to_down_datarate(Plan, UpDRIndex, 0),
            MaxSize = lora_plan:max_downlink_payload_size(Plan, DownDRIndex),
            Size = erlang:byte_size(Payload),
            {Size =< MaxSize, Size, MaxSize, DownDRIndex}
    end.

%% ------------------------------------------------------------------
%% RocksDB Device Functions
%% ------------------------------------------------------------------

-spec get(rocksdb:db_handle(), rocksdb:cf_handle()) -> [device()].
get(DB, CF) ->
    ?MODULE:get(DB, CF, fun(_) -> true end).

-spec get(rocksdb:db_handle(), rocksdb:cf_handle(), function()) -> [device()].
get(DB, CF, FilterFun) when is_function(FilterFun) ->
    get_fold(DB, CF, FilterFun).

-spec get_by_id(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) ->
    {ok, device()} | {error, any()}.
get_by_id(DB, CF, DeviceID) when is_binary(DeviceID) ->
    case rocksdb:get(DB, CF, DeviceID, []) of
        {ok, BinDevice} -> {ok, ?MODULE:deserialize(BinDevice)};
        not_found -> {error, not_found};
        Error -> Error
    end.

-spec save(rocksdb:db_handle(), rocksdb:cf_handle(), device()) -> {ok, device()} | {error, any()}.
save(DB, CF, Device) ->
    DeviceID = ?MODULE:id(Device),
    case rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(Device), []) of
        {error, _} = Error -> Error;
        ok -> {ok, Device}
    end.

-spec delete(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> ok | {error, any()}.
delete(DB, CF, DeviceID) ->
    rocksdb:delete(DB, CF, <<DeviceID/binary>>, []).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec get_queue_size_limit() -> pos_integer().
get_queue_size_limit() ->
    case application:get_env(router, device_queue_size_limit, ?QUEUE_SIZE_LIMIT) of
        [] -> ?QUEUE_SIZE_LIMIT;
        Str when is_list(Str) -> erlang:list_to_integer(Str);
        Limit -> Limit
    end.

-spec get_fold(rocksdb:db_handle(), rocksdb:cf_handle(), function()) -> [device()].
get_fold(DB, CF, FilterFun) ->
    {ok, Itr} = rocksdb:iterator(DB, CF, []),
    First = rocksdb:iterator_move(Itr, first),
    Acc = get_fold(DB, CF, Itr, First, FilterFun, []),
    rocksdb:iterator_close(Itr),
    Acc.

-spec get_fold(
    DB :: rocksdb:db_handle(),
    CF :: rocksdb:cf_handle(),
    Iterator :: rocksdb:itr_handle(),
    RocksDBEntry :: any(),
    FilterFun :: function(),
    Accumulator :: list()
) -> [device()].
get_fold(DB, CF, Itr, {ok, _K, Bin}, FilterFun, Acc) ->
    Next = rocksdb:iterator_move(Itr, next),
    Device = ?MODULE:deserialize(Bin),
    case FilterFun(Device) of
        true ->
            get_fold(DB, CF, Itr, Next, FilterFun, [Device | Acc]);
        false ->
            get_fold(DB, CF, Itr, Next, FilterFun, Acc)
    end;
get_fold(DB, CF, Itr, {ok, _}, FilterFun, Acc) ->
    Next = rocksdb:iterator_move(Itr, next),
    get_fold(DB, CF, Itr, Next, FilterFun, Acc);
get_fold(_DB, _CF, _Itr, {error, _}, _FilterFun, Acc) ->
    Acc.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

name_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, name(Device)),
    ?assertEqual(<<"name">>, name(name(<<"name">>, Device))).

app_eui_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, app_eui(Device)),
    ?assertEqual(<<"app_eui">>, app_eui(app_eui(<<"app_eui">>, Device))).

dev_eui_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, dev_eui(Device)),
    ?assertEqual(<<"dev_eui">>, dev_eui(dev_eui(<<"dev_eui">>, Device))).

keys_test() ->
    Device = new(<<"id">>),
    ?assertEqual([], keys(Device)),
    ?assertEqual(
        [{<<"nwk_s_key">>, <<"app_s_key">>}],
        keys(keys([{<<"nwk_s_key">>, <<"app_s_key">>}], Device))
    ).

nwk_s_key_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, nwk_s_key(Device)),
    ?assertEqual(
        <<"nwk_s_key">>,
        nwk_s_key(keys([{<<"nwk_s_key">>, <<"app_s_key">>}], Device))
    ).

app_s_key_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, app_s_key(Device)),
    ?assertEqual(
        <<"app_s_key">>,
        app_s_key(keys([{<<"nwk_s_key">>, <<"app_s_key">>}], Device))
    ).

devaddrs_test() ->
    Device = new(<<"id">>),
    ?assertEqual([], devaddrs(Device)),
    ?assertEqual([<<"devaddrs">>], devaddrs(devaddrs([<<"devaddrs">>], Device))).

dev_nonces_test() ->
    Device = new(<<"id">>),
    ?assertEqual([], dev_nonces(Device)),
    ?assertEqual([<<"1">>], dev_nonces(dev_nonces([<<"1">>], Device))).

fcnt_test() ->
    Device = new(<<"id">>),
    ?assertEqual(0, fcnt(Device)),
    ?assertEqual(1, fcnt(fcnt(1, Device))).

fcntdown_test() ->
    Device = new(<<"id">>),
    ?assertEqual(0, fcntdown(Device)),
    ?assertEqual(1, fcntdown(fcntdown(1, Device))).

offset_test() ->
    Device = new(<<"id">>),
    ?assertEqual(0, offset(Device)),
    ?assertEqual(1, offset(offset(1, Device))).

channel_correction_test() ->
    Device = new(<<"id">>),
    ?assertEqual(false, channel_correction(Device)),
    ?assertEqual(true, channel_correction(channel_correction(true, Device))).

queue_test() ->
    Device = new(<<"id">>),
    ?assertEqual([], queue(Device)),
    ?assertEqual([a], queue(queue([a], Device))).

region_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, region(Device)),
    ?assertEqual('US915', region(region('US915', Device))).

last_known_datarate_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, last_known_datarate(Device)),
    ?assertEqual(7, last_known_datarate(last_known_datarate(7, Device))).

location_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, location(Device)),
    ?assertEqual(<<"location">>, location(location(<<"location">>, Device))).

ecc_compact_test() ->
    Device = new(<<"id">>),
    ?assertMatch(undefined, ecc_compact(Device)),
    ?assertEqual({ecc_compact, any}, ecc_compact(ecc_compact({ecc_compact, any}, Device))).

update_test() ->
    Device = new(<<"id">>),
    Updates = [
        {name, <<"name">>},
        {app_eui, <<"app_eui">>},
        {dev_eui, <<"dev_eui">>},
        {keys, [{<<"nwk_s_key">>, <<"app_s_key">>}]},
        {devaddrs, [<<"devaddr">>]},
        {dev_nonces, [<<"1">>]},
        {fcnt, 1},
        {fcntdown, 1},
        {offset, 1},
        {channel_correction, true},
        {queue, [a]},
        {region, 'US915'},
        {last_known_datarate, 7},
        {ecc_compact, #{}},
        {location, <<"location">>},
        {metadata, #{a => b}},
        {is_active, false}
    ],
    UpdatedDevice = #device_v7{
        id = <<"id">>,
        name = <<"name">>,
        app_eui = <<"app_eui">>,
        dev_eui = <<"dev_eui">>,
        keys = [{<<"nwk_s_key">>, <<"app_s_key">>}],
        devaddrs = [<<"devaddr">>],
        dev_nonces = [<<"1">>],
        fcnt = 1,
        fcntdown = 1,
        offset = 1,
        channel_correction = true,
        queue = [a],
        region = 'US915',
        last_known_datarate = 7,
        ecc_compact = #{},
        location = <<"location">>,
        metadata = #{a => b},
        is_active = false
    },
    ?assertEqual(UpdatedDevice, update(Updates, Device)).

serialize_deserialize_test() ->
    Device = new(<<"id">>),
    ?assertEqual(Device, deserialize(serialize(Device))).

get_save_delete_test() ->
    Dir = test_utils:tmp_dir("get_save_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    {ok, DB, [_, CF]} = router_db:get(),
    DeviceID = <<"id">>,
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    Device = ecc_compact(Keys, new(DeviceID)),
    ?assertEqual({error, not_found}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([], get(DB, CF)),
    ?assertEqual({ok, Device}, save(DB, CF, Device)),
    ?assertEqual({ok, Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([Device], get(DB, CF)),
    ?assertEqual({error, not_found}, get_by_id(DB, CF, <<"unknown">>)),
    ?assertEqual(ok, delete(DB, CF, DeviceID)),
    ?assertEqual({error, not_found}, get_by_id(DB, CF, DeviceID)),
    gen_server:stop(Pid).

upgrade_test() ->
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    meck:new(libp2p_crypto, [passthrough]),
    meck:expect(libp2p_crypto, generate_keys, fun(ecc_compact) -> Keys end),
    Dir = test_utils:tmp_dir("upgrade_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    {ok, DB, [_, CF]} = router_db:get(),

    DeviceID = <<"id">>,
    V7Device = #device_v7{
        id = DeviceID,
        keys = [{undefined, undefined}],
        devaddrs = [],
        ecc_compact = Keys,
        dev_nonces = [<<>>],
        region = undefined,
        last_known_datarate = undefined
    },

    V0Device = #device{id = DeviceID},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V0Device), []),
    ?assertEqual({ok, V7Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V7Device], get(DB, CF)),

    V1Device = #device_v1{id = DeviceID},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V1Device), []),
    ?assertEqual({ok, V7Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V7Device], get(DB, CF)),

    V2Device = #device_v2{id = DeviceID, keys = Keys},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V2Device), []),
    ?assertEqual({ok, V7Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V7Device], get(DB, CF)),

    V3Device = #device_v3{id = DeviceID, keys = Keys},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V3Device), []),
    ?assertEqual({ok, V7Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V7Device], get(DB, CF)),

    V4Device = #device_v4{id = DeviceID, keys = Keys},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V4Device), []),
    ?assertEqual({ok, V7Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V7Device], get(DB, CF)),

    V5Device = #device_v5{
        id = DeviceID,
        keys = V7Device#device_v7.keys,
        ecc_compact = Keys,
        dev_nonces = [<<>>]
    },
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V5Device), []),
    ?assertEqual({ok, V7Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V7Device], get(DB, CF)),

    V6Device = #device_v6{
        id = DeviceID,
        keys = V7Device#device_v7.keys,
        ecc_compact = Keys,
        dev_nonces = [<<>>]
    },
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V6Device), []),
    ?assertEqual({ok, V7Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V7Device], get(DB, CF)),

    gen_server:stop(Pid),
    ?assert(meck:validate(libp2p_crypto)),
    meck:unload(libp2p_crypto).

-endif.
