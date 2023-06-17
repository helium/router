%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Device Cache ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_device_cache).

-include_lib("stdlib/include/ms_transform.hrl").

-include("router_device.hrl").

-define(ETS, router_device_cache_ets).
-define(DEVADDR_TABLES, router_device_cache_devaddr_tables).

-define(ETS_OPTS, [
    public,
    named_table,
    set,
    {write_concurrency, true},
    {read_concurrency, true},
    {keypos, #device_v7.id}
]).

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
    _ = ets:new(?ETS, ?ETS_OPTS),
    ok = persistent_term:put(?DEVADDR_TABLES, []),
    ok = init_from_db(),
    ok.

-spec get() -> [router_device:device()].
get() ->
    ets:tab2list(?ETS).

-spec get(binary()) -> {ok, router_device:device()} | {error, not_found}.
get(DeviceID) ->
    case ets:lookup(?ETS, DeviceID) of
        [] -> {error, not_found};
        [Device] -> {ok, Device}
    end.

-spec get_by_devaddr(binary()) -> [router_device:device()].
get_by_devaddr(DevAddr) ->
    ETSName = devaddr_to_ets(DevAddr),
    ets:tab2list(ETSName).

-spec save(router_device:device()) -> {ok, router_device:device()}.
save(Device) ->
    true = ets:insert(?ETS, Device),
    ok = insert_device_devaddr(Device),
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
    lists:foreach(
        fun(Device) ->
            true = ets:insert(?ETS, Device),
            insert_device_devaddr(Device)
        end,
        Devices
    ).

-spec insert_device_devaddr(Device :: router_device:device()) -> ok.
insert_device_devaddr(Device) ->
    CurrentDevaddrs = router_device:devaddrs(Device),
    DeviceID = router_device:id(Device),
    lists:foreach(
        fun(Table) ->
            case ets:whereis(Table) of
                undefined ->
                    ok;
                _TID ->
                    true = ets:delete(Table, DeviceID),
                    ok
            end
        end,
        persistent_term:get(?DEVADDR_TABLES, [])
    ),
    lists:foreach(
        fun(DevAddr) ->
            ETSName = devaddr_to_ets(DevAddr),
            case ets:whereis(ETSName) of
                undefined ->
                    _ = ets:new(ETSName, ?ETS_OPTS),
                    ok = update_devaddr_tables(ETSName),
                    true = ets:insert(ETSName, Device),
                    ok;
                _TID ->
                    true = ets:insert(ETSName, Device),
                    ok
            end
        end,
        CurrentDevaddrs
    ).

-spec devaddr_to_ets(DevAddr :: binary()) -> atom().
devaddr_to_ets(DevAddr) ->
    erlang:binary_to_atom(binary:encode_hex(lorawan_utils:reverse(DevAddr))).

-spec update_devaddr_tables(TableName :: atom()) -> ok.
update_devaddr_tables(TableName) ->
    Tables = persistent_term:get(?DEVADDR_TABLES, []),
    ok = persistent_term:put(?DEVADDR_TABLES, [TableName | Tables]).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

fulll_test() ->
    Dir = test_utils:tmp_dir("router_device_cache_fulll_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    {ok, DB, [_, CF]} = router_db:get(),

    DevAddr1 = <<255, 1, 0, 72>>,
    Device1 = fake_device(DevAddr1),
    Device1ID = router_device:id(Device1),
    {ok, _} = router_device:save(DB, CF, Device1),

    ok = ?MODULE:init(),

    ?assert(undefined =/= ets:whereis(devaddr_to_ets(DevAddr1))),
    ?assertEqual({ok, Device1}, router_device:get_by_id(DB, CF, Device1ID)),
    ?assertEqual([Device1], ?MODULE:get_by_devaddr(DevAddr1)),
    ?assertEqual([Device1], ?MODULE:get()),
    ?assertEqual({ok, Device1}, ?MODULE:get(Device1ID)),
    ?assertEqual(1, ?MODULE:size()),

    DevAddr2 = <<255, 2, 0, 72>>,
    DevAddr3 = <<255, 3, 0, 72>>,
    UpdatedDevice1 = router_device:update(
        [
            {devaddrs, [DevAddr2, DevAddr3]}
        ],
        Device1
    ),
    {ok, UpdatedDevice1} = ?MODULE:save(UpdatedDevice1),

    ?assert(undefined =/= ets:whereis(devaddr_to_ets(DevAddr2))),
    ?assert(undefined =/= ets:whereis(devaddr_to_ets(DevAddr3))),
    ?assertEqual([], ?MODULE:get_by_devaddr(DevAddr1)),
    ?assertEqual([UpdatedDevice1], ?MODULE:get_by_devaddr(DevAddr2)),
    ?assertEqual([UpdatedDevice1], ?MODULE:get_by_devaddr(DevAddr3)),
    ?assertEqual([UpdatedDevice1], ?MODULE:get()),
    ?assertEqual({ok, UpdatedDevice1}, ?MODULE:get(Device1ID)),
    ?assertEqual(1, ?MODULE:size()),
    ?assertEqual(
        [devaddr_to_ets(DevAddr3), devaddr_to_ets(DevAddr2), devaddr_to_ets(DevAddr1)],
        persistent_term:get(?DEVADDR_TABLES, [])
    ),

    Device2 = fake_device(DevAddr2),
    {ok, Device2} = ?MODULE:save(Device2),

    ?assertEqual([], ?MODULE:get_by_devaddr(DevAddr1)),
    ?assertEqual([Device2, UpdatedDevice1], ?MODULE:get_by_devaddr(DevAddr2)),
    ?assertEqual([UpdatedDevice1], ?MODULE:get_by_devaddr(DevAddr3)),
    ?assertEqual([Device2, UpdatedDevice1], ?MODULE:get()),
    ?assertEqual({ok, Device2}, ?MODULE:get(router_device:id(Device2))),
    ?assertEqual(2, ?MODULE:size()),

    gen_server:stop(Pid),
    ets:delete(?ETS),
    lists:foreach(fun ets:delete/1, persistent_term:get(?DEVADDR_TABLES, [])),
    ok.

fake_device(DevAddr) ->
    DeviceID = router_utils:uuid_v4(),
    Updates = [
        {name, DeviceID},
        {app_eui, <<"app_eui">>},
        {dev_eui, <<"dev_eui">>},
        {keys, [{<<"nwk_s_key">>, <<"app_s_key">>}]},
        {devaddrs, [DevAddr]},
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
    router_device:update(Updates, router_device:new(DeviceID)).

-endif.
