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
        set,
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
        [{_, Ref}] -> ets:tab2list(Ref)
    end.

all_devaddrs_tables() ->
    ets:tab2list(?DEVADDR_ETS).

-spec save(router_device:device()) -> {ok, router_device:device()}.
save(Device) ->
    DeviceID = router_device:id(Device),
    true = ets:insert(?ETS, {DeviceID, Device}),
    _ = erlang:spawn_monitor(fun() ->
        AddrsEtsMap = maps:from_list(all_devaddrs_tables()),
        CurrentDevaddrs = router_device:devaddrs(Device),

        %% Build a list of all DevAddrs we can know about.
        AllAddrs = lists:usort(maps:keys(AddrsEtsMap) ++ CurrentDevaddrs),

        lists:foreach(
            fun(Addr) ->
                EtsRef =
                    case maps:get(Addr, AddrsEtsMap, undefined) of
                        undefined -> make_devaddr_table(Addr);
                        Ref -> Ref
                    end,
                case lists:member(Addr, CurrentDevaddrs) of
                    true -> ets:insert(EtsRef, Device);
                    false -> ets:delete(EtsRef, DeviceID)
                end
            end,
            AllAddrs
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

-spec make_devaddr_table(binary()) -> ets:tab().
make_devaddr_table(DevAddr) ->
    Ref = ets:new(devaddr_table, [
        public,
        set,
        %% items are router_device:device()
        %% keypos is the id field of the record.
        {keypos, 2},
        {heir, whereis(router_sup), DevAddr}
    ]),
    true = ets:insert(?DEVADDR_ETS, {DevAddr, Ref}),
    Ref.

-spec init_from_db() -> ok.
init_from_db() ->
    {ok, DB, [_DefaultCF, DevicesCF]} = router_db:get(),
    Devices = router_device:get(DB, DevicesCF),
    %% TODO: improve this maybe?
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
