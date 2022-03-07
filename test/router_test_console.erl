-module(router_test_console).

-export([
    init/0,
    lookup_devices/0,
    lookup_device/1,
    insert_device/2
]).

-define(ETS, router_test_console_ets).
-define(DEVICE_KEY(DeviceID), {device, DeviceID}).

init() ->
    _ = ets:new(?ETS, [public, set, named_table]),
    ElliOpts = [
        {callback, router_test_console_callback},
        {callback_args, #{
            forward => self()
        }},
        {port, 3000}
    ],
    {ok, Pid} = elli:start_link(ElliOpts),
    application:ensure_all_started(gun),
    lager:info("started @ ~p", [Pid]),
    Pid.

-spec lookup_devices() -> [router_device:device()].
lookup_devices() ->
    ets:select(?ETS, [
        {{{device, '$1'}, '$2'}, [], ['$2']}
    ]).

-spec lookup_device(DeviceID :: router_device:id()) ->
    {ok, router_device:device(), binary()} | {error, not_found}.
lookup_device(DeviceID) ->
    case ets:lookup(?ETS, ?DEVICE_KEY(DeviceID)) of
        [{?DEVICE_KEY(DeviceID), {Device, AppKey}}] ->
            {ok, Device, AppKey};
        [] ->
            {error, not_found}
    end.

-spec insert_device(Device :: router_device:device(), AppKey :: binary()) -> ok.
insert_device(Device, AppKey) ->
    true = ets:insert(?ETS, {?DEVICE_KEY(router_device:id(Device)), {Device, AppKey}}),
    ok.
