-module(router_cli_registry).

-define(CLI_MODULES, [router_cli_dc_tracker, router_cli_device_worker]).

-export([register_cli/0]).

register_cli() ->
    clique:register(?CLI_MODULES).
