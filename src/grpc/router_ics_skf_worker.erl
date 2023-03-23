%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_skf_worker).

-behavior(gen_server).

-include("./autogen/iot_config_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    reconcile/2,
    reconcile_end/2,
    update/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).

-export([
    list_skf/0,
    local_skf_to_remote_diff/2,
    is_reconciling/0
]).

-endif.

-define(SERVER, ?MODULE).
-define(INIT, init).
-define(RECONCILE_START, reconcile_start).
-define(RECONCILE_END, reconcile_end).
-define(UPDATE, update).

-ifdef(TEST).
-define(BACKOFF_MIN, 100).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    oui :: non_neg_integer(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: function(),
    transport :: http | https,
    host :: string(),
    port :: non_neg_integer(),
    conn_backoff :: backoff:backoff(),
    reconciling = false :: boolean(),
    reconcile_on_connect = true :: boolean()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    case router_ics_utils:start_link_args(Args) of
        #{skf_enabled := "true"} = Map ->
            gen_server:start_link({local, ?SERVER}, ?SERVER, Map, []);
        _ ->
            lager:warning("~s ignored ~p", [?MODULE, Args]),
            ignore
    end.

-spec reconcile(Pid :: pid() | undefined, Commit :: boolean()) -> ok.
reconcile(Pid, Commit) ->
    gen_server:cast(?SERVER, {?RECONCILE_START, #{forward_pid => Pid, commit => Commit}}).

-spec reconcile_end(
    Options :: map(),
    List :: list(iot_config_pb:iot_config_session_key_filter_v1_pb())
) -> ok.
reconcile_end(Options, List) ->
    gen_server:cast(?SERVER, {?RECONCILE_END, Options, List}).

-spec update(Updates :: list({add | remove, non_neg_integer(), binary()})) ->
    ok.
update(Updates) ->
    gen_server:cast(?SERVER, {?UPDATE, Updates}).

-ifdef(TEST).

-spec list_skf() ->
    {ok, list(iot_config_pb:iot_config_session_key_filter_v1_pb())} | {error, any()}.
list_skf() ->
    gen_server:call(?SERVER, list_skf, timer:seconds(30)).

-spec is_reconciling() -> boolean().
is_reconciling() ->
    gen_server:call(?SERVER, is_reconciling, infinity).

-endif.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(
    #{
        pubkey_bin := PubKeyBin,
        sig_fun := SigFun,
        transport := Transport,
        host := Host,
        port := Port
    } = Args
) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    %% {_, SigFun, _} = router_blockchain:get_key(),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    self() ! ?INIT,
    ReconcileOnConnect = maps:get(reconcile_on_connect, Args, true),
    {ok, #state{
        oui = router_utils:get_oui(),
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        transport = Transport,
        host = Host,
        port = Port,
        conn_backoff = Backoff,
        reconcile_on_connect = ReconcileOnConnect
    }}.

handle_call(is_reconciling, _From, #state{reconciling = Reconciling} = State) ->
    {reply, Reconciling, State};
handle_call(list_skf, From, State) ->
    %% ct:print("listing skf"),
    Options = #{type => listing_skf, reply_pid => From},
    case skf_list(Options, State) of
        {error, _} = Error ->
            ok = gen_server:reply(From, Error);
        {ok, _Stream} ->
            ok
    end,
    {noreply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({?RECONCILE_START, Options}, #state{conn_backoff = Backoff0} = State) ->
    ct:print("starting reconcile with: ~p", [Options]),
    lager:info("reconciling started pid: ~p", [Options]),
    case skf_list(Options, State) of
        {error, _Reason} = Error ->
            %% ct:print("reconcile fail 1"),
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?INIT),
            lager:warning("fail to skf_list ~p, retrying in ~wms", [
                _Reason, Delay
            ]),
            ok = forward_reconcile(Options, Error),
            {noreply, State#state{conn_backoff = Backoff1}};
        {ok, _Stream} ->
            %% ct:print("reconcile success 1"),
            {_, Backoff2} = backoff:succeed(Backoff0),
            {noreply, State#state{conn_backoff = Backoff2, reconciling = true}}
    end;
handle_cast({?RECONCILE_END, #{type := listing_skf, reply_pid := From}, SKFs}, #state{} = State) ->
    ct:print("got back skf list: ~p", [length(SKFs)]),
    ok = gen_server:reply(From, {ok, SKFs}),
    {noreply, State};
handle_cast(
    {?RECONCILE_END, #{forward_pid := Pid, commit := false} = Options, SKFs},
    #state{oui = OUI} = State
) when is_pid(Pid) ->
    lager:info("DRY RUN, got RECONCILE_END ~p, with ~w", [Options, erlang:length(SKFs)]),
    {ToAdd, ToRemove} = local_skf_to_remote_diff(OUI, SKFs),
    ok = forward_reconcile(Options, {ok, ToAdd, ToRemove}),
    lager:info("DRY RUN, reconciling done adding ~w removing ~w", [
        erlang:length(ToAdd), erlang:length(ToRemove)
    ]),
    {noreply, State#state{reconciling = false}};
handle_cast(
    {?RECONCILE_END, #{forward_pid := Pid, commit := true} = Options, SKFs},
    #state{oui = OUI} = State
) when is_pid(Pid) ->
    ct:print("got RECONCILE_END ~p, with ~w", [Options, erlang:length(SKFs)]),
    lager:info("got RECONCILE_END ~p, with ~w", [Options, erlang:length(SKFs)]),
    {ToAdd, ToRemove} = local_skf_to_remote_diff(OUI, SKFs),
    lager:info("reconciling done adding ~w removing ~w", [
        erlang:length(ToAdd), erlang:length(ToRemove)
    ]),
    case maybe_update_skf([{remove, ToRemove}, {add, ToAdd}], State) of
        {error, Reason} = Error ->
            ok = forward_reconcile(Options, Error),
            {noreply, skf_update_failed(Reason, State#state{reconciling = false})};
        ok ->
            ok = forward_reconcile(Options, {ok, ToAdd, ToRemove}),
            lager:info("reconciling done adding ~w removing ~w", [
                erlang:length(ToAdd), erlang:length(ToRemove)
            ]),
            {noreply, State#state{reconciling = false}}
    end;
handle_cast(
    {?RECONCILE_END, #{forward_pid := undefined, commit := true} = Options, SKFs},
    #state{oui = OUI} = State
) ->
    lager:info("got RECONCILE_END ~p, with ~w", [Options, erlang:length(SKFs)]),
    {ToAdd, ToRemove} = local_skf_to_remote_diff(OUI, SKFs),
    lager:info("reconciling done adding ~w removing ~w", [
        erlang:length(ToAdd), erlang:length(ToRemove)
    ]),
    case maybe_update_skf([{remove, ToRemove}, {add, ToAdd}], State) of
        {error, Reason} ->
            {noreply, skf_update_failed(Reason, State#state{reconciling = false})};
        ok ->
            lager:info("reconciling done adding ~w removing ~w", [
                erlang:length(ToAdd), erlang:length(ToRemove)
            ]),
            {noreply, State#state{reconciling = false}}
    end;
handle_cast(
    {?UPDATE, _Updates}, #state{reconciling = true} = State
) ->
    %% We ignore updates while we reconcile
    {noreply, State};
handle_cast(
    {?UPDATE, Updates0}, #state{oui = OUI, reconciling = false} = State
) ->
    Updates1 = maps:to_list(
        lists:foldl(
            fun({Action, DevAddr, Key}, Acc) ->
                Tail = maps:get(Action, Acc, []),
                SKF = #iot_config_session_key_filter_v1_pb{
                    oui = OUI,
                    devaddr = DevAddr,
                    session_key = binary:encode_hex(Key)
                },
                Acc#{Action => [SKF | Tail]}
            end,
            #{},
            Updates0
        )
    ),
    case maybe_update_skf(Updates1, State) of
        {error, Reason} ->
            {noreply, skf_update_failed(Reason, State)};
        ok ->
            lager:info("update done"),
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    ?INIT,
    #state{
        transport = Transport,
        host = Host,
        port = Port,
        conn_backoff = Backoff0,
        reconcile_on_connect = ReconcileOnConnect
    } = State
) ->
    ct:print("init"),
    case router_ics_utils:connect(Transport, Host, Port) of
        {error, _Reason} ->
            ct:print("could not connect"),
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:warning("fail to connect ~p, reconnecting in ~wms", [_Reason, Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT),
            {noreply, State#state{conn_backoff = Backoff1}};
        ok ->
            ct:print("connected"),
            lager:info("connected"),
            case ReconcileOnConnect of
                true ->
                    ok = ?MODULE:reconcile(undefined, true);
                false ->
                    ok
            end,
            {noreply, State}
    end;
handle_info({headers, _StreamID, _Data}, State) ->
    {noreply, State};
handle_info({trailers, _StreamID, _Data}, State) ->
    {noreply, State};
handle_info({eos, _StreamID}, State) ->
    {noreply, State};
handle_info({'END_STREAM', _StreamID}, State) ->
    {noreply, State};
handle_info({'DOWN', _Ref, _Type, _Pid, _Reason}, State) ->
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ct:print("are we terminating: ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec skf_list(Options :: map() | undefined, state()) ->
    {ok, grpcbox_client:stream()} | {error, any()}.
skf_list(Options, #state{oui = OUI, sig_fun = SigFun}) ->
    Req = #iot_config_session_key_filter_list_req_v1_pb{
        oui = OUI,
        timestamp = erlang:system_time(millisecond)
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_session_key_filter_list_req_v1_pb),
    SignedReq = Req#iot_config_session_key_filter_list_req_v1_pb{signature = SigFun(EncodedReq)},
    helium_iot_config_session_key_filter_client:list(SignedReq, #{
        channel => router_ics_utils:channel(),
        callback_module => {
            router_ics_skf_list_handler,
            Options
        }
    }).

-spec local_skf_to_remote_diff(OUI :: non_neg_integer(), Remote :: SKFList) ->
    {ToAdd :: SKFList, ToRemove :: SKFList}
when
    SKFList :: [iot_config_pb:iot_config_session_key_filter_v1_pb()].
local_skf_to_remote_diff(OUI, RemoteSKFs) ->
    Local = get_local_skfs(OUI),

    Add = Local -- RemoteSKFs,
    Remove = RemoteSKFs -- Local,

    {Add, Remove}.

-spec get_local_skfs(OUI :: non_neg_integer()) ->
    [iot_config_pb:iot_config_session_key_filter_v1_pb()].
get_local_skfs(OUI) ->
    Devices = router_device_cache:get(),
    lists:usort(
        lists:filtermap(
            fun(Device) ->
                case {router_device:devaddr(Device), router_device:nwk_s_key(Device)} of
                    {undefined, _} ->
                        false;
                    {_, undefined} ->
                        false;
                    %% devices store devaddrs reversed. Config service expects them BE.
                    {<<DevAddr:32/integer-unsigned-little>>, SessionKey} ->
                        {true, #iot_config_session_key_filter_v1_pb{
                            oui = OUI,
                            devaddr = DevAddr,
                            session_key = erlang:binary_to_list(binary:encode_hex(SessionKey))
                        }}
                end
            end,
            Devices
        )
    ).

-spec maybe_update_skf(
    List :: [{add | remove, [iot_config_pb:iot_config_session_key_filter_v1_pb()]}],
    State :: state()
) ->
    ok | {error, any()}.
maybe_update_skf(List0, State) ->
    List1 = lists:filter(
        fun
            ({_Action, []}) -> false;
            ({_Action, _L}) -> true
        end,
        List0
    ),
    update_skf(List1, State).

-spec update_skf(
    List :: [{add | remove, [iot_config_pb:iot_config_session_key_filter_v1_pb()]}],
    State :: state()
) ->
    ok | {error, any()}.
update_skf([], _State) ->
    ok;
update_skf(List, State) ->
    BatchSize = router_utils:get_env_int(config_service_batch_size, 1000),
    BatchSleep = router_utils:get_env_int(config_service_batch_sleep_ms, 500),
    MaxAttempt = router_utils:get_env_int(config_service_max_timeout_attempt, 5),

    case
        helium_iot_config_session_key_filter_client:update(#{
            channel => router_ics_utils:channel()
        })
    of
        {error, _} = Error ->
            ct:print("update stream ERROR: ~p", [Error]),
            Error;
        {ok, Stream} ->
            ct:print("Got update stream"),
            router_ics_utils:batch_update(
                fun(Action, SKF) ->
                    %% lager:info("~p ~p", [Action, SKF]),
                    ok = update_skf(Action, SKF, Stream, State)
                end,
                List,
                BatchSleep,
                BatchSize
            ),

            ok = grpcbox_client:close_send(Stream),
            lager:info("done sending skf updates [timeout_retry: ~p]", [MaxAttempt]),
            wait_for_stream_close(init, Stream, 0, MaxAttempt)
    end.

-spec wait_for_stream_close(
    Result :: init | stream_finished | timeout | {ok, any()} | {error, any()},
    Stream :: map(),
    CurrentAttempts :: non_neg_integer(),
    MaxAttempts :: non_neg_integer()
) -> ok | {error, any()}.
wait_for_stream_close(_, _, MaxAttempts, MaxAttempts) ->
    ct:print("[~p] stream did not close within ~p attempts", [?FUNCTION_NAME, MaxAttempts]),
    {error, {max_timeouts_reached, MaxAttempts}};
wait_for_stream_close({error, _} = Err, _Stream, _TimeoutAttempts, _MaxAttempts) ->
    ct:print("[~p] got an error: ~p", [?FUNCTION_NAME, Err]),
    Err;
wait_for_stream_close({ok, _} = Data, _Stream, _TimeoutAttempts, _MaxAttempts) ->
    ct:print("[~p] got an ok: ~p", [?FUNCTION_NAME, Data]),

    ok;
wait_for_stream_close(stream_finished, _Stream, _TimeoutAttempts, _MaxAttempts) ->
    ct:print("[~p] got an stream_finished", [?FUNCTION_NAME]),
    ok;
wait_for_stream_close(init, Stream, TimeoutAttempts, MaxAttempts) ->
    wait_for_stream_close(
        grpcbox_client:recv_data(Stream, timer:seconds(2)),
        Stream,
        TimeoutAttempts,
        MaxAttempts
    );
wait_for_stream_close(timeout, Stream, TimeoutAttempts, MaxAttempts) ->
    ct:print("waiting for stream to close, attempt ~p/~p", [TimeoutAttempts, MaxAttempts]),
    timer:sleep(250),
    wait_for_stream_close(
        grpcbox_client:recv_data(Stream, timer:seconds(2)),
        Stream,
        TimeoutAttempts + 1,
        MaxAttempts
    ).

-spec update_skf(
    Action :: add | remove,
    SKF :: iot_config_pb:iot_config_session_key_filter_v1_pb(),
    Stream :: grpcbox_client:stream(),
    state()
) -> ok | {error, any()}.
update_skf(Action, SKF, Stream, #state{sig_fun = SigFun}) ->
    Req = #iot_config_session_key_filter_update_req_v1_pb{
        action = Action,
        filter = SKF,
        timestamp = erlang:system_time(millisecond)
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_session_key_filter_update_req_v1_pb),
    SignedReq = Req#iot_config_session_key_filter_update_req_v1_pb{signature = SigFun(EncodedReq)},
    ok = grpcbox_client:send(Stream, SignedReq).

-spec skf_update_failed(Reason :: any(), State :: state()) -> state().
skf_update_failed(Reason, #state{conn_backoff = Backoff0} = State) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    _ = erlang:send_after(Delay, self(), ?INIT),
    lager:warning("fail to update skf ~p, reconnecting in ~wms", [Reason, Delay]),
    State#state{conn_backoff = Backoff1}.

-spec forward_reconcile(
    map(), Result :: {ok, list(), list()} | {error, any()}
) -> ok.
forward_reconcile(#{forward_pid := undefined}, _Result) ->
    ok;
forward_reconcile(#{forward_pid := Pid}, Result) when is_pid(Pid) ->
    catch Pid ! {?MODULE, Result},
    ok.
