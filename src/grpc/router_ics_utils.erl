%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_utils).

-export([
    start_link_args/1,
    channel/0,
    connect/3,
    batch_update/3
]).

-define(ICS_CHANNEL, ics_channel).

-spec start_link_args(map()) -> ignore | map().
start_link_args(#{transport := ""}) ->
    ignore;
start_link_args(#{host := ""}) ->
    ignore;
start_link_args(#{port := ""}) ->
    ignore;
start_link_args(#{transport := "http"} = Args) ->
    start_link_args(Args#{transport => http});
start_link_args(#{transport := "https"} = Args) ->
    start_link_args(Args#{transport => https});
start_link_args(#{port := Port} = Args) when is_list(Port) ->
    start_link_args(Args#{port => erlang:list_to_integer(Port)});
start_link_args(#{transport := Transport, host := Host, port := Port} = Args) when
    is_atom(Transport) andalso is_list(Host) andalso is_integer(Port)
->
    Args;
start_link_args(_) ->
    ignore.

channel() ->
    ?ICS_CHANNEL.

-spec connect(Transport :: http | https, Host :: string(), Port :: non_neg_integer()) ->
    ok | {error, any()}.
connect(Transport, Host, Port) ->
    case grpcbox_channel:pick(?MODULE:channel(), stream) of
        {error, _} ->
            case
                grpcbox_client:connect(?MODULE:channel(), [{Transport, Host, Port, []}], #{
                    sync_start => true
                })
            of
                {ok, _Conn} ->
                    connect(Transport, Host, Port);
                {error, {already_started, _}} ->
                    connect(Transport, Host, Port);
                {error, _Reason} = Error ->
                    Error
            end;
        {ok, {_Conn, _Interceptor}} ->
            ok
    end.

-spec batch_update(
    Fun :: fun((Action, T) -> ok),
    List :: [{Action, [T]}],
    BatchSleep :: non_neg_integer()
) ->
    ok | {error, any()}
when
    Action :: add | remove.
batch_update(Fun, List, BatchSleep) ->
    Size = 250,
    lists:foreach(
        fun({Action, Els}) ->
            ct:print(
                "batch update [action: ~p] [count: ~p] [batch_sleep: ~pms]",
                [Action, erlang:length(Els), BatchSleep]
            ),
            lists:foldl(
                fun(El, Idx) ->
                    %% we pause between every batch of 1k to not oversaturate
                    %% our connection to the config service.
                    case Idx rem Size of
                        0 ->
                            ct:print("batch ~p / ~p (~p)", [Idx div Size, length(Els) / Size, Idx]),
                            timer:sleep(BatchSleep);
                        _ ->
                            ok
                    end,
                    ok = Fun(Action, El),
                    Idx + 1
                end,
                1,
                Els
            ),
            ct:print("batch ~p done ~p", [Action, length(Els)])
        end,
        List
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

batch_update_test() ->
    Ok = fun(_, _) -> ok end,

    %% warmup
    {_, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 500)}], timer:seconds(0)]),
    {_, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 500)}], timer:seconds(5)]),

    {Time0, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 2500)}], 0]),
    {Time1, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 2500)}], 50]),
    {Time2, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 2500)}], 100]),
    {Time3, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 2500)}], 150]),
    %% ct:print("~p < ~p < ~p < ~p", [
    %%     erlang:convert_time_unit(Time0, microsecond, millisecond),
    %%     erlang:convert_time_unit(Time1, microsecond, millisecond),
    %%     erlang:convert_time_unit(Time2, microsecond, millisecond),
    %%     erlang:convert_time_unit(Time3, microsecond, millisecond)
    %% ]),
    ?assert(Time0 < Time1),
    ?assert(Time1 < Time2),
    ?assert(Time2 < Time3),

    ok.

-endif.
