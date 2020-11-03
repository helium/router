-define(EVT_MGR, router_metrics_evt_mgr).

-define(METRICS_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_TICK, '__router_metrics_tick').
-define(METRICS_EVT_MGR, router_metrics_evt_mgr).

-define(DC, router_dc_balance).
-define(SC_ACTIVE_COUNT, router_state_channel_active_count).
-define(SC_ACTIVE, router_state_channel_active).
-define(ROUTING_OFFER, router_device_routing_offer_duration).
-define(ROUTING_PACKET, router_device_routing_packet_duration).
-define(PACKET_TRIP, router_device_packet_trip_duration).
-define(DECODED_TIME, router_decoder_decoded_duration).
-define(FUN_DURATION, router_function_duration).
-define(CONSOLE_API_TIME, router_console_api_duration).
-define(DOWNLINK, router_device_downlink_packet).
-define(WS, router_ws_state).

-define(METRICS, [
    {?SC_ACTIVE, [], "Active State Channel balance"},
    {?SC_ACTIVE_COUNT, [], "Active State Channel count"},
    {?DC, [], "Active State Channel balance"},
    {?ROUTING_OFFER, [type, status, reason], "Routing Offer duration"},
    {?ROUTING_PACKET, [type, status, reason, downlink], "Routing Packet duration"},
    {?PACKET_TRIP, [type, downlink], "Packet round trip duration"},
    {?DECODED_TIME, [type, status], "Decoder decoded duration"},
    {?FUN_DURATION, [function], "Function duration"},
    {?CONSOLE_API_TIME, [type, status], "Console API duration"},
    {?DOWNLINK, [type, status], "Downlink count"},
    {?WS, [], "Websocket State"}
]).
