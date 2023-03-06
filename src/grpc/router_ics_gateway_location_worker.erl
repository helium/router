%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Gateway Location Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_gateway_location_worker).

-behavior(gen_server).

-include("./autogen/iot_config_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    init_ets/0,
    get/1
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
-define(ETS, router_ics_gateway_location_worker_ets).
-define(INIT, init).
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
    conn_backoff :: backoff:backoff()
}).

-record(location, {
    gateway :: libp2p_crypto:pubkey_bin(),
    timestamp :: non_neg_integer(),
    h3_index :: h3:index()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    case router_ics_utils:start_link_args(Args) of
        ignore ->
            ignore;
        Map ->
            gen_server:start_link({local, ?SERVER}, ?SERVER, Map, [])
    end.

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public, named_table, set, {read_concurrency, true}, {keypos, #location.gateway}
    ]),
    ok.

-spec get(libp2p_crypto:pubkey_bin()) -> {ok, h3:index()} | {error, any()}.
get(PubKeyBin) ->
    case lookup(PubKeyBin) of
        {error, _Reason} ->
            gen_server:call(?SERVER, {get, PubKeyBin});
        {ok, _} = OK ->
            OK
    end.

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
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        transport = Transport,
        host = Host,
        port = Port,
        conn_backoff = Backoff
    }}.

handle_call({get, PubKeyBin}, _From, #state{conn_backoff = Backoff0} = State) ->
    case get_gateway_location(PubKeyBin, State) of
        {error, Reason} = Error ->
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?INIT),
            lager:warning("fail to get_gateway_location ~p, reconnecting in ~wms", [Reason, Delay]),
            {reply, Error, State#state{conn_backoff = Backoff1}};
        {ok, H3IndexString} ->
            H3Index = h3:from_string(H3IndexString),
            ok = insert(PubKeyBin, H3Index),
            {reply, {ok, H3Index}, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

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
    {Delay, Backoff1} = backoff:fail(Backoff0),
    case router_ics_utils:connect(Transport, Host, Port) of
        {error, _Reason} ->
            lager:warning("fail to connect ~p, reconnecting in ~wms", [_Reason, Delay]),
            _ = erlang:send_after(Delay, self(), ?INIT),
            {noreply, State#state{conn_backoff = Backoff1}};
        ok ->
            lager:info("connected"),
            {_, Backoff2} = backoff:succeed(Backoff0),
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

-spec lookup(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, h3:index()} | {error, not_found | outdated}.
lookup(PubKeyBin) ->
    Yesterday = erlang:system_time(millisecond) - timer:hours(24),
    case ets:lookup(?ETS, PubKeyBin) of
        [] ->
            {error, not_found};
        [#location{timestamp = T}] when T < Yesterday ->
            {error, outdated};
        [#location{h3_index = H3Index}] ->
            {ok, H3Index}
    end.

-spec insert(PubKeyBin :: libp2p_crypto:pubkey_bin(), H3Index :: h3:index()) -> ok.
insert(PubKeyBin, H3Index) ->
    true = ets:insert(?ETS, #location{
        gateway = PubKeyBin,
        timestamp = erlang:system_time(millisecond),
        h3_index = H3Index
    }),
    ok.

-spec get_gateway_location(PubKeyBin :: libp2p_crypto:pubkey_bin(), state()) ->
    {ok, string()} | {error, any()}.
get_gateway_location(PubKeyBin, #state{sig_fun = SigFun}) ->
    Req = #iot_config_gateway_location_req_v1_pb{
        gateway = PubKeyBin
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_gateway_location_req_v1_pb),
    SignedReq = Req#iot_config_gateway_location_req_v1_pb{signature = SigFun(EncodedReq)},
    case
        helium_iot_config_gateway_client:location(SignedReq, #{
            channel => router_ics_utils:channel()
        })
    of
        {grpc_error, Reason} ->
            {error, Reason};
        {error, _} = Error ->
            Error;
        {ok, #iot_config_gateway_location_res_v1_pb{location = Location}, _Meta} ->
            {ok, Location}
    end.
