-module(router_device_cache).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("stdlib/include/ms_transform.hrl").

-include("router_device.hrl").

-define(ETS, router_device_cache_ets).

-export([
    init/0,
    save/1,
    delete/1,
    get/0, get/1,
    get_by_devaddr/1
]).

-spec init() -> ok.
init() ->
    ets:new(?ETS, [public, named_table, set]),
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
    MS = ets:fun2ms(fun({_, D}) when D#device_v4.devaddr == DevAddr -> D end),
    ets:select(?ETS, MS).

-spec save(router_device:device()) -> {ok, router_device:device()}.
save(Device) ->
    DeviceID = router_device:id(Device),
    true = ets:insert(?ETS, {DeviceID, Device}),
    {ok, Device}.

-spec delete(binary()) -> ok.
delete(DeviceID) ->
    true = ets:delete(?ETS, DeviceID),
    ok.

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

uuid_v4() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    Str = io_lib:format(
        "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]
    ),
    list_to_binary(Str).

init_from_db_test() ->
    Dir = test_utils:tmp_dir("init_from_db_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    ok = init(),
    ID = uuid_v4(),
    Device = router_device:new(ID),

    {ok, DB, [_, CF]} = router_db:get(),
    ?assertEqual({ok, Device}, router_device:save(DB, CF, Device)),
    ?assertEqual(ok, init_from_db()),
    ?assertEqual({ok, Device}, ?MODULE:get(ID)),

    gen_server:stop(Pid),
    ets:delete(?ETS),
    ok.

get_save_delete_test() ->
    Dir = test_utils:tmp_dir("init_from_db_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    ok = init(),
    ID = uuid_v4(),
    Device = router_device:new(ID),

    ?assertEqual({ok, Device}, save(Device)),
    ?assertEqual({ok, Device}, ?MODULE:get(ID)),
    ?assertEqual([Device], ?MODULE:get()),
    ?assertEqual(ok, delete(ID)),
    ?assertEqual({error, not_found}, ?MODULE:get(ID)),

    gen_server:stop(Pid),
    ets:delete(?ETS),
    ok.

get_by_devaddr_test() ->
    Dir = test_utils:tmp_dir("init_from_db_test"),
    {ok, Pid} = router_db:start_link([Dir]),
    ok = init(),
    Max = 100000,
    lists:foreach(
        fun(I) ->
            ID = uuid_v4(),
            true = ets:insert(
                ?ETS,
                {ID, #device_v4{
                    id = ID,
                    devaddr = <<(I rem 2):25/integer-unsigned-little, 72:7/integer>>
                }}
            )
        end,
        lists:seq(1, Max)
    ),
    DevAddr = <<0:25/integer-unsigned-little, 72:7/integer>>,
    {Time, Got} = timer:tc(?MODULE, get_by_devaddr, [DevAddr]),

    ?assert(Time / 1000 < 100),
    ?assertEqual(Max / 2, length(Got) + 0.0),

    gen_server:stop(Pid),
    ets:delete(?ETS),
    ok.

-endif.
