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
    reconcile/1,
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
    conn_backoff :: backoff:backoff()
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

-spec reconcile(Pid :: pid() | undefined) -> ok.
reconcile(Pid) ->
    gen_server:cast(?SERVER, {?RECONCILE_START, Pid}).

-spec reconcile_end(
    Pid :: pid() | undefined,
    List :: list(iot_config_pb:iot_config_session_key_filter_v1_pb())
) -> ok.
reconcile_end(Pid, List) ->
    gen_server:cast(?SERVER, {?RECONCILE_END, Pid, List}).

-spec update(Updates :: list({add | remove, non_neg_integer(), binary()})) -> ok.
update(Updates) ->
    gen_server:cast(?SERVER, {?UPDATE, Updates}).

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
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    self() ! ?INIT,
    {ok, #state{
        oui = router_utils:get_oui(),
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        transport = Transport,
        host = Host,
        port = Port,
        conn_backoff = Backoff
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({?RECONCILE_START, Pid}, #state{conn_backoff = Backoff0} = State) ->
    lager:info("reconciling started pid: ~p", [Pid]),
    case skf_list(Pid, State) of
        {error, _Reason} = Error ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?INIT),
            lager:warning("fail to skf_list ~p, retrying in ~wms", [
                _Reason, Delay
            ]),
            ok = forward_reconcile(Pid, Error),
            {noreply, State#state{conn_backoff = Backoff1}};
        {ok, _Stream} ->
            {_, Backoff2} = backoff:succeed(Backoff0),
            {noreply, State#state{conn_backoff = Backoff2}}
    end;
handle_cast(
    {?RECONCILE_END, Pid, SKFs}, #state{oui = OUI} = State
) ->
    LocalSFKs = get_local_skfs(OUI),
    ToAdd = LocalSFKs -- SKFs,
    ToRemove = SKFs -- LocalSFKs,
    lager:info("adding ~w", [erlang:length(ToAdd)]),
    lager:info("removing ~w", [erlang:length(ToRemove)]),
    case maybe_update_skf([{remove, ToRemove}, {add, ToAdd}], State) of
        {error, Reason} = Error ->
            ok = forward_reconcile(Pid, Error),
            {noreply, skf_update_failed(Reason, State)};
        ok ->
            ok = forward_reconcile(Pid, {ok, erlang:length(ToAdd), erlang:length(ToRemove)}),
            lager:info("reconciling done"),
            {noreply, State}
    end;
handle_cast(
    {?UPDATE, Updates0}, #state{oui = OUI} = State
) ->
    Updates1 = maps:to_list(
        lists:foldl(
            fun({Action, DevAdrr, Key}, Acc) ->
                Tail = maps:get(Action, Acc, []),
                SKF = #iot_config_session_key_filter_v1_pb{
                    oui = OUI,
                    devaddr = DevAdrr,
                    session_key = Key
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
        conn_backoff = Backoff0
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
            ok = ?MODULE:reconcile(undefined),
            {noreply, State}
    end;
handle_info({headers, _StreamID, _Data}, State) ->
    lager:debug("got headers for stream: ~p, ~p", [_StreamID, _Data]),
    {noreply, State};
handle_info({trailers, _StreamID, _Data}, State) ->
    lager:debug("got trailers for stream: ~p, ~p", [_StreamID, _Data]),
    {noreply, State};
handle_info({eos, _StreamID}, State) ->
    lager:debug("got eos for stream: ~p", [_StreamID]),
    {noreply, State};
handle_info({'END_STREAM', _StreamID}, State) ->
    lager:debug("got END_STREAM for stream: ~p", [_StreamID]),
    {noreply, State};
handle_info({'DOWN', _Ref, Type, Pid, Reason}, State) ->
    lager:debug("got DOWN for ~p: ~p ~p", [Type, Pid, Reason]),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec skf_list(Pid :: pid() | undefined, state()) -> {ok, grpcbox_client:stream()} | {error, any()}.
skf_list(Pid, #state{oui = OUI, sig_fun = SigFun}) ->
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
            Pid
        }
    }).

-spec get_local_skfs(OUI :: non_neg_integer()) ->
    [iot_config_pb:iot_config_session_key_filter_v1_pb()].
get_local_skfs(OUI) ->
    Devices = router_device_cache:get(),
    lists:filtermap(
        fun(Device) ->
            case {router_device:devaddr(Device), router_device:nwk_s_key(Device)} of
                {undefined, _} ->
                    false;
                {_, undefined} ->
                    false;
                {<<DevAddr:32/integer-unsigned-big>>, SessionKey} ->
                    {true, #iot_config_session_key_filter_v1_pb{
                        oui = OUI,
                        devaddr = DevAddr,
                        session_key = SessionKey
                    }}
            end
        end,
        Devices
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
    case
        helium_iot_config_session_key_filter_client:update(#{
            channel => router_ics_utils:channel()
        })
    of
        {error, _} = Error ->
            Error;
        {ok, Stream} ->
            lists:foreach(
                fun({Action, SKFs}) ->
                    lists:foreach(
                        fun(SKF) ->
                            lager:info("~p ~p", [Action, SKF]),
                            ok = update_skf(Action, SKF, Stream, State)
                        end,
                        SKFs
                    )
                end,
                List
            ),
            ok = grpcbox_client:close_send(Stream),
            case grpcbox_client:recv_data(Stream) of
                {ok, #iot_config_session_key_filter_update_res_v1_pb{}} -> ok;
                Reason -> {error, Reason}
            end
    end.

-spec update_skf(
    Action :: add | remove,
    EUIPair :: iot_config_pb:iot_config_session_key_filter_v1_pb(),
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
    Pid :: pid() | undefined, Result :: {ok, non_neg_integer(), non_neg_integer()} | {error, any()}
) -> ok.
forward_reconcile(undefined, _Result) ->
    ok;
forward_reconcile(Pid, Result) ->
    catch Pid ! {?MODULE, Result},
    ok.
