%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_worker).

-behavior(gen_server).

-include("./grpc/autogen/iot_config_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    add/1,
    update/1,
    remove/1
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
-define(CONNECT, connect).
-define(FETCH, fetch).
-define(BACKOFF_MIN, timer:seconds(10)).
-define(BACKOFF_MAX, timer:minutes(1)).

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
start_link(#{host := Host, port := Port} = Args) when is_list(Host) andalso is_integer(Port) ->
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

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(#{pubkey_bin := PubKeyBin, sig_fun := SigFun, host := Host, port := Port} = Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    self() ! ?CONNECT,
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
    EUIPairs = fetch_device_euis(apis, DeviceIDs, RouteID),
    Reply = update_euis([{add, EUIPairs}], State),
    {reply, Reply, State};
handle_call(
    {remove, DeviceIDs},
    _From,
    #state{route_id = RouteID} = State
) ->
    EUIPairs = fetch_device_euis(cache, DeviceIDs, RouteID),
    Reply = update_euis([{remove, EUIPairs}], State),
    {reply, Reply, State};
handle_call(
    {update, DeviceIDs},
    _From,
    #state{route_id = RouteID} = State
) ->
    CachedEUIPairs = fetch_device_euis(cache, DeviceIDs, RouteID),
    APIEUIPairs = fetch_device_euis(apis, DeviceIDs, RouteID),
    ToRemove = CachedEUIPairs -- APIEUIPairs,
    ToAdd = APIEUIPairs -- CachedEUIPairs,
    Reply = update_euis([{remove, ToRemove}, {add, ToAdd}], State),
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?CONNECT, #state{host = Host, port = Port, conn_backoff = Backoff0} = State) ->
    case connect(Host, Port) of
        {error, _Reason} ->
            lager:warning("fail to connect ~p", [_Reason]),
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?CONNECT),
            {noreply, State#state{conn_backoff = Backoff1}};
        ok ->
            {_, Backoff1} = backoff:succeed(Backoff0),
            lager:info("connected"),
            self() ! ?FETCH,
            {noreply, State#state{conn_backoff = Backoff1}}
    end;
handle_info(?FETCH, #state{conn_backoff = Backoff0} = State) ->
    case get_route_id(State) of
        {error, _Reason} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?FETCH),
            lager:warning("fail to get_route_id ~p", [_Reason]),
            {noreply, State#state{conn_backoff = Backoff1}};
        {ok, RouteID} ->
            case get_local_eui_pairs(RouteID) of
                {error, _Reason} ->
                    {Delay, Backoff1} = backoff:fail(Backoff0),
                    _ = erlang:send_after(Delay, self(), ?FETCH),
                    lager:warning("fail to get_route_id ~p", [_Reason]),
                    {noreply, State#state{conn_backoff = Backoff1}};
                {ok, EUIPairs} ->
                    ok = delete_euis(RouteID, State),
                    ok = update_euis([{add, EUIPairs}], State),
                    {noreply, State#state{route_id = RouteID}}
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
handle_info({'DOWN', _Ref, process, Pid, normal}, State) ->
    lager:debug("got DOWN for Pid: ~p", [Pid]),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec connect(Host :: string(), Port :: non_neg_integer()) -> ok | {error, any()}.
connect(Host, Port) ->
    case grpcbox_channel:pick(?MODULE, stream) of
        {error, _} ->
            case
                grpcbox_client:connect(?MODULE, [{http, Host, Port, []}], #{
                    sync_start => true
                })
            of
                {ok, _Conn} -> connect(Host, Port);
                {error, _Reason} = Error -> Error
            end;
        {ok, {_Conn, _Interceptor}} ->
            ok
    end.

-spec get_route_id(state()) -> {ok, string()} | {error, any()}.
get_route_id(#state{pubkey_bin = PubKeyBin, sig_fun = SigFun}) ->
    Req = #iot_config_route_list_req_v1_pb{
        oui = router_utils:get_oui(),
        timestamp = erlang:system_time(millisecond),
        signer = PubKeyBin
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

-spec delete_euis(RouteID :: string(), state()) -> ok | {error, any()}.
delete_euis(RouteID, #state{pubkey_bin = PubKeyBin, sig_fun = SigFun}) ->
    Req = #iot_config_route_delete_euis_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond),
        signer = PubKeyBin
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_route_delete_euis_req_v1_pb),
    SignedReq = Req#iot_config_route_delete_euis_req_v1_pb{signature = SigFun(EncodedReq)},
    case helium_iot_config_route_client:delete_euis(SignedReq, #{channel => ?MODULE}) of
        {grpc_error, Reason} -> {error, Reason};
        {error, _} = Error -> Error;
        {ok, #iot_config_route_euis_res_v1_pb{}, _Meta} -> ok
    end.

-spec update_euis(
    List :: [{add | remove, [iot_config_pb:iot_config_eui_pair_v1_pb()]}],
    State :: state()
) ->
    ok | {error, any()}.
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
                            lager:info("~p ~p", [Action, EUIPair]),
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
