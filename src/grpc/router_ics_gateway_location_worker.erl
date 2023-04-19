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
-define(CACHED_NOT_FOUND, cached_not_found).

-record(state, {
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: function()
}).

-record(location, {
    gateway :: libp2p_crypto:pubkey_bin(),
    timestamp :: non_neg_integer(),
    h3_index :: h3:index() | undefined
}).

%% -type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec init_ets() -> ok.
init_ets() ->
    ?ETS = ets:new(?ETS, [
        public,
        named_table,
        set,
        {read_concurrency, true},
        {keypos, #location.gateway}
    ]),
    ok.

-spec get(libp2p_crypto:pubkey_bin()) -> {ok, h3:index()} | {error, any()}.
get(PubKeyBin) ->
    case router_utils:get_env_bool(bypass_location_lookup, false) of
        true ->
            {error, not_found};
        false ->
            case lookup(PubKeyBin) of
                {error, ?CACHED_NOT_FOUND} = E ->
                    E;
                {error, _Reason} ->
                    HotspotName = blockchain_utils:addr2name(PubKeyBin),
                    case get_gateway_location(PubKeyBin) of
                        {error, ErrReason, _} ->
                            lager:warning(
                                "fail to get_gateway_location ~p for ~s",
                                [ErrReason, HotspotName]
                            ),
                            ok = insert(PubKeyBin, ?CACHED_NOT_FOUND),
                            {error, ErrReason};
                        {ok, H3IndexString} ->
                            H3Index = h3:from_string(H3IndexString),
                            ok = insert(PubKeyBin, H3Index),
                            {ok, H3Index}
                    end;
                {ok, _} = OK ->
                    OK
            end
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(
    #{
        pubkey_bin := PubKeyBin,
        sig_fun := SigFun
    } = Args
) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, #state{
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

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

%% Store valid locations for up to 24 hours.
%% Invalid locations for 1 hour.
-spec lookup(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, h3:index()} | {error, ?CACHED_NOT_FOUND | not_found | outdated}.
lookup(PubKeyBin) ->
    Yesterday = erlang:system_time(millisecond) - timer:hours(24),
    OneHour = erlang:system_time(millisecond) - timer:hours(1),
    case ets:lookup(?ETS, PubKeyBin) of
        [] ->
            {error, not_found};
        [#location{timestamp = T}] when T < Yesterday ->
            {error, outdated};
        [#location{timestamp = T, h3_index = ?CACHED_NOT_FOUND}] when T < OneHour ->
            {error, outdated};
        [#location{h3_index = ?CACHED_NOT_FOUND}] ->
            {error, ?CACHED_NOT_FOUND};
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

%% We have to do this because the call to `helium_iot_config_gateway_client:location` can return
%% `{error, {Status, Reason}, _}` but is not in the spec...
-dialyzer({nowarn_function, get_gateway_location/1}).

-spec get_gateway_location(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, string()} | {error, any(), boolean()}.
get_gateway_location(PubKeyBin) ->
    SigFun = router_blockchain:sig_fun(),
    Req = #iot_config_gateway_location_req_v1_pb{
        gateway = PubKeyBin,
        signer = router_blockchain:pubkey_bin()
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_gateway_location_req_v1_pb),
    SignedReq = Req#iot_config_gateway_location_req_v1_pb{signature = SigFun(EncodedReq)},
    case
        helium_iot_config_gateway_client:location(SignedReq, #{
            channel => router_ics_utils:channel()
        })
    of
        {error, {Status, Reason}, _} when is_binary(Status) ->
            {error, {grpcbox_utils:status_to_string(Status), Reason}, false};
        {grpc_error, Reason} ->
            {error, Reason, false};
        {error, Reason} ->
            {error, Reason, true};
        {ok, #iot_config_gateway_location_res_v1_pb{location = Location}, _Meta} ->
            {ok, Location}
    end.
