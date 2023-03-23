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
    reconcile_end/2,
    devaddr_num_to_base_num/1
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
    transport :: http | https,
    host :: string(),
    port :: non_neg_integer(),
    conn_backoff :: backoff:backoff(),
    route_id :: string(),
    devaddr_ranges :: undefined | list(iot_config_pb:iot_config_devaddr_range_v1_pb())
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    case router_ics_utils:start_link_args(Args) of
        #{devaddr_enabled := "true"} = Map ->
            case maps:get(route_id, Map, "") of
                "" ->
                    lager:warning("~p enabled, but no route_id provided, ignoring", [?MODULE]),
                    ignore;
                _ ->
                    gen_server:start_link({local, ?SERVER}, ?SERVER, Map, [])
            end;
        _ ->
            lager:warning("~s ignored ~p", [?MODULE, Args]),
            ignore
    end.

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
init(
    #{
        pubkey_bin := PubKeyBin,
        sig_fun := SigFun,
        transport := Transport,
        host := Host,
        port := Port,
        route_id := RouteID
    } =
        Args
) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    %% {_, SigFun, _} = router_blockchain:get_key(),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    self() ! ?INIT,
    {ok, #state{
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        transport = Transport,
        host = Host,
        port = Port,
        conn_backoff = Backoff,
        route_id = RouteID
    }}.

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
    ok = forward_reconcile(Pid, DevaddrRanges),
    %% Drop ranges that may fall outside the configured devaddr_prefix
    Ranges = lists:filtermap(
        fun(DevaddrRange) ->
            #iot_config_devaddr_range_v1_pb{
                start_addr = StartAddr,
                end_addr = EndAddr
            } = DevaddrRange,
            try
                MinBase = router_ics_devaddr_worker:devaddr_num_to_base_num(StartAddr),
                MaxBase = router_ics_devaddr_worker:devaddr_num_to_base_num(EndAddr),
                {true, {MinBase, MaxBase}}
            catch
                _Error:Reason ->
                    lager:warning("ignoring devaddr range [reason: ~p]", [Reason]),
                    false
            end
        end,
        DevaddrRanges
    ),
    ok = router_device_devaddr:set_devaddr_bases(Ranges),

    {noreply, State#state{devaddr_ranges = DevaddrRanges}};
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
        route_id = RouteID
    } = State
) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    case router_ics_utils:connect(Transport, Host, Port) of
        {error, _Reason} ->
            lager:warning("fail to connect ~p, reconnecting in ~wms", [_Reason, Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT),
            {noreply, State#state{conn_backoff = Backoff1}};
        ok ->
            lager:info("connected"),
            {_, Backoff2} = backoff:succeed(Backoff0),
            ok = ?MODULE:reconcile(undefined),
            {noreply, State#state{
                conn_backoff = Backoff2, route_id = RouteID
            }}
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
        channel => router_ics_utils:channel(),
        callback_module => {
            router_ics_route_get_devaddrs_handler,
            Pid
        }
    }).

-spec forward_reconcile(
    Pid :: pid() | undefined,
    Result :: list(iot_config_pb:iot_config_devaddr_range_v1_pb()) | {error, any()}
) -> ok.
forward_reconcile(undefined, _Result) ->
    ok;
forward_reconcile(Pid, Result) ->
    catch Pid ! {?MODULE, Result},
    ok.

-spec devaddr_num_to_base_num(non_neg_integer()) -> non_neg_integer().
devaddr_num_to_base_num(DevaddrNum) ->
    Prefix = application:get_env(blockchain, devaddr_prefix, $H),
    <<Base:25/integer-unsigned-little, Prefix:7/integer>> = lorawan_utils:reverse(
        binary:encode_unsigned(DevaddrNum)
    ),
    Base.
