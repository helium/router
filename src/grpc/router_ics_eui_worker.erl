%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_eui_worker).

-behavior(gen_server).

-include("./autogen/iot_config_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    add/1,
    update/1,
    remove/1,
    reconcile/2,
    reconcile_end/2
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

-ifdef(TEST).
-define(BACKOFF_MIN, 100).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: function(),
    conn_backoff :: backoff:backoff(),
    route_id :: undefined | string()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    case Args of
        #{eui_enabled := "true"} = Map ->
            case maps:get(route_id, Map, "") of
                "" ->
                    lager:warning("~p enabled, but not route_id provided, ignoring", [?MODULE]),
                    ignore;
                _ ->
                    gen_server:start_link({local, ?SERVER}, ?SERVER, Map, [])
            end;
        _ ->
            lager:warning("~s ignored ~p", [?MODULE, Args]),
            ignore
    end.

-spec add(list(binary())) -> ok | {error, any()}.
add(DeviceIDs) ->
    gen_server:call(?SERVER, {add, DeviceIDs}).

-spec update(list(binary())) -> ok | {error, any()}.
update(DeviceIDs) ->
    gen_server:call(?SERVER, {update, DeviceIDs}).

-spec remove(list(binary())) -> ok | {error, any()}.
remove(DeviceIDs) ->
    gen_server:call(?SERVER, {remove, DeviceIDs}).

-spec reconcile(Pid :: pid() | undefined, Commit :: boolean()) -> ok.
reconcile(Pid, Commit) ->
    gen_server:cast(?SERVER, {?RECONCILE_START, #{forward_pid => Pid, commit => Commit}}).

-spec reconcile_end(Options :: map(), list(iot_config_pb:iot_config_eui_pair_v1_pb())) ->
    ok.
reconcile_end(Options, List) ->
    gen_server:cast(?SERVER, {?RECONCILE_END, Options, List}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(
    #{
        pubkey_bin := PubKeyBin,
        sig_fun := SigFun,
        route_id := RouteID
    } = Args
) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    ok = ?MODULE:reconcile(undefined, true),
    {ok, #state{
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        conn_backoff = Backoff,
        route_id = RouteID
    }}.

handle_call(
    {add, DeviceIDs},
    _From,
    #state{route_id = RouteID} = State
) ->
    lager:info("add ~p", [DeviceIDs]),
    {AddedDeviceIDs, EUIPairs} = lists:unzip(fetch_device_euis(apis, DeviceIDs, RouteID)),
    case maybe_update_euis([{add, EUIPairs}], State) of
        {error, Reason} ->
            {reply, {error, Reason}, update_euis_failed(Reason, State)};
        ok ->
            ok = router_console_api:xor_filter_updates(AddedDeviceIDs, []),
            {reply, ok, State}
    end;
handle_call(
    {remove, DeviceIDs},
    _From,
    #state{route_id = RouteID} = State
) ->
    lager:info("remove ~p", [DeviceIDs]),
    {RemovedDeviceIDs, EUIPairs} = lists:unzip(fetch_device_euis(cache, DeviceIDs, RouteID)),
    case maybe_update_euis([{remove, EUIPairs}], State) of
        {error, Reason} ->
            {reply, {error, Reason}, update_euis_failed(Reason, State)};
        ok ->
            ok = router_console_api:xor_filter_updates([], RemovedDeviceIDs),
            {reply, ok, State}
    end;
handle_call(
    {update, DeviceIDs},
    _From,
    #state{route_id = RouteID} = State
) ->
    lager:info("update ~p", [DeviceIDs]),
    CachedDevicesEUIPairs = fetch_device_euis(cache, DeviceIDs, RouteID),
    APIDevicesEUIPairs = fetch_device_euis(apis, DeviceIDs, RouteID),
    {ToRemoveIDs, ToRemoveEUIPairs} = lists:unzip(CachedDevicesEUIPairs -- APIDevicesEUIPairs),
    {ToAddIDs, ToAddEUIPairs} = lists:unzip(APIDevicesEUIPairs -- CachedDevicesEUIPairs),

    case maybe_update_euis([{remove, ToRemoveEUIPairs}, {add, ToAddEUIPairs}], State) of
        {error, Reason} ->
            {reply, {error, Reason}, update_euis_failed(Reason, State)};
        ok ->
            ok = router_console_api:xor_filter_updates(ToAddIDs, ToRemoveIDs),
            {reply, ok, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({?RECONCILE_START, Options}, #state{conn_backoff = Backoff0} = State) ->
    lager:info("reconciling started with: ~p", [Options]),
    case get_euis(Options, State) of
        {error, _Reason} = Error ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = timer:apply_after(Delay, ?MODULE, reconcile, [undefined, true]),
            lager:warning("fail to get_euis ~p, retrying in ~wms", [
                _Reason, Delay
            ]),
            ok = forward_reconcile(Options, Error),
            {noreply, State#state{conn_backoff = Backoff1}};
        {ok, _Stream} ->
            {_, Backoff2} = backoff:succeed(Backoff0),
            {noreply, State#state{conn_backoff = Backoff2}}
    end;
handle_cast(
    {?RECONCILE_END, #{forward_pid := Pid, commit := false} = Options, EUIPairs},
    #state{route_id = RouteID} = State
) when is_pid(Pid) ->
    lager:info("DRY RUN, got RECONCILE_END  ~p, with ~w", [Options, erlang:length(EUIPairs)]),
    case get_local_eui_pairs(RouteID) of
        {error, _Reason} = Error ->
            ok = forward_reconcile(Options, Error),
            lager:warning("fail to get local pairs ~p", [_Reason]),
            {noreply, State};
        {ok, LocalEUIPairs} ->
            ToAdd = LocalEUIPairs -- EUIPairs,
            ToRemove = EUIPairs -- LocalEUIPairs,
            ok = forward_reconcile(
                Options, {ok, ToAdd, ToRemove}
            ),
            lager:info("DRY RUN, reconciling done adding ~w removing ~w", [
                erlang:length(ToAdd), erlang:length(ToRemove)
            ]),
            {noreply, State}
    end;
handle_cast(
    {?RECONCILE_END, #{forward_pid := Pid, commit := true} = Options, EUIPairs},
    #state{route_id = RouteID} = State
) when is_pid(Pid) ->
    lager:info("got RECONCILE_END  ~p, with ~w", [Options, erlang:length(EUIPairs)]),
    case get_local_eui_pairs(RouteID) of
        {error, _Reason} = Error ->
            ok = forward_reconcile(Options, Error),
            lager:warning("fail to get local pairs ~p", [_Reason]),
            {noreply, State};
        {ok, LocalEUIPairs} ->
            ToAdd = LocalEUIPairs -- EUIPairs,
            ToRemove = EUIPairs -- LocalEUIPairs,
            case maybe_update_euis([{remove, ToRemove}, {add, ToAdd}], State) of
                {error, Reason} = Error ->
                    ok = forward_reconcile(Options, Error),
                    {noreply, update_euis_failed(Reason, State)};
                ok ->
                    ok = forward_reconcile(
                        Options, {ok, ToAdd, ToRemove}
                    ),
                    lager:info("reconciling done adding ~w removing ~w", [
                        erlang:length(ToAdd), erlang:length(ToRemove)
                    ]),
                    {noreply, State}
            end
    end;
handle_cast(
    {?RECONCILE_END, #{forward_pid := undefined, commit := true} = Options, EUIPairs},
    #state{conn_backoff = Backoff0, route_id = RouteID} = State
) ->
    lager:info("got RECONCILE_END  ~p, with ~w", [Options, erlang:length(EUIPairs)]),
    case get_local_eui_pairs(RouteID) of
        {error, _Reason} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:spawn(fun() ->
                timer:sleep(Delay),
                ok = ?MODULE:reconcile(undefined, true)
            end),
            lager:warning("fail to get local pairs ~p, retrying in ~wms", [_Reason, Delay]),
            {noreply, State#state{conn_backoff = Backoff1}};
        {ok, LocalEUIPairs} ->
            ToAdd = LocalEUIPairs -- EUIPairs,
            ToRemove = EUIPairs -- LocalEUIPairs,
            case maybe_update_euis([{remove, ToRemove}, {add, ToAdd}], State) of
                {error, Reason} ->
                    {noreply, update_euis_failed(Reason, State)};
                ok ->
                    lager:info("reconciling done adding ~w removing ~w", [
                        erlang:length(ToAdd), erlang:length(ToRemove)
                    ]),
                    {noreply, State}
            end
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

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

-spec get_euis(Options :: map(), state()) -> {ok, grpcbox_client:stream()} | {error, any()}.
get_euis(Options, #state{pubkey_bin = PubKeyBin, sig_fun = SigFun, route_id = RouteID}) ->
    Req = #iot_config_route_get_euis_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond),
        signer = PubKeyBin
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_route_get_euis_req_v1_pb),
    SignedReq = Req#iot_config_route_get_euis_req_v1_pb{signature = SigFun(EncodedReq)},
    helium_iot_config_route_client:get_euis(SignedReq, #{
        channel => router_ics_utils:channel(),
        callback_module => {
            router_ics_route_get_euis_handler,
            Options
        }
    }).

-spec maybe_update_euis(
    List :: [{add | remove, [iot_config_pb:iot_config_eui_pair_v1_pb()]}],
    State :: state()
) ->
    ok | {error, any()}.
maybe_update_euis(List0, State) ->
    List1 = lists:filter(
        fun
            ({_Action, []}) -> false;
            ({_Action, _L}) -> true
        end,
        List0
    ),
    update_euis(List1, State).

-spec update_euis(
    List :: [{add | remove, [iot_config_pb:iot_config_eui_pair_v1_pb()]}],
    State :: state()
) ->
    ok | {error, any()}.
update_euis([], _State) ->
    ok;
update_euis(List, State) ->
    BatchSleep = router_utils:get_env_int(config_service_batch_sleep_ms, 500),
    MaxAttempt = router_utils:get_env_int(config_service_max_timeout_attempt, 5),

    case
        helium_iot_config_route_client:update_euis(#{
            channel => router_ics_utils:channel()
        })
    of
        {error, _} = Error ->
            Error;
        {ok, Stream} ->
            router_ics_utils:batch_update(
                fun(Action, EUIPair) ->
                    lager:info("~p app_eui=~s (~w) dev_eui=~s (~w)", [
                        Action,
                        lorawan_utils:binary_to_hex(<<
                            (EUIPair#iot_config_eui_pair_v1_pb.app_eui):64/integer-unsigned-big
                        >>),
                        EUIPair#iot_config_eui_pair_v1_pb.app_eui,
                        lorawan_utils:binary_to_hex(<<
                            (EUIPair#iot_config_eui_pair_v1_pb.dev_eui):64/integer-unsigned-big
                        >>),
                        EUIPair#iot_config_eui_pair_v1_pb.dev_eui
                    ]),

                    ok = update_euis(Action, EUIPair, Stream, State)
                end,
                List,
                BatchSleep
            ),

            ok = grpcbox_client:close_send(Stream),
            lager:info("done sending eui updates [timeout_retry: ~p]", [MaxAttempt]),
            wait_for_stream_close(init, Stream, 0, MaxAttempt)
    end.

-spec wait_for_stream_close(
    Result :: init | stream_finished | timeout | {ok, any()} | {error, any()},
    Stream :: map(),
    CurrentAttempts :: non_neg_integer(),
    MaxAttempts :: non_neg_integer()
) -> ok | {error, any()}.
wait_for_stream_close(_, _, MaxAttempts, MaxAttempts) ->
    {error, {max_timeouts_reached, MaxAttempts}};
wait_for_stream_close({error, Reason, Extra}, _Stream, _TimeoutAttempts, _MaxAttempts) ->
    {error, {Reason, Extra}};
wait_for_stream_close({error, _} = Err, _Stream, _TimeoutAttempts, _MaxAttempts) ->
    Err;
wait_for_stream_close({ok, _}, _Stream, _TimeoutAttempts, _MaxAttempts) ->
    ok;
wait_for_stream_close(stream_finished, _Stream, _TimeoutAttempts, _MaxAttempts) ->
    ok;
wait_for_stream_close(init, Stream, TimeoutAttempts, MaxAttempts) ->
    wait_for_stream_close(
        grpcbox_client:recv_data(Stream, timer:seconds(2)),
        Stream,
        TimeoutAttempts,
        MaxAttempts
    );
wait_for_stream_close(timeout, Stream, TimeoutAttempts, MaxAttempts) ->
    timer:sleep(250),
    wait_for_stream_close(
        grpcbox_client:recv_data(Stream, timer:seconds(2)),
        Stream,
        TimeoutAttempts + 1,
        MaxAttempts
    ).

-spec update_euis(
    Action :: add | remove,
    EUIPair :: iot_config_pb:iot_config_eui_pair_v1_pb(),
    Stream :: grpcbox_client:stream(),
    state()
) -> ok | {error, any()}.
update_euis(Action, EUIPair, Stream, #state{pubkey_bin = PubKeyBin, sig_fun = SigFun}) ->
    Req = #iot_config_route_update_euis_req_v1_pb{
        action = Action,
        eui_pair = EUIPair,
        timestamp = erlang:system_time(millisecond),
        signer = PubKeyBin
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_route_update_euis_req_v1_pb),
    SignedReq = Req#iot_config_route_update_euis_req_v1_pb{signature = SigFun(EncodedReq)},
    ok = grpcbox_client:send(Stream, SignedReq).

-spec get_local_eui_pairs(RouteID :: string()) ->
    {ok, [iot_config_pb:iot_config_eui_pair_v1_pb()]} | {error, any()}.
get_local_eui_pairs(RouteID) ->
    case router_console_api:get_json_devices() of
        {error, _} = Error ->
            Error;
        {ok, APIDevices} ->
            UnfundedOrgs = router_console_dc_tracker:list_unfunded(),
            {ok,
                lists:usort(
                    lists:filtermap(
                        fun(APIDevice) ->
                            OrgId = kvc:path([<<"organization_id">>], APIDevice),

                            case lists:member(OrgId, UnfundedOrgs) of
                                true ->
                                    false;
                                false ->
                                    <<AppEUI:64/integer-unsigned-big>> = lorawan_utils:hex_to_binary(
                                        kvc:path([<<"app_eui">>], APIDevice)
                                    ),
                                    <<DevEUI:64/integer-unsigned-big>> = lorawan_utils:hex_to_binary(
                                        kvc:path([<<"dev_eui">>], APIDevice)
                                    ),
                                    {true, #iot_config_eui_pair_v1_pb{
                                        route_id = RouteID, app_eui = AppEUI, dev_eui = DevEUI
                                    }}
                            end
                        end,
                        APIDevices
                    )
                )}
    end.

-spec update_euis_failed(Reason :: any(), State :: state()) -> state().
update_euis_failed(Reason, #state{conn_backoff = Backoff0} = State) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    timer:apply_after(Delay, ?MODULE, reconcile, [undefined, true]),
    lager:warning("fail to update euis ~p, reconnecting in ~wms", [Reason, Delay]),
    State#state{
        conn_backoff = Backoff1
    }.

-spec fetch_device_euis(apis | cache, DeviceIDs :: list(binary()), RouteID :: string()) ->
    [{DeviceID :: binary(), iot_config_pb:iot_config_eui_pair_v1_pb()}].
fetch_device_euis(apis, DeviceIDs, RouteID) ->
    UnfundedOrgs = router_console_dc_tracker:list_unfunded(),
    lists:filtermap(
        fun(DeviceID) ->
            case router_console_api:get_device(DeviceID) of
                {error, _} ->
                    false;
                {ok, Device} ->
                    OrgId = maps:get(organization_id, router_device:metadata(Device), undefined),
                    case
                        router_device:is_active(Device) andalso
                            not lists:member(OrgId, UnfundedOrgs)
                    of
                        false ->
                            false;
                        true ->
                            <<AppEUI:64/integer-unsigned-big>> = router_device:app_eui(Device),
                            <<DevEUI:64/integer-unsigned-big>> = router_device:dev_eui(Device),
                            {true,
                                {DeviceID, #iot_config_eui_pair_v1_pb{
                                    route_id = RouteID, app_eui = AppEUI, dev_eui = DevEUI
                                }}}
                    end
            end
        end,
        DeviceIDs
    );
fetch_device_euis(cache, DeviceIDs, RouteID) ->
    lists:filtermap(
        fun(DeviceID) ->
            case router_device_cache:get(DeviceID) of
                {error, _} ->
                    false;
                {ok, Device} ->
                    case router_device:is_active(Device) of
                        false ->
                            false;
                        true ->
                            <<AppEUI:64/integer-unsigned-big>> = router_device:app_eui(Device),
                            <<DevEUI:64/integer-unsigned-big>> = router_device:dev_eui(Device),
                            {true,
                                {DeviceID, #iot_config_eui_pair_v1_pb{
                                    route_id = RouteID, app_eui = AppEUI, dev_eui = DevEUI
                                }}}
                    end
            end
        end,
        DeviceIDs
    ).

-spec forward_reconcile(
    map(), Result :: {ok, list(), list()} | {error, any()}
) -> ok.
forward_reconcile(#{forward_pid := undefined}, _Result) ->
    ok;
forward_reconcile(#{forward_pid := Pid}, Result) when is_pid(Pid) ->
    catch Pid ! {?MODULE, Result},
    ok.
