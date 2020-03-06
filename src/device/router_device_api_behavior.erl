-module(router_device_api_behavior).

-callback init(Args :: any()) -> ok.
-callback get_devices(DevEui :: binary(), AppEui :: binary()) -> [{binary(), router_device:device()}].
-callback report_status(Device :: router_device:device(), Map :: #{}) -> ok.
-callback handle_data(Device :: router_device:device(), Map :: #{}) -> ok.
