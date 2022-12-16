%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_worker).

-behavior(gen_server).

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
-define(REFETCH, refetch).
-define(BACKOFF_MIN, timer:seconds(10)).
-define(BACKOFF_MAX, timer:minutes(1)).

-record(state, {
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: function(),
    host :: string(),
    port :: non_neg_integer(),
    conn :: undefined | grpc_client:connection(),
    conn_backoff :: backoff:backoff(),
    route_id :: undefined | string()
}).

-type state() :: state().

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(#{port := Port} = Args) when is_list(Port) ->
    ?MODULE:start_link(Args#{port => erlang:list_to_integer(Port)});
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec add(list(binary())) -> ok.
add(DeviceIDs) ->
    gen_server:cast(?SERVER, {add, DeviceIDs}).

-spec update(list(binary())) -> ok.
update(DeviceIDs) ->
    gen_server:cast(?SERVER, {update, DeviceIDs}).

-spec remove(list(binary())) -> ok.
remove(DeviceIDs) ->
    gen_server:cast(?SERVER, {remove, DeviceIDs}).

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

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, #state{conn = undefined} = State) ->
    lager:warning("can't handle cast msg: ~p", [_Msg]),
    {noreply, State};
handle_cast(_Msg, #state{route_id = undefined} = State) ->
    lager:warning("can't handle cast msg: ~p", [_Msg]),
    {noreply, State};
handle_cast(
    {add, DeviceIDs},
    #state{pubkey_bin = PubKeyBin, sig_fun = SigFun, conn = Conn, route_id = RouteID} = State
) ->
    Euis = fetch_device_euis(apis, DeviceIDs),
    add_euis = euis_req(Conn, PubKeyBin, SigFun, RouteID, add_euis, Euis),
    {noreply, State};
handle_cast(
    {update, DeviceIDs},
    #state{pubkey_bin = PubKeyBin, sig_fun = SigFun, conn = Conn, route_id = RouteID} = State
) ->
    CachedEuis = fetch_device_euis(cache, DeviceIDs),
    APIEuis = fetch_device_euis(apis, DeviceIDs),
    remove_euis = euis_req(Conn, PubKeyBin, SigFun, RouteID, remove_euis, CachedEuis -- APIEuis),
    add_euis = euis_req(Conn, PubKeyBin, SigFun, RouteID, add_euis, APIEuis -- CachedEuis),
    {noreply, State};
handle_cast(
    {remove, DeviceIDs},
    #state{pubkey_bin = PubKeyBin, sig_fun = SigFun, conn = Conn, route_id = RouteID} = State
) ->
    Euis = fetch_device_euis(cache, DeviceIDs),
    remove_euis = euis_req(Conn, PubKeyBin, SigFun, RouteID, remove_euis, Euis),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?CONNECT, #state{host = Host, port = Port, conn_backoff = Backoff0} = State) ->
    case grpc_client:connect(tcp, Host, Port, []) of
        {ok, Conn} ->
            #{http_connection := Pid} = Conn,
            _ = erlang:monitor(process, Pid),
            {_, Backoff1} = backoff:succeed(Backoff0),
            self() ! ?REFETCH,
            {noreply, State#state{conn = Conn, conn_backoff = Backoff1}};
        {error, _Reason} ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?CONNECT),
            {noreply, State#state{conn = undefined, conn_backoff = Backoff1}}
    end;
handle_info(?REFETCH, State) ->
    {ok, RouteID} = refetch(State),
    {noreply, State#state{route_id = RouteID}};
handle_info({'DOWN', _MonitorRef, process, _Pid, Info}, State) ->
    lager:info("connection went down ~p", [Info]),
    self() ! ?CONNECT,
    {noreply, State#state{conn = undefined}};
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

-spec fetch_device_euis(apis | cache, list(binary())) -> [map()].
fetch_device_euis(apis, DeviceIDs) ->
    lists:filtermap(
        fun(DeviceID) ->
            case router_console_api:get_device(DeviceID) of
                {error, _} ->
                    false;
                {ok, Device} ->
                    <<AppEUI:64/integer-unsigned-big>> = router_device:app_eui(Device),
                    <<DevEUI:64/integer-unsigned-big>> = router_device:dev_eui(Device),
                    {true, #{app_eui => AppEUI, dev_eui => DevEUI}}
            end
        end,
        DeviceIDs
    );
fetch_device_euis(cache, DeviceIDs) ->
    lists:filtermap(
        fun(DeviceID) ->
            case router_device_cache:get(DeviceID) of
                {error, _} ->
                    false;
                {ok, Device} ->
                    <<AppEUI:64/integer-unsigned-big>> = router_device:app_eui(Device),
                    <<DevEUI:64/integer-unsigned-big>> = router_device:dev_eui(Device),
                    {true, #{app_eui => AppEUI, dev_eui => DevEUI}}
            end
        end,
        DeviceIDs
    ).

-spec refetch(State :: state()) -> {ok, string()} | {error, any()}.
refetch(#state{pubkey_bin = PubKeyBin, sig_fun = SigFun, conn = Conn}) ->
    case router_console_api:get_json_devices() of
        {error, _} = Err ->
            Err;
        {ok, APIDevices} ->
            APIEuis =
                lists:map(
                    fun(APIDevice) ->
                        <<AppEUI:64/integer-unsigned-big>> = lorawan_utils:hex_to_binary(
                            kvc:path([<<"app_eui">>], APIDevice)
                        ),
                        <<DevEUI:64/integer-unsigned-big>> = lorawan_utils:hex_to_binary(
                            kvc:path([<<"dev_eui">>], APIDevice)
                        ),
                        #{app_eui => AppEUI, dev_eui => DevEUI}
                    end,
                    APIDevices
                ),
            RouteID = get_route_id(Conn, PubKeyBin, SigFun),
            update_euis = euis_req(Conn, PubKeyBin, SigFun, RouteID, update_euis, APIEuis),
            {ok, RouteID}
    end.

-spec euis_req(
    Conn :: grpc_client:connection(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    SigFun :: function(),
    RouteID :: string(),
    Type :: add_euis | remove_euis | update_euis,
    Euis :: list()
) -> add_euis | remove_euis | update_euis.
euis_req(_Conn, _PubKeyBin, _SigFun, _RouteID, Type, []) ->
    Type;
euis_req(Conn, PubKeyBin, SigFun, RouteID, Type, Euis) ->
    Req = #{
        id => RouteID,
        action => Type,
        euis => Euis,
        timestamp => erlang:system_time(millisecond),
        signer => PubKeyBin
    },
    EncodedReq = iot_config_client_pb:encode_msg(Req, route_euis_req_v1_pb),
    SignedReq = Req#{signature => SigFun(EncodedReq)},
    {ok, #{result := Result}} = grpc_client:unary(
        Conn, SignedReq, 'helium.iot_config.route', euis, iot_config_client_pb, []
    ),
    maps:get(action, Result).

-spec get_route_id(
    Conn :: grpc_client:connection(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    SigFun :: function()
) ->
    string().
get_route_id(Conn, PubKeyBin, SigFun) ->
    Req = #{
        oui => router_utils:get_oui(),
        timestamp => erlang:system_time(millisecond),
        signer => PubKeyBin
    },
    EncodedReq = iot_config_client_pb:encode_msg(Req, route_list_req_v1_pb),
    SignedReq = Req#{signature => SigFun(EncodedReq)},
    {ok, #{result := Result}} = grpc_client:unary(
        Conn, SignedReq, 'helium.iot_config.route', list, iot_config_client_pb, []
    ),
    [Route | _] = maps:get(routes, Result),
    maps:get(id, Route).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-endif.
