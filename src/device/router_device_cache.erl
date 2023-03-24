%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Device Cache ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_device_cache).

-include_lib("stdlib/include/ms_transform.hrl").

-include("router_device.hrl").

-define(ETS, router_device_cache_ets).
-define(DEVADDR_ETS, router_device_cache_devaddr_ets).

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([
    init/0,
    get/0, get/1,
    get_by_devaddr/1,
    save/1,
    delete/1,
    size/0
]).

%% ------------------------------------------------------------------
%% API Functions
%% ------------------------------------------------------------------

-spec init() -> ok.
init() ->
    _ = ets:new(?ETS, [
        public,
        named_table,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    _ = ets:new(?DEVADDR_ETS, [
        public,
        named_table,
        bag,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ok = init_from_db(),
    ok.

-spec get() -> [router_device:device()].
get() ->
    [Device || {_ID, Device} <- ets:tab2list(?ETS)].

-spec get(binary()) -> {ok, router_device:device()} | {error, not_found}.
get(DeviceID) ->
    case ets:lookup(?ETS, DeviceID) of
        [] -> {error, not_found};
        [{DeviceID, Device}] -> {ok, Device}
    end.

-spec get_by_devaddr(binary()) -> [router_device:device()].
get_by_devaddr(DevAddr) ->
    case ets:lookup(?DEVADDR_ETS, DevAddr) of
        [] -> [];
        List -> [Device || {_DevAddr, Device} <- List]
    end.

-spec save(router_device:device()) -> {ok, router_device:device()}.
save(Device) ->
    DeviceID = router_device:id(Device),
    true = ets:insert(?ETS, {DeviceID, Device}),
    _ = erlang:spawn(fun() ->
        % MS = ets:fun2ms(fun({_, D}=O) when D#device_v7.id == DeviceID -> O end),
        MS = [{{'_', '$1'}, [{'==', {element, 2, '$1'}, {const, DeviceID}}], ['$_']}],
        CurrentDevaddrs = router_device:devaddrs(Device),
        SelectResult = ets:select(?DEVADDR_ETS, MS),
        %% We remove devaddrs that are not in use by the device and update existing ones
        lists:foreach(
            fun({DevAddr, _} = Obj) ->
                true = ets:delete_object(?DEVADDR_ETS, Obj),
                case lists:member(DevAddr, CurrentDevaddrs) of
                    true ->
                        true = ets:insert(?DEVADDR_ETS, {DevAddr, Device});
                    false ->
                        noop
                end
            end,
            SelectResult
        ),
        SelectDevaddrs = [DevAddr || {DevAddr, _} <- SelectResult],
        %% We add devaddrs that are in use by the device and missing from ETS
        lists:foreach(
            fun(DevAddr) ->
                case lists:member(DevAddr, SelectDevaddrs) of
                    true ->
                        noop;
                    false ->
                        true = ets:insert(?DEVADDR_ETS, {DevAddr, Device})
                end
            end,
            CurrentDevaddrs
        )
    end),
    {ok, Device}.

-spec delete(binary()) -> ok.
delete(DeviceID) ->
    true = ets:delete(?ETS, DeviceID),
    ok.

-spec size() -> non_neg_integer().
size() ->
    proplists:get_value(size, ets:info(router_device_cache_ets), 0).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_from_db() -> ok.
init_from_db() ->
    {ok, DB, [_DefaultCF, DevicesCF]} = router_db:get(),
    Devices = router_device:get(DB, DevicesCF),
    lists:foreach(fun(Device) -> ?MODULE:save(Device) end, Devices).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

init_from_db_test() ->
    Dir = test_utils:tmp_dir("init_from_db_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    ok = init(),
    ID = router_utils:uuid_v4(),
    Device0 = router_device:new(ID),
    DevAddr0 = <<"devaddr0">>,
    Updates = [
        {name, <<"name">>},
        {app_eui, <<"app_eui">>},
        {dev_eui, <<"dev_eui">>},
        {keys, [{<<"nwk_s_key">>, <<"app_s_key">>}]},
        {devaddrs, [DevAddr0]},
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
    Device1 = router_device:update(Updates, Device0),
    {ok, DB, [_, CF]} = router_db:get(),
    ?assertEqual({ok, Device1}, router_device:save(DB, CF, Device1)),
    ?assertEqual(ok, init_from_db()),
    ?assertEqual({ok, Device1}, ?MODULE:get(ID)),
    timer:sleep(10),
    ?assertEqual([Device1], ?MODULE:get_by_devaddr(DevAddr0)),

    DevAddr1 = <<"devaddr1">>,
    DevAddr2 = <<"devaddr2">>,
    Device2 = router_device:devaddrs([DevAddr1, DevAddr2], Device1),
    ?assertEqual({ok, Device2}, ?MODULE:save(Device2)),
    timer:sleep(10),
    ?assertEqual([], ?MODULE:get_by_devaddr(DevAddr0)),
    ?assertEqual([Device2], ?MODULE:get_by_devaddr(DevAddr1)),
    ?assertEqual([Device2], ?MODULE:get_by_devaddr(DevAddr2)),

    gen_server:stop(Pid),
    ets:delete(?ETS),
    ets:delete(?DEVADDR_ETS),
    ok.

get_save_delete_test() ->
    Dir = test_utils:tmp_dir("get_save_delete_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    ok = init(),
    ID = router_utils:uuid_v4(),
    Device = router_device:new(ID),

    ?assertEqual({ok, Device}, ?MODULE:save(Device)),
    ?assertEqual({ok, Device}, ?MODULE:get(ID)),
    ?assertEqual([Device], ?MODULE:get()),
    ?assertEqual(ok, ?MODULE:delete(ID)),
    ?assertEqual({error, not_found}, ?MODULE:get(ID)),

    gen_server:stop(Pid),
    ets:delete(?ETS),
    ets:delete(?DEVADDR_ETS),
    ok.

-endif.
