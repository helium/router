-module(router_device_worker_utils).

-export([
    channels_worker/1,
    dev_nonce/1,
    event_manager/1,
    fcnt/1,
    device/1,
    offer_cache/1,
    refresh_channels/1
]).

-spec channels_worker(router_device:id()) -> pid().
channels_worker(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt,
        _OUI, ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADREngine,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    ChannelsWorkerPid.

-spec dev_nonce(router_device:id()) -> non_neg_integer().
dev_nonce(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt,
        _OUI, _ChannelsWorkerPid, LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    LastDevNonce.

-spec event_manager(router_device:id()) -> pid().
event_manager(DeviceID) ->
    ChannelWorkerPid = ?MODULE:channels_worker(DeviceID),
    {state, _Chain, EventManagerPid, _DeviceWorkerPid, _Device, _Channels, _ChannelsBackoffs,
        _DataCache} = sys:get_state(ChannelWorkerPid),
    EventManagerPid.

-spec fcnt(router_device:id()) -> non_neg_integer().
fcnt(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, FCnt,
        _OUI, _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    FCnt.

-spec device(router_device:id()) -> router_device:device().
device(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt,
        _OUI, _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, _OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    Device.

-spec offer_cache(router_device:id()) -> map().
offer_cache(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _FrameTimeout, _Device, _QueueUpdates, _DownlinkHandlkedAt, _FCnt,
        _OUI, _ChannelsWorkerPid, _LastDevNonce, _JoinChache, _FrameCache, OfferCache, _ADRCache,
        _IsActive, _Discovery} = sys:get_state(
        WorkerPid
    ),
    OfferCache.

-spec refresh_channels(router_device:id()) -> ok.
refresh_channels(DeviceID) ->
    Pid = ?MODULE:channels_worker(DeviceID),
    Pid ! refresh_channels,
    timer:sleep(250),
    ok.
