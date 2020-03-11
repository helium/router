-module(router_device_api_behavior).

-callback init(Args :: any()) -> ok.
-callback get_devices(DevEui :: binary(), AppEui :: binary()) -> [{binary(), router_device:device()}].
-callback get_channels(Device :: router_device:device(), DeviceWorkerPid :: pid()) -> [router_channel:channel()].
-callback report_device_status(Device :: router_device:device(), Map :: #{}) -> ok.
-callback report_channel_status(Device :: router_device:device(), Map :: #{}) -> ok.

