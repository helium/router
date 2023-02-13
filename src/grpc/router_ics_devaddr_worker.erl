%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_devaddr_worker).

-behavior(gen_server).

-include("./autogen/iot_config_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    get_devaddr_ranges/0,
    reconcile/1,
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
    route_id :: undefined | string(),
    devaddr_ranges :: undefined | list(iot_config_pb:iot_config_devaddr_range_v1_pb())
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(#{host := ""}) ->
    ignore;
start_link(#{port := Port} = Args) when is_list(Port) ->
    ?MODULE:start_link(Args#{port => erlang:list_to_integer(Port)});
start_link(#{devaddr_enabled := "true", host := Host, port := Port} = Args) when
    is_list(Host) andalso is_integer(Port)
->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []);
start_link(_Args) ->
    ignore.

-spec get_devaddr_ranges() ->
    {ok, list(iot_config_pb:iot_config_devaddr_range_v1_pb())} | {error, any()}.
get_devaddr_ranges() ->
    gen_server:call(?SERVER, get_devaddr_ranges).

-spec reconcile(Pid :: pid() | undefined) -> ok.
reconcile(Pid) ->
    gen_server:cast(?SERVER, {?RECONCILE_START, Pid}).

-spec reconcile_end(Pid :: pid() | undefined, list(iot_config_pb:iot_config_devaddr_range_v1_pb())) ->
    ok.
reconcile_end(Pid, List) ->
    gen_server:cast(?SERVER, {?RECONCILE_END, Pid, List}).

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
        conn_backoff = Backoff,
        route_id = maps:get(route_id, Args, undefined)
    }}.

handle_call(_Msg, _From, #state{route_id = undefined} = State) ->
    lager:warning("can't handle call msg: ~p", [_Msg]),
    {reply, ok, State};
handle_call(get_devaddr_ranges, _From, #state{devaddr_ranges = DevaddrRanges} = State) ->
    Reply =
        case DevaddrRanges of
            undefined -> {error, no_ranges};
            _ -> {ok, DevaddrRanges}
        end,
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({?RECONCILE_START, Pid}, #state{conn_backoff = Backoff0} = State) ->
    ct:print("reconciling started pid: ~p", [Pid]),
    case get_devaddrs(Pid, State) of
        {error, _Reason} = Error ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?INIT),
            lager:warning("fail to get_devaddrs ~p, retrying in ~wms", [
                _Reason, Delay
            ]),
            ok = forward_reconcile(Pid, Error),
            {noreply, State#state{conn_backoff = Backoff1}};
        {ok, _Stream} ->
            {_, Backoff2} = backoff:succeed(Backoff0),
            {noreply, State#state{conn_backoff = Backoff2}}
    end;
handle_cast({?RECONCILE_END, Pid, DevaddrRanges}, #state{} = State) ->
    ct:print("reconciling done: ~p", [{?RECONCILE_END, Pid, DevaddrRanges}]),
    ok = forward_reconcile(Pid, DevaddrRanges),
    {noreply, State#state{devaddr_ranges = DevaddrRanges}};
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
                    ok = ?MODULE:reconcile(undefined),
                    {noreply, State#state{
                        conn_backoff = Backoff2, route_id = RouteID
                    }}
            end
    end;
handle_info({headers, _StreamID, _Data}, State) ->
    ct:print("got headers for stream: ~p, ~p", [_StreamID, _Data]),
    {noreply, State};
handle_info({trailers, _StreamID, _Data}, State) ->
    ct:print("got trailers for stream: ~p, ~p", [_StreamID, _Data]),
    {noreply, State};
handle_info({eos, _StreamID}, State) ->
    ct:print("got eos for stream: ~p", [_StreamID]),
    {noreply, State};
handle_info({'DOWN', _Ref, Type, Pid, Reason}, State) ->
    ct:print("~p got DOWN for ~p: ~p ~p with state ~p", [self(), Type, Pid, Reason, State]),
    {noreply, State};
handle_info(_Msg, State) ->
    ct:print("rcvd unknown info msg: ~p", [_Msg]),
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
                    ct:print("initial connected: ~p", [_Conn]),
                    connect(State);
                {error, _Reason} = Error ->
                    Error
            end;
        {ok, {_Conn, _Interceptor}} ->
            ct:print("found connected: ~p and ~p", [_Conn, _Interceptor]),
            erlang:monitor(process, _Conn),
            ok
    end.

-spec get_route_id(state()) -> {ok, string()} | {error, any()}.
get_route_id(#state{sig_fun = SigFun, route_id = undefined}) ->
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
        {ok, #iot_config_route_list_res_v1_pb{routes = [Route]}, _Meta} ->
            RouteID = Route#iot_config_route_v1_pb.id,
            lager:info(
                lists:join(" ", [
                    "Picking devaddr range from route ~s.",
                    "Add 'ROUTER_DEVADDR_CONFIG_SERVICE_ROUTE_ID=~s' to your .env file."
                ]),
                [RouteID, RouteID]
            ),
            {ok, RouteID};
        {ok, #iot_config_route_list_res_v1_pb{routes = [Route | _] = Routes}, _Meta} ->
            RouteID = Route#iot_config_route_v1_pb.id,

            Count = io_lib:format("There are ~p routes, choosing ~s", [length(Routes), RouteID]),
            Info = "Add one of the following to your .env file:",
            Choices = lists:map(
                fun(R) ->
                    io_lib:format("  ROUTER_DEVADDR_CONFIG_SERVICE_ROUTE_ID=~s", [
                        R#iot_config_route_v1_pb.id
                    ])
                end,
                Routes
            ),

            lager:info("~p~n~p~n~p", [Count, Info, lists:join("\n", Choices)]),

            {ok, RouteID}
    end;
get_route_id(#state{route_id = RouteID}) ->
    {ok, RouteID}.

-spec get_devaddrs(Pid :: pid() | undefined, state()) ->
    {ok, grpcbox_client:stream()} | {error, any()}.
get_devaddrs(Pid, #state{sig_fun = SigFun, route_id = RouteID}) ->
    Req = #iot_config_route_get_devaddr_ranges_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond)
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_route_get_devaddr_ranges_req_v1_pb),
    SignedReq = Req#iot_config_route_get_devaddr_ranges_req_v1_pb{signature = SigFun(EncodedReq)},

    helium_iot_config_route_client:get_devaddr_ranges(SignedReq, #{
        channel => ?MODULE,
        callback_module => {
            router_ics_route_get_devaddrs_handler,
            Pid
        }
    }).

-spec forward_reconcile(
    Pid :: pid() | undefined,
    Result :: {ok, non_neg_integer(), non_neg_integer()} | {error, any()}
) -> ok.
forward_reconcile(undefined, _Result) ->
    ok;
forward_reconcile(Pid, Result) ->
    catch Pid ! {?MODULE, Result},
    ok.
