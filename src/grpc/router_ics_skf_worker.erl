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
    send_deferred_updates/0,
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
-define(SEND_DEFERRED_UPDATES, send_deferred_updates).

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
    reconcile_on_connect = true :: boolean(),
    deferred_updates = [] :: list(skf_update())
}).

-type state() :: #state{}.
-type session_key_filter() :: iot_config_pb:iot_config_session_key_filter_v1_pb().
-type skf_update() :: {add | remove, non_neg_integer(), binary()}.

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
    List :: list(session_key_filter())
) -> ok.
reconcile_end(Options, List) ->
    gen_server:cast(?SERVER, {?RECONCILE_END, Options, List}).

-spec update(Updates :: list(skf_update())) ->
    ok.
update(Updates) ->
    gen_server:cast(?SERVER, {?UPDATE, Updates}).

-spec send_deferred_updates() -> ok.
send_deferred_updates() ->
    gen_server:cast(?SERVER, ?SEND_DEFERRED_UPDATES).

-ifdef(TEST).

-spec list_skf() -> {ok, list(session_key_filter())} | {error, any()}.
list_skf() ->
    gen_server:call(?SERVER, list_skf, infinity).

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
    lager:info("reconciling started pid: ~p", [Options]),
    case skf_list(Options, State) of
        {error, _Reason} = Error ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?INIT),
            lager:warning("fail to skf_list ~p, retrying in ~wms", [
                _Reason, Delay
            ]),
            ok = forward_reconcile(Options, Error),
            {noreply, State#state{conn_backoff = Backoff1}};
        {ok, _Stream} ->
            {_, Backoff2} = backoff:succeed(Backoff0),
            {noreply, State#state{conn_backoff = Backoff2, reconciling = true}}
    end;
handle_cast(
    {?RECONCILE_END, #{type := listing_skf, reply_pid := From} = Options, SKFs},
    #state{} = State
) ->
    Reply =
        case maps:get(error, Options, undefined) of
            undefined -> {ok, SKFs};
            Err -> Err
        end,
    ok = gen_server:reply(From, Reply),
    {noreply, State};
handle_cast(
    {?RECONCILE_END, #{error := Error} = Options, _SKFs},
    #state{} = State0
) ->
    ok = forward_reconcile(Options, Error),
    State1 = maybe_schedule_reconnect(Options, State0),
    {noreply, done_reconciling(State1)};
handle_cast(
    {?RECONCILE_END, #{commit := false} = Options, SKFs},
    #state{oui = OUI} = State
) ->
    lager:info("DRY RUN, got RECONCILE_END ~p, with ~w", [Options, erlang:length(SKFs)]),
    {ToAdd, ToRemove} = local_skf_to_remote_diff(OUI, SKFs),
    ok = forward_reconcile(Options, {ok, ToAdd, ToRemove}),
    lager:info(
        "DRY RUN, reconciling done adding ~w removing ~w",
        [erlang:length(ToAdd), erlang:length(ToRemove)]
    ),
    {noreply, done_reconciling(State)};
handle_cast(
    {?RECONCILE_END, #{commit := true} = Options, SKFs},
    #state{oui = OUI} = State
) ->
    lager:info("got RECONCILE_END ~p, with ~w", [Options, erlang:length(SKFs)]),
    {ToAdd, ToRemove} = local_skf_to_remote_diff(OUI, SKFs),
    AddCount = erlang:length(ToAdd),
    RemCount = erlang:length(ToRemove),
    lager:info("diff with local adding ~w removing ~w", [AddCount, RemCount]),
    case maybe_update_skf([{remove, ToRemove}, {add, ToAdd}], State) of
        {error, _Reason} = Error ->
            ok = forward_reconcile(Options, Error),
            State1 = maybe_schedule_reconnect(Options#{error => Error}, State),
            {noreply, done_reconciling(State1)};
        ok ->
            ok = forward_reconcile(Options, {ok, ToAdd, ToRemove}),
            lager:info("reconciling done added ~w removed ~w", [AddCount, RemCount]),
            {noreply, done_reconciling(State)}
    end;
handle_cast(
    {?UPDATE, Updates}, #state{reconciling = true, deferred_updates = DeferredUpdates} = State
) ->
    %% Defer updates while we reconcile
    {noreply, State#state{deferred_updates = [Updates | DeferredUpdates]}};
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
            {noreply, update_skf_failed(Reason, State)};
        ok ->
            lager:info("update done"),
            {noreply, State}
    end;
handle_cast(?SEND_DEFERRED_UPDATES, #state{deferred_updates = DeferredUpdates} = State) ->
    ok = ?MODULE:update(DeferredUpdates),
    {noreply, State#state{deferred_updates = []}};
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
    case router_ics_utils:connect(Transport, Host, Port) of
        {error, _Reason} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            lager:warning("fail to connect ~p, reconnecting in ~wms", [_Reason, Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT),
            {noreply, State#state{conn_backoff = Backoff1}};
        ok ->
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
    lager:error("terminating: ~p", [_Reason]),
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
    SKFList :: list(session_key_filter()).
local_skf_to_remote_diff(OUI, RemoteSKFs) ->
    Local = get_local_skfs(OUI),

    Add = Local -- RemoteSKFs,
    Remove = RemoteSKFs -- Local,

    {Add, Remove}.

-spec get_local_skfs(OUI :: non_neg_integer()) -> list(session_key_filter()).
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
    List :: [{add | remove, list(session_key_filter())}],
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
    List :: [{add | remove, list(session_key_filter())}],
    State :: state()
) ->
    ok | {error, any()}.
update_skf([], _State) ->
    ok;
update_skf(List, State) ->
    case
        helium_iot_config_session_key_filter_client:update(#{
            channel => router_ics_utils:channel()
        })
    of
        {error, _} = Error ->
            Error;
        {ok, Stream} ->
            router_ics_utils:batch_update(
                fun(Action, SKF) ->
                    %% lager:info("~p ~p", [Action, SKF]),
                    ok = update_skf(Action, SKF, Stream, State)
                end,
                List
            ),

            ok = grpcbox_client:close_send(Stream),
            router_ics_utils:wait_for_stream_close(?MODULE, Stream)
    end.

-spec update_skf(
    Action :: add | remove,
    SKF :: session_key_filter(),
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

-spec update_skf_failed(Reason :: any(), State :: state()) -> state().
update_skf_failed(Reason, #state{conn_backoff = Backoff0} = State) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    _ = erlang:send_after(Delay, self(), ?INIT),
    lager:warning("fail to update skf ~p, reconnecting in ~wms", [Reason, Delay]),
    State#state{conn_backoff = Backoff1}.

-spec forward_reconcile(map(), Result :: {ok, list(), list()} | {error, any()}) -> ok.
forward_reconcile(#{forward_pid := undefined}, _Result) ->
    ok;
forward_reconcile(#{forward_pid := Pid}, Result) when is_pid(Pid) ->
    catch Pid ! {?MODULE, Result},
    ok.

-spec maybe_schedule_reconnect(Options :: map(), State :: #state{}) -> #state{}.
maybe_schedule_reconnect(
    #{error := Error, forward_pid := Pid, commit := Commit} = _Options,
    #state{} = State
) ->
    lager:warning("[dry_run: ~p] reconciling error: ~p", [Commit, Error]),

    case erlang:is_pid(Pid) of
        false ->
            %% undefined PID is internal reconcile, trigger retry after backoff
            update_skf_failed(Error, State);
        true ->
            State
    end.

-spec done_reconciling(#state{}) -> #state{}.
done_reconciling(#state{} = State) ->
    ok = ?MODULE:send_deferred_updates(),
    State#state{reconciling = false}.
