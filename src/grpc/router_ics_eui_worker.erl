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
    host :: string(),
    port :: non_neg_integer(),
    conn_backoff :: backoff:backoff(),
    route_id :: undefined | string()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(#{host := ""}) ->
    ignore;
start_link(#{port := Port} = Args) when is_list(Port) ->
    ?MODULE:start_link(Args#{port => erlang:list_to_integer(Port)});
start_link(#{eui_enabled := "true", host := Host, port := Port} = Args) when
    is_list(Host) andalso is_integer(Port)
->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []);
start_link(_Args) ->
    ignore.

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
init(#{pubkey_bin := PubKeyBin, sig_fun := SigFun, host := Host, port := Port} = Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    self() ! ?INIT,
    {ok, #state{
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        host = Host,
        port = Port,
        conn_backoff = Backoff
    }}.

handle_call(_Msg, _From, #state{route_id = undefined} = State) ->
    lager:warning("can't handle call msg: ~p", [_Msg]),
    {reply, ok, State};
handle_call(
    {add, DeviceIDs},
    _From,
    #state{route_id = RouteID} = State
) ->
    lager:info("add ~p", [DeviceIDs]),
    EUIPairs = fetch_device_euis(apis, DeviceIDs, RouteID),
    case maybe_update_euis([{add, EUIPairs}], State) of
        {error, Reason} ->
            {reply, {error, Reason}, update_euis_failed(Reason, State)};
        ok ->
            {reply, ok, State}
    end;
handle_call(
    {remove, DeviceIDs},
    _From,
    #state{route_id = RouteID} = State
) ->
    lager:info("remove ~p", [DeviceIDs]),
    EUIPairs = fetch_device_euis(cache, DeviceIDs, RouteID),
    case maybe_update_euis([{remove, EUIPairs}], State) of
        {error, Reason} ->
            {reply, {error, Reason}, update_euis_failed(Reason, State)};
        ok ->
            {reply, ok, State}
    end;
handle_call(
    {update, DeviceIDs},
    _From,
    #state{route_id = RouteID} = State
) ->
    lager:info("update ~p", [DeviceIDs]),
    CachedEUIPairs = fetch_device_euis(cache, DeviceIDs, RouteID),
    APIEUIPairs = fetch_device_euis(apis, DeviceIDs, RouteID),
    ToRemove = CachedEUIPairs -- APIEUIPairs,
    ToAdd = APIEUIPairs -- CachedEUIPairs,
    case maybe_update_euis([{remove, ToRemove}, {add, ToAdd}], State) of
        {error, Reason} ->
            {reply, {error, Reason}, update_euis_failed(Reason, State)};
        ok ->
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
            _ = erlang:send_after(Delay, self(), ?INIT),
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

handle_info(?INIT, #state{conn_backoff = Backoff0} = State) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    case connect(State) of
        {error, _Reason} ->
            lager:warning("fail to connect ~p, reconnecting in ~wms", [_Reason, Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT),
            {noreply, State#state{conn_backoff = Backoff1}};
        ok ->
            case get_route_id(State) of
                {error, _Reason} ->
                    _ = erlang:send_after(Delay, self(), ?INIT),
                    lager:warning("fail to get_route_id ~p, reconnecting in ~wms", [_Reason, Delay]),
                    {noreply, State#state{conn_backoff = Backoff1}};
                {ok, RouteID} ->
                    lager:info("connected"),
                    {_, Backoff2} = backoff:succeed(Backoff0),
                    ok = ?MODULE:reconcile(undefined, true),
                    {noreply, State#state{
                        conn_backoff = Backoff2, route_id = RouteID
                    }}
            end
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

-spec connect(State :: state()) -> ok | {error, any()}.
connect(#state{host = Host, port = Port} = State) ->
    case grpcbox_channel:pick(?MODULE, stream) of
        {error, _} ->
            case
                grpcbox_client:connect(?MODULE, [{http, Host, Port, []}], #{
                    sync_start => true
                })
            of
                {ok, _Conn} ->
                    connect(State);
                {error, _Reason} = Error ->
                    Error
            end;
        {ok, {_Conn, _Interceptor}} ->
            ok
    end.

-spec get_route_id(state()) -> {ok, string()} | {error, any()}.
get_route_id(#state{sig_fun = SigFun}) ->
    Req = #iot_config_route_list_req_v1_pb{
        oui = router_utils:get_oui(),
        timestamp = erlang:system_time(millisecond)
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_route_list_req_v1_pb),
    SignedReq = Req#iot_config_route_list_req_v1_pb{signature = SigFun(EncodedReq)},
    case helium_iot_config_route_client:list(SignedReq, #{channel => ?MODULE}) of
        {grpc_error, Reason} ->
            {error, Reason};
        {error, _} = Error ->
            Error;
        {ok, #iot_config_route_list_res_v1_pb{routes = []}, _Meta} ->
            {error, no_routes};
        {ok, #iot_config_route_list_res_v1_pb{routes = [Route | _]}, _Meta} ->
            {ok, Route#iot_config_route_v1_pb.id}
    end.

-spec get_euis(Options :: map(), state()) -> {ok, grpcbox_client:stream()} | {error, any()}.
get_euis(Options, #state{sig_fun = SigFun, route_id = RouteID}) ->
    Req = #iot_config_route_get_euis_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond)
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_route_get_euis_req_v1_pb),
    SignedReq = Req#iot_config_route_get_euis_req_v1_pb{signature = SigFun(EncodedReq)},
    helium_iot_config_route_client:get_euis(SignedReq, #{
        channel => ?MODULE,
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
    case
        helium_iot_config_route_client:update_euis(#{
            channel => ?MODULE
        })
    of
        {error, _} = Error ->
            Error;
        {ok, Stream} ->
            lists:foreach(
                fun({Action, EUIPairs}) ->
                    lists:foreach(
                        fun(EUIPair) ->
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
                        EUIPairs
                    )
                end,
                List
            ),
            ok = grpcbox_client:close_send(Stream),
            case grpcbox_client:recv_data(Stream) of
                {ok, #iot_config_route_euis_res_v1_pb{}} -> ok;
                Reason -> {error, Reason}
            end
    end.

-spec update_euis(
    Action :: add | remove,
    EUIPair :: iot_config_pb:iot_config_eui_pair_v1_pb(),
    Stream :: grpcbox_client:stream(),
    state()
) -> ok | {error, any()}.
update_euis(Action, EUIPair, Stream, #state{sig_fun = SigFun}) ->
    Req = #iot_config_route_update_euis_req_v1_pb{
        action = Action,
        eui_pair = EUIPair,
        timestamp = erlang:system_time(millisecond)
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
            {ok,
                lists:map(
                    fun(APIDevice) ->
                        <<AppEUI:64/integer-unsigned-big>> = lorawan_utils:hex_to_binary(
                            kvc:path([<<"app_eui">>], APIDevice)
                        ),
                        <<DevEUI:64/integer-unsigned-big>> = lorawan_utils:hex_to_binary(
                            kvc:path([<<"dev_eui">>], APIDevice)
                        ),
                        #iot_config_eui_pair_v1_pb{
                            route_id = RouteID, app_eui = AppEUI, dev_eui = DevEUI
                        }
                    end,
                    APIDevices
                )}
    end.

-spec update_euis_failed(Reason :: any(), State :: state()) -> state().
update_euis_failed(Reason, #state{conn_backoff = Backoff0} = State) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    _ = erlang:send_after(Delay, self(), ?INIT),
    lager:warning("fail to update euis ~p, reconnecting in ~wms", [Reason, Delay]),
    State#state{
        conn_backoff = Backoff1, route_id = undefined
    }.

-spec fetch_device_euis(apis | cache, DeviceIDs :: list(binary()), RouteID :: string()) ->
    [iot_config_pb:iot_config_eui_pair_v1_pb()].
fetch_device_euis(apis, DeviceIDs, RouteID) ->
    lists:filtermap(
        fun(DeviceID) ->
            case router_console_api:get_device(DeviceID) of
                {error, _} ->
                    false;
                {ok, Device} ->
                    <<AppEUI:64/integer-unsigned-big>> = router_device:app_eui(Device),
                    <<DevEUI:64/integer-unsigned-big>> = router_device:dev_eui(Device),
                    {true, #iot_config_eui_pair_v1_pb{
                        route_id = RouteID, app_eui = AppEUI, dev_eui = DevEUI
                    }}
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
                    <<AppEUI:64/integer-unsigned-big>> = router_device:app_eui(Device),
                    <<DevEUI:64/integer-unsigned-big>> = router_device:dev_eui(Device),
                    {true, #iot_config_eui_pair_v1_pb{
                        route_id = RouteID, app_eui = AppEUI, dev_eui = DevEUI
                    }}
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
