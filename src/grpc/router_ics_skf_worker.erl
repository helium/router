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
    reconcile/0,
    reconcile_end/1,
    updates/1
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
    host :: string(),
    port :: non_neg_integer(),
    conn_backoff :: backoff:backoff()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(#{host := ""}) ->
    ignore;
start_link(#{port := Port} = Args) when is_list(Port) ->
    ?MODULE:start_link(Args#{port => erlang:list_to_integer(Port)});
start_link(#{host := Host, port := Port} = Args) when is_list(Host) andalso is_integer(Port) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []);
start_link(_Args) ->
    ignore.

-spec reconcile() -> ok.
reconcile() ->
    gen_server:cast(?SERVER, ?RECONCILE_START).

-spec reconcile_end(list(iot_config_pb:iot_config_eui_pair_v1_pb())) -> ok.
reconcile_end(List) ->
    gen_server:cast(?SERVER, {?RECONCILE_END, List}).

-spec updates(Updates :: list({add | remove, non_neg_integer(), binary()})) -> ok.
updates(Updates) ->
    gen_server:cast(?SERVER, {?UPDATE, Updates}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{pubkey_bin := PubKeyBin, sig_fun := SigFun, host := Host, port := Port} = Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    self() ! ?INIT,
    {ok, #state{
        oui = router_utils:get_oui(),
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        host = Host,
        port = Port,
        conn_backoff = Backoff
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(?RECONCILE_START, #state{conn_backoff = Backoff0} = State) ->
    case get_skfs(State) of
        {error, _Reason} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?INIT),
            lager:warning("fail to get_euis ~p, retrying in ~wms", [
                _Reason, Delay
            ]),
            {noreply, State#state{conn_backoff = Backoff1}};
        {ok, _Stream} ->
            {_, Backoff2} = backoff:succeed(Backoff0),
            {noreply, State#state{conn_backoff = Backoff2}}
    end;
handle_cast(
    {?RECONCILE_END, SKFs}, #state{oui = OUI} = State
) ->
    LocalSFKs = get_local_skfs(OUI),
    ToAdd = LocalSFKs -- SKFs,
    ToRemove = SKFs -- LocalSFKs,
    case update_skf([{remove, ToRemove}, {add, ToAdd}], State) of
        {error, Reason} ->
            {noreply, update_skf_failed(Reason, State)};
        ok ->
            lager:info("reconciling done"),
            {noreply, State}
    end;
handle_cast(
    {?UPDATE, Updates0}, #state{oui = OUI} = State
) ->
    Updates1 = [
        {Action, #iot_config_session_key_filter_v1_pb{
            oui = OUI,
            devaddr = DevAdrr,
            session_key = Key
        }}
     || {Action, DevAdrr, Key} <- Updates0
    ],
    case update_skf(Updates1, State) of
        {error, Reason} ->
            {noreply, update_skf_failed(Reason, State)};
        ok ->
            lager:info("reconciling done"),
            {noreply, State}
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
            lager:info("connected"),
            {_, Backoff2} = backoff:succeed(Backoff0),
            ok = ?MODULE:reconcile(),
            {noreply, State#state{conn_backoff = Backoff2}}
    end;
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

-spec get_skfs(state()) -> {ok, grpcbox_client:stream()} | {error, any()}.
get_skfs(#state{oui = OUI, pubkey_bin = PubKeyBin, sig_fun = SigFun}) ->
    Req = #iot_config_session_key_filter_list_req_v1_pb{
        oui = OUI,
        timestamp = erlang:system_time(millisecond),
        signer = PubKeyBin
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_session_key_filter_list_req_v1_pb),
    SignedReq = Req#iot_config_session_key_filter_list_req_v1_pb{signature = SigFun(EncodedReq)},
    helium_iot_config_session_key_filter_client:list(SignedReq, #{
        channel => ?MODULE,
        callback_module => {
            router_ics_skf_list_handler,
            []
        }
    }).

-spec get_local_skfs(OUI :: non_neg_integer()) ->
    [iot_config_pb:iot_config_session_key_filter_v1_pb()].
get_local_skfs(OUI) ->
    Devices = router_device_cache:get(),
    lists:map(
        fun(Device) ->
            <<Devaddr:32/integer-unsigned-big>> = router_device:devaddr(Device),
            #iot_config_session_key_filter_v1_pb{
                oui = OUI,
                devaddr = Devaddr,
                session_key = router_device:nwk_s_key(Device)
            }
        end,
        Devices
    ).

-spec update_skf(
    List :: [{add | remove, [iot_config_pb:iot_config_session_key_filter_v1_pb()]}],
    State :: state()
) ->
    ok | {error, any()}.
update_skf(List, State) ->
    case
        helium_iot_config_session_key_filter_client:update(#{
            channel => ?MODULE
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
update_skf(Action, SKF, Stream, #state{pubkey_bin = PubKeyBin, sig_fun = SigFun}) ->
    Req = #iot_config_session_key_filter_update_req_v1_pb{
        action = Action,
        filter = SKF,
        timestamp = erlang:system_time(millisecond),
        signer = PubKeyBin
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_session_key_filter_update_req_v1_pb),
    SignedReq = Req#iot_config_session_key_filter_update_req_v1_pb{signature = SigFun(EncodedReq)},
    ok = grpcbox_client:send(Stream, SignedReq).

-spec update_skf_failed(Reason :: any(), State :: state()) -> state().
update_skf_failed(Reason, #state{conn_backoff = Backoff0} = State) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    _ = erlang:send_after(Delay, self(), ?INIT),
    lager:warning("fail to update euis ~p, reconnecting in ~wms", [Reason, Delay]),
    State#state{conn_backoff = Backoff1}.
