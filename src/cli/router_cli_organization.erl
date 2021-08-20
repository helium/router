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
            "  info all [--less 42] [--more 42]  - Display DC for all Orgs\n",
            "  info <org_id>                     - Display info for single Org\n"
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
            "  info all [--less 42] [--more 42]    - Display DC for all Orgs\n",
            "  info <org_id>                       - Display info for single Org\n"
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
                ]},
                {more_than, [
                    {longname, "more"},
                    {datatype, integer}
                ]}
            ],
            fun org_info_all/3
        ],
        [["organization", "info", '*'], [], [], fun org_info_single/3]
    ].

org_info_all(["organization", "info", "all"], [], Flags) ->
    APIOrgs = get_api_orgs(),
    case APIOrgs of
        [] ->
            c_text("No organization found.");
        _ ->
            DCTracketOrgs = get_dc_tracker_orgs(),
            LessThan = proplists:get_value(less_than, Flags, undefined),
            MoreThan = proplists:get_value(more_than, Flags, undefined),
            OrgList = lists:filtermap(
                fun(Org) ->
                    ID = proplists:get_value(id, Org),
                    {CacheBalance, CacheNonce} =
                        case proplists:get_value(ID, DCTracketOrgs) of
                            undefined ->
                                {undefined, undefined};
                            {B, N} ->
                                {B, N}
                        end,
                    True =
                        {true,
                            Org ++
                                [
                                    {cached_balance, CacheBalance},
                                    {cached_nonce, CacheNonce}
                                ]},
                    Balance = proplists:get_value(balance, Org),
                    FilterBalance =
                        case Balance of
                            undefined -> 0;
                            _ -> Balance
                        end,
                    case {LessThan, MoreThan} of
                        {undefined, undefined} ->
                            True;
                        {undefined, _} when FilterBalance > MoreThan ->
                            True;
                        {undefined, _} ->
                            false;
                        {_, undefined} when FilterBalance < LessThan ->
                            True;
                        {_, undefined} ->
                            false;
                        {_, _} when FilterBalance < LessThan andalso FilterBalance > MoreThan ->
                            True;
                        {_, _} ->
                            false
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

org_info_single(["organization", "info", OrgStr], [], _Flags) ->
    OrgID = erlang:list_to_binary(OrgStr),
    case router_console_api:get_org(OrgID) of
        {error, _} ->
            c_text("Organization not found.");
        {ok, Org} ->
            {CacheBalance, CacheNonce} =
                case router_console_dc_tracker:lookup(OrgID) of
                    {ok, B, N} ->
                        {B, N};
                    {error, _} ->
                        {undefined, undefined}
                end,
            c_table([
                format_api_org(Org) ++
                    [
                        {cached_balance, CacheBalance},
                        {cached_nonce, CacheNonce}
                    ]
            ])
    end.

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

-spec get_dc_tracker_orgs() -> list({binary(), balance_nonce()}).
get_dc_tracker_orgs() ->
    router_console_dc_tracker:lookup_all().

-spec get_api_orgs() -> list(list()).
get_api_orgs() ->
    case router_console_api:get_orgs() of
        {error, _} ->
            [];
        {ok, Orgs} ->
            [format_api_org(Org) || Org <- Orgs]
    end.

-spec format_api_org(map()) -> list().
format_api_org(Map) ->
    [
        {id, not_null(maps:get(<<"id">>, Map, undefined))},
        {name, not_null(maps:get(<<"name">>, Map, undefined))},
        {balance, not_null(maps:get(<<"dc_balance">>, Map, undefined))},
        {nonce, not_null(maps:get(<<"dc_balance_nonce">>, Map, undefined))}
    ].

-spec not_null(any()) -> any().
not_null(null) -> undefined;
not_null(Any) -> Any.

-spec c_table(list()) -> clique_status:status().
c_table(PropLists) ->
    [clique_status:table(PropLists)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].
