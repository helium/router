-module(router_cli_dc_tracker).

-behavior(clique_handler).

-export([register_cli/0]).

-define(USAGE, fun(_, _, _) -> usage end).
-define(NO_MATCHES_MESSAGE,
    "Router tracks DC for organizations with actively transmitting devices in memory only.\n"
    "Refer to https://docs.helium.com/use-the-network/console/users#organizations to view current DC balances."
).

-type balance_nonce() :: {non_neg_integer(), non_neg_integer()}.

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(
        fun(Args) -> apply(clique, register_usage, Args) end,
        [
            dc_usage(),
            dc_info_usage(),
            dc_refill_usage()
        ]
    ).

register_all_cmds() ->
    lists:foreach(
        fun(Cmds) -> [apply(clique, register_command, Cmd) || Cmd <- Cmds] end,
        [
            dc_cmd(),
            dc_info_cmd(),
            dc_refill_cmd()
        ]
    ).

%%--------------------------------------------------------------------
%% dc
%%--------------------------------------------------------------------

dc_usage() ->
    [
        ["dc_tracker"],
        [
            "DC Tracker commands\n\n",
            "  info all [--less 42] [--refetch]                 - Display DC for all Orgs\n",
            "  info <org_id> [--refetch]                        - Display info for single Org\n",
            "  info no-nonce                                    " ++
                "- List all Orgs with a nonce of 0 (zero)\n",
            "  info no-balance                                  " ++
                "- List all Orgs with a balance of 0 (zero)\n",
            "  info nonce <amount>                              - List Orgs with <nonce>\n",
            "  info balance <amount>                            - List Orgs with <balance>\n"
            "  info <org_id>                                    - Display info for single Org\n",
            "  refill <org_id> balance=<balance> nonce=<nonce>  - Refill Org\n\n"
        ]
    ].

dc_cmd() ->
    [
        [["dc_tracker"], [], [], ?USAGE]
    ].

%%--------------------------------------------------------------------
%% dc info
%%--------------------------------------------------------------------

dc_info_usage() ->
    [
        ["dc_tracker", "info"],
        [
            "Info commands (all commands have [--refetch] flag)\n\n",
            "  info all [--less 42]   - Display DC for all Orgs\n",
            "  info <org_id>          - Display info for single Org\n",
            "  info no-nonce          - List all Orgs with a nonce of 0 (zero)\n",
            "  info no-balance        - List all Orgs with a balance of 0 (zero)\n",
            "  info nonce <amount>    - List Orgs with <nonce>\n",
            "  info balance <amount>  - List Orgs with <balance>\n\n"
            "Options:\n\n",
            "  --less\n",
            "      Filter for balances less than amount\n",
            "  --refetch\n",
            "      Refetch org balances from console (requires filter)\n\n"
        ]
    ].

dc_info_cmd() ->
    [
        [
            ["dc_tracker", "info", "all"],
            [],
            [
                {less_than, [
                    {longname, "less"},
                    {datatype, integer}
                ]},
                refetch_flag()
            ],
            fun dc_info_all/3
        ],
        [["dc_tracker", "info", "nonce", '*'], [], [refetch_flag()], fun dc_info_by_nonce/3],
        [["dc_tracker", "info", "balance", '*'], [], [refetch_flag()], fun dc_info_by_balance/3],
        [["dc_tracker", "info", "no-nonce"], [], [refetch_flag()], fun dc_info_no_nonce/3],
        [["dc_tracker", "info", "no-balance"], [], [refetch_flag()], fun dc_info_no_balance/3],
        [["dc_tracker", "info", '*'], [], [refetch_flag()], fun dc_info_single/3]
    ].

refetch_flag() ->
    {refetch, [
        {longname, "refetch"},
        {datatype, boolean}
    ]}.

dc_info_by_nonce(["dc_tracker", "info", "nonce", Nonce], [], Flags) ->
    N = list_to_integer(Nonce),
    list_orgs_maybe_refetch(lookup_nonce(N), Flags).

dc_info_by_balance(["dc_tracker", "info", "balance", Balance], [], Flags) ->
    B = list_to_integer(Balance),
    list_orgs_maybe_refetch(lookup_nonce(B), Flags).

dc_info_no_nonce(["dc_tracker", "info", "no-nonce"], [], Flags) ->
    list_orgs_maybe_refetch(lookup_nonce(0), Flags).

dc_info_no_balance(["dc_tracker", "info", "no-balance"], [], Flags) ->
    list_orgs_maybe_refetch(lookup_balance(0), Flags).

dc_info_all(["dc_tracker", "info", "all"], [], Flags) ->
    Amount = proplists:get_value(less_than, Flags),
    Orgs =
        case proplists:get_value(less_than, Flags) of
            undefined -> lookup_all();
            Amount -> lookup_balance_less_than(Amount)
        end,
    list_orgs_maybe_refetch(Orgs, Flags).

dc_info_single(["dc_tracker", "info", Org], [], Flags) ->
    OrgId = erlang:list_to_binary(Org),
    Refetch = proplists:is_defined(refetch, Flags),

    case {lookup(OrgId), Refetch} of
        {{error, not_found}, _} ->
            c_text("Org named ~s not found", [OrgId]);
        {{ok, Match}, false} ->
            c_text(format_org_balance({OrgId, Match}));
        {{ok, Old}, true} ->
            New = refetch(OrgId),
            c_text(format_refetched_balance(OrgId, Old, New))
    end.

-spec list_orgs_maybe_refetch([{binary(), balance_nonce()}], list()) -> any().
list_orgs_maybe_refetch(Orgs, Flags) ->
    Refetch = proplists:is_defined(refetch, Flags),
    case {Orgs, Refetch} of
        {[], _} ->
            c_text("- no matches~n~n~p~n", [?NO_MATCHES_MESSAGE]);
        {Matches, false} ->
            Matches1 = [format_org_balance(Org) || Org <- Matches],
            c_list(Matches1);
        {Matches, true} ->
            Total = erlang:length(Matches),
            Matches1 =
                lists:map(
                    fun({Idx, {OrgId, Old}}) ->
                        New = refetch(OrgId),
                        io:format("  Progress: ~p/~p\r", [Idx, Total]),
                        format_refetched_balance(OrgId, Old, New)
                    end,
                    lists:zip(lists:seq(1, Total), Matches)
                ),
            c_list(Matches1)
    end.

%%--------------------------------------------------------------------
%% dc refill
%%--------------------------------------------------------------------

dc_refill_usage() ->
    [
        ["dc_tracker", "refill"],
        [
            "Refill commmands\n\n",
            "  refill <org_id> -b <balance> -n <nonce> [--dry-run --force]     - Refill Org\n\n",
            "Options:\n\n",
            "  --dry-run\n",
            "      Don't do anything,         yet...\n",
            "  --force\n",
            "      If Org does not exist, create it.\n\n"
        ]
    ].

dc_refill_cmd() ->
    [
        [["dc_tracker", "refill"], [], [], ?USAGE],
        [
            ["dc_tracker", "refill", '*'],
            [],
            [
                {balance, [
                    {shortname, "b"},
                    {longmame, "balance"},
                    {datatype, integer}
                ]},
                {nonce, [
                    {shortname, "n"},
                    {longname, "nonce"},
                    {datatype, integer}
                ]},
                {dry_run, [
                    {longname, "dry-run"},
                    {datatype, boolean}
                ]},
                {force, [
                    {longname, "force"},
                    {datatype, boolean}
                ]}
            ],
            fun refill_cmd/3
        ]
    ].

refill_cmd(_, [], []) ->
    usage;
refill_cmd(["dc_tracker", "refill", Org], [], Flags) ->
    OrgId = erlang:list_to_binary(Org),
    refill_org(
        OrgId,
        lookup(OrgId),
        maps:from_list(Flags)
    ).

-spec refill_org(
    OrgId :: binary(),
    LookupResponse :: {ok, balance_nonce()} | {error, not_found},
    Options :: #{
        force => undefined,
        dry_run => undefined,
        balance := non_neg_integer(),
        nonce := non_neg_integer()
    }
) -> any().
refill_org(
    OrgId,
    _Missing = {error, not_found},
    _Force = #{force := _, balance := NewBalance, nonce := NewNonce}
) ->
    ok = refill(OrgId, NewBalance, NewNonce),
    c_text("Created ~p with ~p @ epoch ~p", [OrgId, NewBalance, NewNonce]);
refill_org(
    OrgId,
    _Missing = {error, not_found},
    _Options
) ->
    c_text(
        "Could not find the Organization you're looking for~n"
        "Create ~p by passing the --force flag~n",
        [OrgId]
    );
refill_org(
    OrgId,
    _Found = {ok, {Balance, Nonce}},
    _Noop = #{dry_run := _, balance := NewBalance, nonce := NewNonce}
) ->
    c_text(
        "[DRY-RUN] Refilled ~p with ~p (old: ~p) @ epoch ~p (old: ~p)",
        [OrgId, NewBalance, Balance, NewNonce, Nonce]
    );
refill_org(
    OrgId,
    _Found = {ok, {OldBalance, OldNonce}},
    #{balance := NewBalance, nonce := NewNonce}
) ->
    ok = refill(OrgId, NewBalance, NewNonce),
    c_text(
        "Refilled ~p with ~p (old: ~p) @ epoch ~p (old: ~p)",
        [OrgId, NewBalance, OldBalance, NewNonce, OldNonce]
    ).

%%--------------------------------------------------------------------
%% router_console_dc_tracker interface
%%--------------------------------------------------------------------

-spec lookup(binary()) -> {ok, balance_nonce()} | {error, not_found}.
lookup(Org) ->
    case router_console_dc_tracker:lookup(Org) of
        {ok, B, N} -> {ok, {B, N}};
        Val -> Val
    end.

-spec lookup_all() -> list({binary(), balance_nonce()}).
lookup_all() ->
    router_console_dc_tracker:lookup_all().

-spec lookup_balance_less_than(non_neg_integer()) -> list({binary(), balance_nonce()}).
lookup_balance_less_than(Amount) ->
    router_console_dc_tracker:lookup_balance_less_than(Amount).

-spec lookup_balance(non_neg_integer()) -> list({binary(), balance_nonce()}).
lookup_balance(Amount) ->
    router_console_dc_tracker:lookup_balance(Amount).

-spec lookup_nonce(non_neg_integer()) -> list({binary(), balance_nonce()}).
lookup_nonce(Amount) ->
    router_console_dc_tracker:lookup_nonce(Amount).

-spec refetch(binary()) -> balance_nonce().
refetch(Org) ->
    router_console_dc_tracker:fetch_and_save_org_balance(Org).

-spec refill(binary(), non_neg_integer(), non_neg_integer()) -> ok.
refill(Org, Balance, Nonce) ->
    router_console_dc_tracker:refill(Org, Nonce, Balance).

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

-spec c_list(list()) -> clique_status:status().
c_list(L) -> [clique_status:list(L)].

-spec c_text(string()) -> clique_status:status().
c_text(T) -> [clique_status:text([T])].

-spec c_text(string(), list(term())) -> clique_status:status().
c_text(F, Args) -> c_text(io_lib:format(F, Args)).

-spec format_refetched_balance(binary(), balance_nonce(), balance_nonce()) -> string().
format_refetched_balance(OrgId, {OldB, OldN}, {NewB, NewN}) ->
    B = format_field("balance", OldB, NewB),
    N = format_field("nonce", OldN, NewN),
    io_lib:format("~s --> ~s ~s~n", [OrgId, B, N]).

-spec format_org_balance({binary(), balance_nonce()}) -> string().
format_org_balance({OrgId, {Balance, Nonce}}) ->
    B = format_field("balance", Balance),
    N = format_field("nonce", Nonce),
    io_lib:format("~s --> ~s ~s~n", [OrgId, B, N]).

-spec format_field(string(), non_neg_integer()) -> string().
format_field(Name, Value) -> io_lib:format("[~s: ~p]", [Name, Value]).

-spec format_field(string(), non_neg_integer(), non_neg_integer()) -> string().
format_field(Name, Old, Old) -> io_lib:format("==[~s: ~p]==", [Name, Old]);
format_field(Name, Old, New) -> io_lib:format("[~s: ~p -> ~p]", [Name, Old, New]).
