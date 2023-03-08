-module(router_cli_registry).

-define(CLI_MODULES, [
    router_cli_device_worker,
    router_cli_info,
    router_cli_xor_filter,
    router_cli_organization,
    router_cli_migration
]).

-export([register_cli/0]).

register_cli() ->
    Modules =
        case router_xor_filter_worker:enabled() of
            true -> ?CLI_MODULES;
            false -> lists:delete(router_cli_xor_filter, ?CLI_MODULES)
        end,
    clique:register(Modules).
