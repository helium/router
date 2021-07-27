-module(router_cli_registry).

-define(CLI_MODULES, [
    router_cli_dc_tracker,
    router_cli_device_worker,
    router_cli_info,
    router_cli_xor_filter
]).

-export([register_cli/0]).

register_cli() ->
    clique:register(?CLI_MODULES).
