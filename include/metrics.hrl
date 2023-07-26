-define(METRICS_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_TICK, '__router_metrics_tick').

-define(METRICS_ROUTING_PACKET, "router_device_routing_packet_duration").
-define(METRICS_CONSOLE_API, "router_console_api_duration").
-define(METRICS_WS, "router_ws_state").
-define(METRICS_VM_CPU, "router_vm_cpu").
-define(METRICS_VM_PROC_Q, "router_vm_process_queue").
-define(METRICS_VM_ETS_MEMORY, "router_vm_ets_memory").
-define(METRICS_DEVICE_TOTAL, "router_device_total_gauge").
-define(METRICS_DEVICE_RUNNING, "router_device_running_gauge").

-define(METRICS, [
    {?METRICS_ROUTING_PACKET, prometheus_histogram, [type, status, reason, downlink],
        "Routing Packet duration"},
    {?METRICS_CONSOLE_API, prometheus_histogram, [type, status], "Console API duration"},
    {?METRICS_WS, prometheus_boolean, [], "Websocket State"},
    {?METRICS_VM_CPU, prometheus_gauge, [cpu], "Router CPU usage"},
    {?METRICS_VM_PROC_Q, prometheus_gauge, [name], "Router process queue"},
    {?METRICS_VM_ETS_MEMORY, prometheus_gauge, [name], "Router ets memory"},
    {?METRICS_DEVICE_TOTAL, prometheus_gauge, [], "Device total gauge"},
    {?METRICS_DEVICE_RUNNING, prometheus_gauge, [], "Device running gauge"}
]).
