-module(router_device).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("router_device.hrl").

-export([
         new/1, new/4,
         id/1,
         name/1, name/2,
         app_eui/1, app_eui/2,
         dev_eui/1, dev_eui/2,
         nwk_s_key/1, nwk_s_key/2,
         app_s_key/1, app_s_key/2,
         join_nonce/1, join_nonce/2,
         fcnt/1, fcnt/2,
         fcntdown/1, fcntdown/2,
         offset/1, offset/2,
         channel_correction/1, channel_correction/2,
         queue/1, queue/2,
         key/1, key/2,
         update/2,
         serialize/1, deserialize/1,
         get/2, get/3, save/3
        ]).

-type device() :: #device_v1{}.

-export_type([device/0]).

-spec new(binary()) -> device().
new(ID) ->
    #device_v1{id=ID,
               key=libp2p_crypto:generate_keys(ecc_compact)}.

-spec new(binary(), binary(), binary(), binary()) -> device().
new(ID, Name, DevEui, AppEui) ->
    #device_v1{id=ID,
               name=Name,
               dev_eui=DevEui,
               app_eui=AppEui,
               key=libp2p_crypto:generate_keys(ecc_compact)}.

-spec id(device()) -> binary() | undefined.
id(Device) ->
    Device#device_v1.id.

-spec name(device()) -> binary() | undefined.
name(Device) ->
    Device#device_v1.name.

-spec name(binary(), device()) -> device().
name(Name, Device) ->
    Device#device_v1{name=Name}.

-spec app_eui(device()) -> binary() | undefined.
app_eui(Device) ->
    Device#device_v1.app_eui.

-spec app_eui(binary(), device()) -> device().
app_eui(EUI, Device) ->
    Device#device_v1{app_eui=EUI}.

-spec dev_eui(device()) -> binary() | undefined.
dev_eui(Device) ->
    Device#device_v1.dev_eui.

-spec dev_eui(binary(), device()) -> device().
dev_eui(EUI, Device) ->
    Device#device_v1{dev_eui=EUI}.

-spec nwk_s_key(device()) -> binary() | undefined.
nwk_s_key(Device) ->
    Device#device_v1.nwk_s_key.

-spec nwk_s_key(binary(), device()) -> device().
nwk_s_key(Key, Device) ->
    Device#device_v1{nwk_s_key=Key}.

-spec app_s_key(device()) -> binary() | undefined.
app_s_key(Device) ->
    Device#device_v1.app_s_key.

-spec app_s_key(binary(), device()) -> device().
app_s_key(Key, Device) ->
    Device#device_v1{app_s_key=Key}.

-spec join_nonce(device()) -> non_neg_integer().
join_nonce(Device) ->
    Device#device_v1.join_nonce.

-spec join_nonce(non_neg_integer(), device()) -> device().
join_nonce(Nonce, Device) ->
    Device#device_v1{join_nonce=Nonce}.

-spec fcnt(device()) -> non_neg_integer().
fcnt(Device) ->
    Device#device_v1.fcnt.

-spec fcnt(non_neg_integer(), device()) -> device().
fcnt(Fcnt, Device) ->
    Device#device_v1{fcnt=Fcnt}.

-spec fcntdown(device()) -> non_neg_integer().
fcntdown(Device) ->
    Device#device_v1.fcntdown.

-spec fcntdown(non_neg_integer(), device()) -> device().
fcntdown(Fcnt, Device) ->
    Device#device_v1{fcntdown=Fcnt}.

-spec offset(device()) -> non_neg_integer().
offset(Device) ->
    Device#device_v1.offset.

-spec offset(non_neg_integer(), device()) -> device().
offset(Offset, Device) ->
    Device#device_v1{offset=Offset}.

-spec channel_correction(device()) -> boolean().
channel_correction(Device) ->
    Device#device_v1.channel_correction.

-spec channel_correction(boolean(), device()) -> device().
channel_correction(Correct, Device) ->
    Device#device_v1{channel_correction=Correct}.

-spec queue(device()) -> [any()].
queue(Device) ->
    Device#device_v1.queue.

-spec queue([any()], device()) -> device().
queue(Q, Device) ->
    Device#device_v1{queue=Q}.

-spec key(device()) -> any().
key(Device) ->
    Device#device_v1.key.

-spec key(any(), device()) -> device().
key(Key, Device) ->
    Device#device_v1{key=Key}.

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
update([{key, Value}|T], Device) ->
    update(T, ?MODULE:key(Value, Device)).

-spec serialize(device()) -> binary().
serialize(Device) ->
    erlang:term_to_binary(Device).

-spec deserialize(binary()) -> device().
deserialize(Binary) ->
    case erlang:binary_to_term(Binary) of
        #device_v1{key=undefined}=Device ->
            ?MODULE:key(libp2p_crypto:generate_keys(ecc_compact), Device);
        #device_v1{}=Device ->
            Device;
        #device{}=Old ->
            #device_v1{id=Old#device.id,
                       name=Old#device.name,
                       dev_eui=Old#device.dev_eui,
                       app_eui=Old#device.app_eui,
                       nwk_s_key=Old#device.nwk_s_key,
                       app_s_key=Old#device.app_s_key,
                       join_nonce=Old#device.join_nonce,
                       fcnt=Old#device.fcnt,
                       fcntdown=Old#device.fcntdown,
                       offset=Old#device.offset,
                       channel_correction=Old#device.channel_correction,
                       queue=Old#device.queue,
                       key=libp2p_crypto:generate_keys(ecc_compact)}
    end.

-spec get(rocksdb:db_handle(), rocksdb:cf_handle()) -> [device()].
get(DB, CF) ->
    [?MODULE:deserialize(Bin) || Bin <- rocks_fold(DB, CF)].

-spec get(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> {ok, device()} | {error, any()}.
get(DB, CF, DeviceID) ->
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

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec rocks_fold(rocksdb:db_handle(), rocksdb:cf_handle()) -> [binary()].
rocks_fold(DB, CF) ->
    {ok, Itr} = rocksdb:iterator(DB, CF, []),
    First = rocksdb:iterator_move(Itr, first),
    Acc = rocks_fold(DB, CF, Itr, First, []),
    rocksdb:iterator_close(Itr),
    lists:reverse(Acc).

-spec rocks_fold(rocksdb:db_handle(), rocksdb:cf_handle(), rocksdb:itr_handle(), any(), list()) -> [binary()].
rocks_fold(DB, CF, Itr, {ok, _K, V}, Acc) ->
    Next = rocksdb:iterator_move(Itr, next),
    rocks_fold(DB, CF, Itr, Next, [V|Acc]);
rocks_fold(DB, CF, Itr, {ok, _}, Acc) ->
    Next = rocksdb:iterator_move(Itr, next),
    rocks_fold(DB, CF, Itr, Next, Acc);
rocks_fold(_DB, _CF, _Itr, {error, _}, Acc) ->
    Acc.


%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    meck:new(libp2p_crypto, [passthrough]),
    meck:expect(libp2p_crypto, generate_keys, fun(ecc_compact) -> #{} end),

    ?assertEqual(#device_v1{id= <<"id">>, key= #{}}, new(<<"id">>)),

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

key_test() ->
    Device = new(<<"id">>),
    ?assertMatch(#{secret := {ecc_compact, _}, public := {ecc_compact, _}}, key(Device)),
    ?assertEqual({key, any}, key(key({key, any}, Device))).

update_test() ->
    Device = new(<<"id">>),
    Updates = [{name, <<"name">>},
               {app_eui, <<"app_eui">>},
               {dev_eui, <<"dev_eui">>},
               {nwk_s_key, <<"nwk_s_key">>},
               {app_s_key, <<"app_s_key">>},
               {join_nonce, 1},
               {fcnt, 1},
               {fcntdown, 1},
               {offset, 1},
               {channel_correction, true},
               {queue, [a]},
               {key, #{}}],
    UpdatedDevice = #device_v1{id = <<"id">>,
                               name = <<"name">>,
                               app_eui = <<"app_eui">>,
                               dev_eui = <<"dev_eui">>,
                               nwk_s_key = <<"nwk_s_key">>,
                               app_s_key = <<"app_s_key">>,
                               join_nonce = 1,
                               fcnt = 1,
                               fcntdown = 1,
                               offset = 1,
                               channel_correction = true,
                               queue = [a],
                               key = #{}},
    ?assertEqual(UpdatedDevice, update(Updates, Device)).

serialize_deserialize_test() ->
    Device = new(<<"id">>),
    ?assertEqual(Device, deserialize(serialize(Device))).

get_save_test() ->
    Dir = test_utils:tmp_dir("get_save_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    {ok, DB, [_, CF]} = router_db:get(),
    DeviceID = <<"id">>,
    Key = libp2p_crypto:generate_keys(ecc_compact),
    Device = key(Key, new(DeviceID, <<"device_name">>, <<"dev_eui">>, <<"app_eui">>)),
    ?assertEqual({error, not_found}, get(DB, CF, DeviceID)),
    ?assertEqual([], get(DB, CF)),
    ?assertEqual({ok, Device}, save(DB, CF, Device)),
    ?assertEqual({ok, Device}, get(DB, CF, DeviceID)),
    ?assertEqual([Device], get(DB, CF)),
    ?assertEqual({error, not_found}, get(DB, CF, <<"unknown">>)),
    gen_server:stop(Pid).

upgrade_test() ->
    meck:new(libp2p_crypto, [passthrough]),
    meck:expect(libp2p_crypto, generate_keys, fun(ecc_compact) -> #{} end),

    Dir = test_utils:tmp_dir("upgrade_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    {ok, DB, [_, CF]} = router_db:get(),
    DeviceID = <<"id">>,
    V0Device = #device{id=DeviceID},
    V1Device = #device_v1{id=DeviceID, key=#{}},
    ok = rocksdb:put(DB, CF, <<DeviceID/binary>>, ?MODULE:serialize(V0Device), []),
    ?assertEqual({ok, V1Device}, get(DB, CF, DeviceID)),
    ?assertEqual([V1Device], get(DB, CF)),

    gen_server:stop(Pid),
    ?assert(meck:validate(libp2p_crypto)),
    meck:unload(libp2p_crypto).

-endif.
