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
    batch_update/2, batch_update/4,
    wait_for_stream_close/2,
    do_wait_for_stream_close/2
]).

-define(ICS_CHANNEL, ics_channel).

-record(stream_close_opts, {
    stream :: grpcbox_client:stream(),
    module :: module(),
    curr_attempt :: non_neg_integer(),
    max_attempt :: non_neg_integer(),
    timeout_ms :: non_neg_integer()
}).

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
    List :: [{Action, [T]}]
) ->
    ok | {error, any()}
when
    Action :: add | remove.
batch_update(Fun, List) ->
    BatchSize = router_utils:get_env_int(config_service_batch_size, 1000),
    BatchSleep = router_utils:get_env_int(config_service_batch_sleep_ms, 500),
    ?MODULE:batch_update(Fun, List, BatchSleep, BatchSize).

-spec batch_update(
    Fun :: fun((Action, T) -> ok),
    List :: [{Action, [T]}],
    BatchSleep :: non_neg_integer(),
    BatchSize :: non_neg_integer()
) ->
    ok | {error, any()}
when
    Action :: add | remove.
batch_update(Fun, List, BatchSleep, BatchSize) ->
    lists:foreach(
        fun({Action, Els}) ->
            Total = erlang:length(Els),
            lager:info(
                "batch start [action: ~p] [count: ~p] [batch_sleep: ~pms] [batch_size: ~p]",
                [Action, Total, BatchSleep, BatchSize]
            ),
            lists:foldl(
                fun(El, Idx) ->
                    %% we pause between every batch of 1k to not oversaturate
                    %% our connection to the config service.
                    case Idx rem BatchSize of
                        0 ->
                            lager:info(
                                "batch update ~p / ~p (~p)",
                                [Idx div BatchSize, Total / BatchSize, Idx]
                            ),
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
            lager:info(
                "batch finished [action: ~p] [count: ~p] [batch_sleep: ~pms] [batch_size: ~p]",
                [Action, Total, BatchSleep, BatchSize]
            )
        end,
        List
    ).

-spec wait_for_stream_close(Module :: module(), Stream :: grpcbox_client:stream()) ->
    ok | {error, any()}.
wait_for_stream_close(Module, Stream) ->
    MaxAttempt = router_utils:get_env_int(config_service_max_timeout_attempt, 5),
    AttemptSleep = router_utils:get_env_int(config_service_max_timeout_sleep_ms, 5000),
    lager:info(
        "done sending ~p updates [timeout_retry: ~p] [recv_timeout: ~pms]",
        [Module, MaxAttempt, AttemptSleep]
    ),
    ?MODULE:do_wait_for_stream_close(
        grpcbox_client:recv_data(Stream, AttemptSleep),
        #stream_close_opts{
            stream = Stream,
            module = Module,
            curr_attempt = 0,
            max_attempt = MaxAttempt,
            timeout_ms = AttemptSleep
        }
    ).

-spec do_wait_for_stream_close(
    Result :: stream_finished | timeout | {ok, any()} | {error, any()},
    State :: #stream_close_opts{}
) -> ok | {error, any()}.
do_wait_for_stream_close({error, _} = Err, _State) ->
    lager:error("got an error: ~p", [Err]),
    Err;
do_wait_for_stream_close({ok, _} = Data, _State) ->
    lager:info("stream closed ok with: ~p", [Data]),
    ok;
do_wait_for_stream_close(stream_finished, _State) ->
    lager:info("got a stream_finished"),
    ok;
do_wait_for_stream_close(
    _Result,
    #stream_close_opts{
        curr_attempt = MaxAttempts,
        max_attempt = MaxAttempts
    }
) ->
    lager:warning("stream did not close within ~p attempts", [MaxAttempts]),
    {error, {max_timeouts_reached, MaxAttempts}};
do_wait_for_stream_close(
    timeout,
    #stream_close_opts{
        module = Mod,
        stream = Stream,
        curr_attempt = CurrentAttempt,
        max_attempt = MaxAttempt,
        timeout_ms = AttemptSleep
    } = State
) ->
    lager:info("~p waiting for stream to close, attempt ~p/~p", [Mod, CurrentAttempt, MaxAttempt]),
    timer:sleep(250),
    ?MODULE:do_wait_for_stream_close(
        grpcbox_client:recv_data(Stream, AttemptSleep),
        State#stream_close_opts{curr_attempt = CurrentAttempt + 1}
    ).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

batch_update_test() ->
    Ok = fun(_, _) -> ok end,

    %% warmup
    {_, _} = timer:tc(?MODULE, batch_update, [
        Ok, [{add, lists:seq(1, 500)}], timer:seconds(0), 1000
    ]),
    {_, _} = timer:tc(?MODULE, batch_update, [
        Ok, [{add, lists:seq(1, 500)}], timer:seconds(5), 1000
    ]),

    {Time0, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 2500)}], 0, 1000]),
    {Time1, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 2500)}], 50, 1000]),
    {Time2, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 2500)}], 100, 1000]),
    {Time3, _} = timer:tc(?MODULE, batch_update, [Ok, [{add, lists:seq(1, 2500)}], 150, 1000]),
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
