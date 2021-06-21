-define(EVT_MGR, router_metrics_evt_mgr).

-define(METRICS_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_TICK, '__router_metrics_tick').
-define(METRICS_EVT_MGR, router_metrics_evt_mgr).

-define(METRICS_DC, router_dc_balance).
-define(METRICS_SC_OPENED_COUNT, router_state_channel_opened_count).
-define(METRICS_SC_ACTIVE_COUNT, router_state_channel_active_count).
-define(METRICS_SC_ACTIVE_BALANCE, router_state_channel_active_balance).
-define(METRICS_SC_ACTIVE_ACTORS, router_state_channel_actors).
-define(METRICS_ROUTING_OFFER, router_device_routing_offer_duration).
-define(METRICS_ROUTING_PACKET, router_device_routing_packet_duration).
-define(METRICS_PACKET_TRIP, router_device_packet_trip_duration).
-define(METRICS_DECODED_TIME, router_decoder_decoded_duration).
-define(METRICS_FUN_DURATION, router_function_duration).
-define(METRICS_CONSOLE_API_TIME, router_console_api_duration).
-define(METRICS_DOWNLINK, router_device_downlink_packet).
-define(METRICS_WS, router_ws_state).
-define(METRICS_NETWORK_ID, router_device_routing_offer_network_id).
-define(METRICS_CHAIN_BLOCKS, router_blockchain_blocks).
-define(METRICS_VM_CPU, router_vm_cpu).
-define(METRICS_VM_PROC_Q, router_vm_process_queue).
-define(METRICS_VM_ETS_MEMORY, router_vm_ets_memory).

-define(METRICS, [
    {?METRICS_DC, [], "Active State Channel balance"},
    {?METRICS_SC_OPENED_COUNT, [], "Opened State Channel count"},
    {?METRICS_SC_ACTIVE_COUNT, [], "Active State Channel count"},
    {?METRICS_SC_ACTIVE_BALANCE, [index], "Active State Channel balance"},
    {?METRICS_SC_ACTIVE_ACTORS, [index], "Active State Channel actors"},
    {?METRICS_ROUTING_OFFER, [type, status, reason], "Routing Offer duration"},
    {?METRICS_ROUTING_PACKET, [type, status, reason, downlink], "Routing Packet duration"},
    {?METRICS_PACKET_TRIP, [type, downlink], "Packet round trip duration"},
    {?METRICS_DECODED_TIME, [type, status], "Decoder decoded duration"},
    {?METRICS_FUN_DURATION, [function], "Function duration"},
    {?METRICS_CONSOLE_API_TIME, [type, status], "Console API duration"},
    {?METRICS_DOWNLINK, [type, status], "Downlink count"},
    {?METRICS_WS, [], "Websocket State"},
    {?METRICS_NETWORK_ID, [network_id], "Offer by network ID"},
    {?METRICS_CHAIN_BLOCKS, [], "Router's blockchain blocks"},
    {?METRICS_VM_CPU, [cpu], "Router CPU usage"},
    {?METRICS_VM_PROC_Q, [name], "Router process queue"},
    {?METRICS_VM_ETS_MEMORY, [name], "Router ets memory"}
]).
