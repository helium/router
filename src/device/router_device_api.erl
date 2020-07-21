-module(router_device_api).

-export([module/0,
         get_device/1,
         get_device/4,
         get_devices/2,
         get_channels/2,
         report_status/2,
         get_downlink_url/2]).

-define(API_MOD, router_device_api_module).

-spec module() -> atom().
module() ->
    {ok, Module} = application:get_env(router, ?API_MOD),
    Module.

-spec get_device(binary()) -> {ok, router_device:device()} | {error, any()}.
get_device(DeviceID) ->
    Mod = ?MODULE:module(),
    Mod:get_device(DeviceID).

-spec get_device(binary(), binary(), binary(), binary()) -> {ok, router_device:device(), binary()} | {error, any()}.
get_device(DevEui, AppEui, Msg, MIC) ->
    Mod = ?MODULE:module(),
    case Mod:get_devices(DevEui, AppEui) of
        [] -> {error, api_not_found};
        KeysAndDevices -> find_device(Msg, MIC, KeysAndDevices)
    end.

-spec get_devices(binary(), binary()) -> {ok, [router_device:device()]} | {error, any()}.
get_devices(DevEui, AppEui) ->
    Mod = ?MODULE:module(),
    case Mod:get_devices(DevEui, AppEui) of
        [] -> {error, api_not_found};
        KeysAndDevices -> {ok, [Device || {_, Device} <- KeysAndDevices]}
    end.

-spec get_channels(Device :: router_device:device(), DeviceWorkerPid :: pid()) -> [router_channel:channel()].
get_channels(Device, DeviceWorkerPid) ->
    Mod = ?MODULE:module(),
    Mod:get_channels(Device, DeviceWorkerPid).

-spec report_status(router_device:device(), map()) -> ok.
report_status(Device, Map) ->
    Mod = ?MODULE:module(),
    Mod:report_status(Device, Map).

-spec get_downlink_url(router_channel:channel(), binary()) -> binary().
get_downlink_url(Channel, DeviceID) ->
    Mod = ?MODULE:module(),
    Mod:get_downlink_url(Channel, DeviceID).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_device(binary(), binary(), [{binary(), router_device:device()}]) -> {ok, router_device:device(), binary()} | {error, not_found}.
find_device(_Msg, _MIC, []) ->
    {error, not_found};
find_device(Msg, MIC, [{AppKey, Device}|T]) ->
    case crypto:cmac(aes_cbc128, AppKey, Msg, 4) of
        MIC ->
            {ok, Device, AppKey};
        _ ->
            find_device(Msg, MIC, T)
    end.
