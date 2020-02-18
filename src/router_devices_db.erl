%%%-------------------------------------------------------------------
%% @doc
%% == Router Devices DB ==
%% @end
%%%-------------------------------------------------------------------
-module(router_devices_db).

-include("device.hrl").

-export([
         insert/3,
         update/4,
         get/3,
         get_all/2
        ]).

-type device() :: #device{}.

-spec insert(rocksdb:db_handle(), rocksdb:cf_handle(), device()) -> ok | {error, any()}.
insert(DB, CF, #device{app_eui=AppEUI}=Device) ->
    rocksdb:put(DB, CF, AppEUI, erlang:term_to_binary(Device), [{sync, true}]).

-spec update(rocksdb:db_handle(), rocksdb:cf_handle(), binary(), [{atom(), any()}]) -> ok | {error, any()}.
update(DB, CF, AppEUI, Updates) ->
    case get(DB, CF, AppEUI) of
        {error, _}=Error ->
            Error;
        {ok, Device} ->
            insert(DB, CF, update(Device, Updates))
    end.

-spec get(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> {ok, device()} | {error, any()}.
get(DB, CF, AppEUI) ->
    case rocksdb:get(DB, CF, AppEUI, [{sync, true}]) of
        {ok, BinDevice} -> {ok, erlang:binary_to_term(BinDevice)};
        not_found -> {error, not_found};
        Error -> Error
    end.

-spec get_all(rocksdb:db_handle(), rocksdb:cf_handle()) -> [device()].
get_all(DB, CF) ->
    rocksdb:fold(
      DB,
      CF,
      fun({_Key, BinDevice}, Acc) ->
              [erlang:binary_to_term(BinDevice)|Acc]
      end,
      [],
      [{sync, true}]
     ).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec update(device(), [{atom(), any()}]) -> device().
update(Device, []) ->
    Device;
update(Device, [{mac, Value}|Updates]) ->
    update(Device#device{mac=Value}, Updates);
update(Device, [{app_eui, Value}|Updates]) ->
    update(Device#device{app_eui=Value}, Updates);
update(Device, [{nwk_s_key, Value}|Updates]) ->
    update(Device#device{nwk_s_key=Value}, Updates);
update(Device, [{app_s_key, Value}|Updates]) ->
    update(Device#device{app_s_key=Value}, Updates);
update(Device, [{join_nonce, Value}|Updates]) ->
    update(Device#device{join_nonce=Value}, Updates);
update(Device, [{fcnt, Value}|Updates]) ->
    update(Device#device{fcnt=Value}, Updates);
update(Device, [{fcntdown, Value}|Updates]) ->
    update(Device#device{fcntdown=Value}, Updates);
update(Device, [{offset, Value}|Updates]) ->
    update(Device#device{offset=Value}, Updates);
update(Device, [{channel_correction, Value}|Updates]) ->
    update(Device#device{channel_correction=Value}, Updates);
update(Device, [{queue, Value}|Updates]) ->
    update(Device#device{queue=Value}, Updates).
