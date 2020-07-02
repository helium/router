-module(router_device).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("router_device.hrl").

-export([
         new/1,
         id/1,
         name/1, name/2,
         app_eui/1, app_eui/2,
         dev_eui/1, dev_eui/2,
         nwk_s_key/1, nwk_s_key/2,
         app_s_key/1, app_s_key/2,
         devaddr/1, devaddr/2,
         join_nonce/1, join_nonce/2,
         fcnt/1, fcnt/2,
         fcntdown/1, fcntdown/2,
         offset/1, offset/2,
         channel_correction/1, channel_correction/2,
         queue/1, queue/2,
         keys/1, keys/2,
         location/1, location/2,
         metadata/1, metadata/2,
         update/2,
         serialize/1, deserialize/1,
         get/2, get/3, get_by_id/3, save/3, delete/3
        ]).

-type device() :: #device_v3{}.

-export_type([device/0]).

-spec new(binary()) -> device().
new(ID) ->
    #device_v3{id=ID,
               keys=libp2p_crypto:generate_keys(ecc_compact)}.

-spec id(device()) -> binary() | undefined.
id(Device) ->
    Device#device_v3.id.

-spec name(device()) -> binary() | undefined.
name(Device) ->
    Device#device_v3.name.

-spec name(binary(), device()) -> device().
name(Name, Device) ->
    Device#device_v3{name=Name}.

-spec app_eui(device()) -> binary() | undefined.
app_eui(Device) ->
    Device#device_v3.app_eui.

-spec app_eui(binary(), device()) -> device().
app_eui(EUI, Device) ->
    Device#device_v3{app_eui=EUI}.

-spec dev_eui(device()) -> binary() | undefined.
dev_eui(Device) ->
    Device#device_v3.dev_eui.

-spec dev_eui(binary(), device()) -> device().
dev_eui(EUI, Device) ->
    Device#device_v3{dev_eui=EUI}.

-spec nwk_s_key(device()) -> binary() | undefined.
nwk_s_key(Device) ->
    Device#device_v3.nwk_s_key.

-spec nwk_s_key(binary(), device()) -> device().
nwk_s_key(Key, Device) ->
    Device#device_v3{nwk_s_key=Key}.

-spec app_s_key(device()) -> binary() | undefined.
app_s_key(Device) ->
    Device#device_v3.app_s_key.

-spec app_s_key(binary(), device()) -> device().
app_s_key(Key, Device) ->
    Device#device_v3{app_s_key=Key}.

-spec devaddr(device()) -> binary() | undefined.
devaddr(Device) ->
    Device#device_v3.devaddr.

-spec devaddr(binary(), device()) -> device().
devaddr(Devaddr, Device) ->
    Device#device_v3{devaddr=Devaddr}.

-spec join_nonce(device()) -> non_neg_integer().
join_nonce(Device) ->
    Device#device_v3.join_nonce.

-spec join_nonce(non_neg_integer(), device()) -> device().
join_nonce(Nonce, Device) ->
    Device#device_v3{join_nonce=Nonce}.

-spec fcnt(device()) -> non_neg_integer().
fcnt(Device) ->
    Device#device_v3.fcnt.

-spec fcnt(non_neg_integer(), device()) -> device().
fcnt(Fcnt, Device) ->
    Device#device_v3{fcnt=Fcnt}.

-spec fcntdown(device()) -> non_neg_integer().
fcntdown(Device) ->
    Device#device_v3.fcntdown.

-spec fcntdown(non_neg_integer(), device()) -> device().
fcntdown(Fcnt, Device) ->
    Device#device_v3{fcntdown=Fcnt}.

-spec offset(device()) -> non_neg_integer().
offset(Device) ->
    Device#device_v3.offset.

-spec offset(non_neg_integer(), device()) -> device().
offset(Offset, Device) ->
    Device#device_v3{offset=Offset}.

-spec channel_correction(device()) -> boolean().
channel_correction(Device) ->
    Device#device_v3.channel_correction.

-spec channel_correction(boolean(), device()) -> device().
channel_correction(Correct, Device) ->
    Device#device_v3{channel_correction=Correct}.

-spec queue(device()) -> [any()].
queue(Device) ->
    Device#device_v3.queue.

-spec queue([any()], device()) -> device().
queue(Q, Device) ->
    Device#device_v3{queue=Q}.

-spec keys(device()) -> map().
keys(Device) ->
    Device#device_v3.keys.

-spec keys(map(), device()) -> device().
keys(Keys, Device) ->
    Device#device_v3{keys=Keys}.

-spec location(device()) -> libp2p_crypto:pubkey_bin() | undefined.
location(Device) ->
    Device#device_v3.location.

-spec location(libp2p_crypto:pubkey_bin() | undefined, device()) -> device().
location(PubkeyBin, Device) ->
    Device#device_v3{location=PubkeyBin}.

-spec metadata(device()) -> map().
metadata(Device) ->
    Device#device_v3.metadata.

-spec metadata(map(), device()) -> device().
metadata(Meta, Device) ->
    Device#device_v3{metadata=Meta}.

-spec update([{atom(), any()}], device()) -> device().
update([], Device) ->
    Device;
update([{name, Value}|T], Device) ->
    update(T, ?MODULE:name(Value, Device));
update([{app_eui, Value}|T], Device) ->
    update(T, ?MODULE:app_eui(Value, Device));
update([{dev_eui, Value}|T], Device) ->
    update(T, ?MODULE:dev_eui(Value, Device));
update([{nwk_s_key, Value}|T], Device) ->
    update(T, ?MODULE:nwk_s_key(Value, Device));
update([{app_s_key, Value}|T], Device) ->
    update(T, ?MODULE:app_s_key(Value, Device));
update([{devaddr, Value}|T], Device) ->
    update(T, ?MODULE:devaddr(Value, Device));
update([{join_nonce, Value}|T], Device) ->
    update(T, ?MODULE:join_nonce(Value, Device));
update([{fcnt, Value}|T], Device) ->
    update(T, ?MODULE:fcnt(Value, Device));
update([{fcntdown, Value}|T], Device) ->
    update(T, ?MODULE:fcntdown(Value, Device));
update([{offset, Value}|T], Device) ->
    update(T, ?MODULE:offset(Value, Device));
update([{channel_correction, Value}|T], Device) ->
    update(T, ?MODULE:channel_correction(Value, Device));
update([{queue, Value}|T], Device) ->
    update(T, ?MODULE:queue(Value, Device));
update([{keys, Value}|T], Device) ->
    update(T, ?MODULE:keys(Value, Device));
update([{location, Value}|T], Device) ->
    update(T, ?MODULE:location(Value, Device));
update([{metadata, Value}|T], Device) ->
    update(T, ?MODULE:metadata(Value, Device)).

-spec serialize(device()) -> binary().
serialize(Device) ->
    erlang:term_to_binary(Device).

-spec deserialize(binary()) -> device().
deserialize(Binary) ->
    case erlang:binary_to_term(Binary) of
        #device_v3{}=V3 ->
            V3;
        #device_v2{}=V2 ->
            #device_v3{id=V2#device_v2.id,
                       name=V2#device_v2.name,
                       dev_eui=V2#device_v2.dev_eui,
                       app_eui=V2#device_v2.app_eui,
                       nwk_s_key=V2#device_v2.nwk_s_key,
                       app_s_key=V2#device_v2.app_s_key,
                       devaddr=router_device_devaddr:default_devaddr(),
                       join_nonce=V2#device_v2.join_nonce,
                       fcnt=V2#device_v2.fcnt,
                       fcntdown=V2#device_v2.fcntdown,
                       offset=V2#device_v2.offset,
                       channel_correction=V2#device_v2.channel_correction,
                       queue=V2#device_v2.queue,
                       keys=V2#device_v2.keys,
                       location=undefined,
                       metadata=V2#device_v2.metadata};
        #device_v1{}=V1 ->
            Keys = case V1#device_v1.key of
                       undefined -> libp2p_crypto:generate_keys(ecc_compact);
                       Key -> Key
                   end,
            #device_v3{id=V1#device_v1.id,
                       name=V1#device_v1.name,
                       dev_eui=V1#device_v1.dev_eui,
                       app_eui=V1#device_v1.app_eui,
                       nwk_s_key=V1#device_v1.nwk_s_key,
                       app_s_key=V1#device_v1.app_s_key,
                       devaddr=undefined,
                       join_nonce=V1#device_v1.join_nonce,
                       fcnt=V1#device_v1.fcnt,
                       fcntdown=V1#device_v1.fcntdown,
                       offset=V1#device_v1.offset,
                       channel_correction=V1#device_v1.channel_correction,
                       queue=V1#device_v1.queue,
                       keys=Keys,
                       metadata=#{}};
        #device{}=V0 ->
            #device_v3{id=V0#device.id,
                       name=V0#device.name,
                       dev_eui=V0#device.dev_eui,
                       app_eui=V0#device.app_eui,
                       nwk_s_key=V0#device.nwk_s_key,
                       app_s_key=V0#device.app_s_key,
                       devaddr=undefined,
                       join_nonce=V0#device.join_nonce,
                       fcnt=V0#device.fcnt,
                       fcntdown=V0#device.fcntdown,
                       offset=V0#device.offset,
                       channel_correction=V0#device.channel_correction,
                       queue=V0#device.queue,
                       keys=libp2p_crypto:generate_keys(ecc_compact),
                       metadata=#{}}
    end.

-spec get(rocksdb:db_handle(), rocksdb:cf_handle()) -> [device()].
get(DB, CF) ->
    ?MODULE:get(DB, CF, fun(_) -> true end).

-spec get(rocksdb:db_handle(), rocksdb:cf_handle(),function()) -> [device()].
get(DB, CF, FilterFun) when is_function(FilterFun) ->
    get_fold(DB, CF, FilterFun).

-spec get_by_id(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> {ok, device()} | {error, any()}.
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
        {error, _}=Error -> Error;
        ok -> {ok, Device}
    end.

-spec delete(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> ok | {error, any()}.
delete(DB, CF, DeviceID) ->
    rocksdb:delete(DB, CF, <<DeviceID/binary>>, []).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec get_fold(rocksdb:db_handle(), rocksdb:cf_handle(), function()) -> [device()].
get_fold(DB, CF, FilterFun) ->
    {ok, Itr} = rocksdb:iterator(DB, CF, []),
    First = rocksdb:iterator_move(Itr, first),
    Acc = get_fold(DB, CF, Itr, First, FilterFun, []),
    rocksdb:iterator_close(Itr),
    Acc.

-spec get_fold(rocksdb:db_handle(), rocksdb:cf_handle(), rocksdb:itr_handle(), any(), function(), list()) -> [device()].
get_fold(DB, CF, Itr, {ok, _K, Bin}, FilterFun, Acc) ->
    Next = rocksdb:iterator_move(Itr, next),
    Device = ?MODULE:deserialize(Bin),
    case FilterFun(Device) of
        true ->
            get_fold(DB, CF, Itr, Next, FilterFun, [Device|Acc]);
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

new_test() ->
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    meck:new(libp2p_crypto, [passthrough]),
    meck:expect(libp2p_crypto, generate_keys, fun(ecc_compact) -> Keys end),

    ?assertEqual(#device_v3{id= <<"id">>, keys=Keys}, new(<<"id">>)),

    ?assert(meck:validate(libp2p_crypto)),
    meck:unload(libp2p_crypto).

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

nwk_s_key_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, nwk_s_key(Device)),
    ?assertEqual(<<"nwk_s_key">>, nwk_s_key(nwk_s_key(<<"nwk_s_key">>, Device))).

app_s_key_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, app_s_key(Device)),
    ?assertEqual(<<"app_s_key">>, app_s_key(app_s_key(<<"app_s_key">>, Device))).

devaddr_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, devaddr(Device)),
    ?assertEqual(<<"devaddr">>, devaddr(devaddr(<<"devaddr">>, Device))).

join_nonce_test() ->
    Device = new(<<"id">>),
    ?assertEqual(0, join_nonce(Device)),
    ?assertEqual(1, join_nonce(join_nonce(1, Device))).

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

location_test() ->
    Device = new(<<"id">>),
    ?assertEqual(undefined, location(Device)),
    ?assertEqual(<<"location">>, location(location(<<"location">>, Device))).

keys_test() ->
    Device = new(<<"id">>),
    ?assertMatch(#{secret := {ecc_compact, _}, public := {ecc_compact, _}}, keys(Device)),
    ?assertEqual({keys, any}, keys(keys({keys, any}, Device))).

update_test() ->
    Device = new(<<"id">>),
    Updates = [{name, <<"name">>},
               {app_eui, <<"app_eui">>},
               {dev_eui, <<"dev_eui">>},
               {nwk_s_key, <<"nwk_s_key">>},
               {app_s_key, <<"app_s_key">>},
               {devaddr, <<"devaddr">>},
               {join_nonce, 1},
               {fcnt, 1},
               {fcntdown, 1},
               {offset, 1},
               {channel_correction, true},
               {queue, [a]},
               {keys, #{}},
               {location, <<"location">>},
               {metadata, #{a => b}}],
    UpdatedDevice = #device_v3{id = <<"id">>,
                               name = <<"name">>,
                               app_eui = <<"app_eui">>,
                               dev_eui = <<"dev_eui">>,
                               nwk_s_key = <<"nwk_s_key">>,
                               app_s_key = <<"app_s_key">>,
                               devaddr = <<"devaddr">>,
                               join_nonce = 1,
                               fcnt = 1,
                               fcntdown = 1,
                               offset = 1,
                               channel_correction = true,
                               queue = [a],
                               keys = #{},
                               location = <<"location">>,
                               metadata = #{a => b}},
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
    Device = keys(Keys, new(DeviceID)),
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
    V3Device = #device_v3{id=DeviceID, keys=Keys},

    V0Device = #device{id=DeviceID},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V0Device), []),
    ?assertEqual({ok, V3Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V3Device], get(DB, CF)),

    V1Device = #device_v1{id=DeviceID, key=Keys},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V1Device), []),
    ?assertEqual({ok, V3Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V3Device], get(DB, CF)),

    V2Device = #device_v1{id=DeviceID, key=Keys},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V2Device), []),
    ?assertEqual({ok, V3Device}, get_by_id(DB, CF, DeviceID)),
    ?assertEqual([V3Device], get(DB, CF)),

    gen_server:stop(Pid),
    ?assert(meck:validate(libp2p_crypto)),
    meck:unload(libp2p_crypto).

-endif.
