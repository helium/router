-module(router_cli_organization).

-behavior(clique_handler).

-export([register_cli/0]).

-type balance_nonce() :: {non_neg_integer(), non_neg_integer()}.

-define(USAGE, fun(_, _, _) -> usage end).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [
            org_usage(),
            org_info_usage()
        ]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [
            org_cmd(),
            org_info_cmd()
        ]
    ).

%%--------------------------------------------------------------------
%% org
%%--------------------------------------------------------------------

org_usage() ->
    [
        ["organization"],
        [
            "Organization commands\n\n",
            "  info all [--less 42] - Display DC for all Orgs\n"
        ]
    ].

org_cmd() ->
    [
        [["organization"], [], [], ?USAGE]
    ].

%%--------------------------------------------------------------------
%% org info
%%--------------------------------------------------------------------

org_info_usage() ->
    [
        ["organization", "info"],
        [
            "Info commands\n\n",
            "  info all [--less 42]   - Display DC for all Orgs\n"
        ]
    ].

org_info_cmd() ->
    [
        [
            ["organization", "info", "all"],
            [],
            [
                {less_than, [
                    {longname, "less"},
                    {datatype, integer}
                ]}
            ],
            fun org_info_all/3
        ]
    ].

org_info_all(["organization", "info", "all"], [], Flags) ->
    APIOrgs = api_orgs(),
    case APIOrgs of
        [] ->
            c_text("No organization found.");
        _ ->
            DCTracketOrgs = dc_tracker_orgs(),
            LessThan = proplists:get_value(less_than, Flags),
            OrgList = lists:filtermap(
                fun(Map) ->
                    Balance = maps:get(balance, Map),
                    case Balance < LessThan of
                        false ->
                            false;
                        _ ->
                            ID = maps:get(id, Map),
                            {CacheBalance, CacheNonce} =
                                case proplists:get_value(ID, DCTracketOrgs) of
                                    undefined ->
                                        {undefined, undefined};
                                    {B, N} ->
                                        {B, N}
                                end,
                            {true, [
                                {id, ID},
                                {name, maps:get(name, Map)},
                                {balance, Balance},
                                {nonce, maps:get(nonce, Map)},
                                {cached_balance, CacheBalance},
                                {cached_nonce, CacheNonce}
                            ]}
                    end
                end,
                APIOrgs
            ),
            case OrgList of
                [] ->
                    c_text("No organization found.");
                _ ->
                    c_table(OrgList)
            end
    end.

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

-spec dc_tracker_orgs() -> list({binary(), balance_nonce()}).
dc_tracker_orgs() ->
    router_console_dc_tracker:lookup_all().

-spec api_orgs() -> list(map()).
api_orgs() ->
    [#{id => <<"test">>, name => <<"Test Org">>, balance => 10, nonce => 1}].

-spec c_table(proplists:proplist()) -> clique_status:status().
c_table(PropLists) ->
    [clique_status:table(PropLists)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].
