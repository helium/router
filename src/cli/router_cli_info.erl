%%%-------------------------------------------------------------------
%% @doc router_cli_info
%% @end
%%%-------------------------------------------------------------------
-module(router_cli_info).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).

-include("router_device_worker.hrl").

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [info_usage()]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [info_cmd()]
    ).

%%--------------------------------------------------------------------
%% info
%%--------------------------------------------------------------------

info_usage() ->
    [
        ["info"],
        [
            "\n\n",
            "info height                - Get height of the blockchain for this router\n",
            "                               The first number is the current election epoch, and the second is\n"
            "                               the block height.  If the second number is displayed with an asterisk (*)\n"
            "                               this node has yet to sync past the assumed valid hash in the node config.\n\n"
            "info name                  - Get name for this router\n"
            "info block_age             - Get age of the latest block in the chain, in seconds.\n"
            "info device <device_id>    - Device's stats\n"
            "info hotspot <hotspot_b58> - Device's stats\n"
        ]
    ].

info_cmd() ->
    [
        [["info", "height"], [], [], fun info_height/3],
        [["info", "name"], [], [], fun info_name/3],
        [["info", "block_age"], [], [], fun info_block_age/3],
        [["info", "device", '*'], [], [], fun info_device/3],
        [["info", "hotspot", '*'], [], [], fun info_hotspot/3]
    ].

info_height(["info", "height"], [], []) ->
    Chain = router_utils:get_blockchain(),
    {ok, Height} = blockchain:height(Chain),
    {ok, SyncHeight} = blockchain:sync_height(Chain),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    {Epoch0, _} = blockchain_block_v1:election_info(HeadBlock),
    Epoch = integer_to_list(Epoch0),
    case SyncHeight == Height of
        true ->
            [clique_status:text(Epoch ++ "\t\t" ++ integer_to_list(Height))];
        false ->
            [
                clique_status:text([
                    Epoch,
                    "\t\t",
                    integer_to_list(Height),
                    "\t\t",
                    integer_to_list(SyncHeight),
                    "*"
                ])
            ]
    end;
info_height([_, _, _], [], []) ->
    usage.

info_name(["info", "name"], [], []) ->
    {ok, Name} = erl_angry_purple_tiger:animal_name(
        libp2p_crypto:bin_to_b58(blockchain_swarm:pubkey_bin())
    ),
    [clique_status:text(Name)];
info_name([_, _, _], [], []) ->
    usage.

info_block_age(["info", "block_age"], [], []) ->
    Chain = router_utils:get_blockchain(),
    {ok, Block} = blockchain:head_block(Chain),
    Age = erlang:system_time(seconds) - blockchain_block:time(Block),
    [clique_status:text(integer_to_list(Age))];
info_block_age([_, _, _], [], []) ->
    usage.

info_device(["info", "device", DeviceID0], [], []) ->
    Formated = format(router_device_stats:lookup_device(DeviceID0)),
    c_table(Formated).

info_hotspot(["info", "hotspot", HotspotB580], [], []) ->
    Formated = format(router_device_stats:lookup_hotspot(HotspotB580)),
    c_table(Formated).

-spec format(list()) -> list().
format(List) ->
    lists:map(
        fun({DeviceID, HotspotName, HotspotB58, Counter}) ->
            [
                {device, DeviceID},
                {hotspot_name, HotspotName},
                {hotspot_b58, HotspotB58},
                {conflicts, Counter}
            ]
        end,
        List
    ).

-spec c_table(list(proplists:proplist()) | proplists:proplist()) -> clique_status:status().
c_table(PropLists) -> [clique_status:table(PropLists)].
