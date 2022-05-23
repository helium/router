-module(router_chain_vars_statem).
-behavior(gen_statem).

-include("src/grpc/autogen/client/gateway_client_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    stop/0,
    handle_msg/1,
    sc_version/0,
    max_open_sc/0,
    max_xor_filter_num/0
]).

%% ------------------------------------------------------------------
%% gen_statem Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    callback_mode/0,
    terminate/2
]).

%% ------------------------------------------------------------------
%% gen_statem callbacks Exports
%% ------------------------------------------------------------------
-export([
    setup/3,
    connected/3
]).

%% ------------------------------------------------------------------
%% record defs, macros and types
%% ------------------------------------------------------------------
-record(connection, {
    conn :: grpc_client_custom:connection(),
    pid :: pid(),
    monitor_ref :: reference()
}).

-record(validator, {
    ip :: string(),
    port :: pos_integer(),
    p2p_addr :: string()
}).

-record(data, {
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: libp2p_crypto:sig_fun(),
    connection = undefined :: connection() | undefined,
    validator = undefined :: validator() | undefined,
    stability_check_timer = undefined :: reference() | undefined,
    block_age_timer = undefined :: reference() | undefined
}).

%% Periodic timer to check the stability of our validator connection
%% if we get too many stream disconnects during this period
%% we assume the val is unstable and will connect to a new val
-define(STREAM_STABILITY_CHECK_TIMEOUT, 90000).
-define(BLOCK_AGE_TIMEOUT, 450000).
%% these are config vars the miner is interested in, if they change we
%% will want to get their latest values
-define(CONFIG_VARS, ["sc_version", "max_open_sc", "max_xor_filter_num"]).

-type data() :: #data{}.
-type connection() :: #connection{}.
-type validator() :: #validator{}.

%% ------------------------------------------------------------------
%% API Definitions
%% ------------------------------------------------------------------
-spec start_link(#{}) -> {ok, pid()}.
start_link(Args) when is_map(Args) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, Args, []).

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?MODULE).

-spec handle_msg(Msg :: any()) -> ok.
handle_msg(Msg) ->
    gen_statem:cast(?MODULE, {handle_msg, Msg}).

-spec sc_version() -> any().
sc_version() ->
    persistent_term:get("sc_version", undefined).

-spec max_open_sc() -> any().
max_open_sc() ->
    persistent_term:get("max_open_sc", undefined).

-spec max_xor_filter_num() -> any().
max_xor_filter_num() ->
    persistent_term:get("max_xor_filter_num", undefined).

%% ------------------------------------------------------------------
%% gen_statem Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("starting ~p", [?MODULE]),
    PubKeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    {ok, setup, #data{pubkey_bin = PubKeyBin, sig_fun = SigFun}}.

callback_mode() -> [state_functions, state_enter].

terminate(_Reason, Data) ->
    lager:info("terminating with reason ~p", [_Reason]),
    _ = disconnect(Data),
    ok.

%% ------------------------------------------------------------------
%% gen_statem callbacks
%% ------------------------------------------------------------------
setup(enter, _OldState, Data0) ->
    Data1 = disconnect(Data0),
    _ = erlang:send_after(1000, self(), find_validator),
    {keep_state, Data1};
setup(info, find_validator, Data) ->
    %% ask a random seed validator for the address of a 'proper' validator
    %% we will then use this as our default durable validator
    case find_validator() of
        {ok, IP, Port, P2P} ->
            lager:info("connecting to validator with ip: ~p, port: ~p, addr: ~p", [
                IP, Port, P2P
            ]),
            Validator = #validator{
                ip = IP,
                port = Port,
                p2p_addr = P2P
            },
            {keep_state, Data#data{validator = Validator}, [{next_event, info, connect_validator}]};
        {error, _Reason} ->
            {repeat_state, Data}
    end;
setup(info, connect_validator, #data{validator = Validator} = Data) ->
    %% connect to our durable validator
    case connect_validator(Validator) of
        {ok, Connection} ->
            #{http_connection := ConnectionPid} = Connection,
            Ref = erlang:monitor(process, ConnectionPid),
            %% once we have a validator connection established
            %% fire a timer to check how stable the streams are behaving
            catch erlang:cancel_timer(Data#data.stability_check_timer),
            catch erlang:cancel_timer(Data#data.block_age_timer),
            SCTRef = erlang:send_after(?STREAM_STABILITY_CHECK_TIMEOUT, self(), stability_check),
            BACTRef = erlang:send_after(block_age_timeout(), self(), block_age_check),
            Conn = #connection{
                conn = Connection,
                pid = ConnectionPid,
                monitor_ref = Ref
            },
            {keep_state,
                Data#data{
                    connection = Conn, stability_check_timer = SCTRef, block_age_timer = BACTRef
                },
                [{next_event, info, fetch_config}]};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(info, fetch_config, #data{validator = Validator} = Data) ->
    %% get necessary config data from our durable validator
    case fetch_config(?CONFIG_VARS, Validator) of
        {ok, Vars} ->
            lager:info("got vars ~p", [Vars]),
            lists:foreach(
                fun({Key, Value}) ->
                    ok = persistent_term:put(Key, Value)
                end,
                Vars
            ),
            {next_state, connected, Data};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(_EventType, _Msg, Data) ->
    lager:debug(
        "unhandled event while in ~p state: type: ~p, msg: ~p",
        [setup, _EventType, _Msg]
    ),
    {keep_state, Data}.

connected(enter, _OldState, Data) ->
    {keep_state, Data};
connected(_EventType, _Msg, Data) ->
    lager:debug(
        "unhandled event while in ~p state: type: ~p, msg: ~p",
        [connected, _EventType, _Msg]
    ),
    {keep_state, Data}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec disconnect(Data :: data()) -> data().
disconnect(#data{connection = undefined} = Data) ->
    Data#data{connection = undefined, validator = undefined};
disconnect(#data{connection = #connection{conn = Connection}} = Data) ->
    catch grpc_client_custom:stop_connection(Connection),
    Data#data{connection = undefined, validator = undefined}.

-spec find_validator() -> {ok, string(), pos_integer(), string()} | {error, any()}.
find_validator() ->
    case application:get_env(router, seed_validators) of
        {ok, SeedValidators} ->
            {_SeedP2PAddr, SeedValIP, SeedValGRPCPort} =
                case lists:nth(rand:uniform(length(SeedValidators)), SeedValidators) of
                    {_SeedP2PAddr0, _SeedValIP0, SeedValGRPCPort0} = AddrAndPort when
                        is_integer(SeedValGRPCPort0)
                    ->
                        AddrAndPort;
                    {_SeedP2PAddr0, SeedValIP0} ->
                        {_SeedP2PAddr0, SeedValIP0, 8080}
                end,
            Req = build_validators_req(1),
            lager:info("attempting to connect to ~s:~p", [SeedValIP, SeedValGRPCPort]),
            case send_grpc_unary_req(SeedValIP, SeedValGRPCPort, Req, validators) of
                {error, _} = Error ->
                    lager:warning("request to validator failed: ~p", [Error]),
                    {error, Error};
                {ok, #{
                    http_status := 200,
                    result := #gateway_resp_v1_pb{
                        msg = {_RespType, #gateway_validators_resp_v1_pb{result = []}}
                    }
                }} ->
                    %% no routes, retry in a bit
                    lager:warning("failed to find any validator routing from seed validator ~p", [
                        SeedValIP
                    ]),
                    {error, no_validators};
                {ok, #{
                    http_status := 200,
                    result := #gateway_resp_v1_pb{
                        msg = {_RespType, #gateway_validators_resp_v1_pb{result = Routing}}
                    }
                }} ->
                    %% resp will contain the payload 'gateway_validators_resp_v1_pb'
                    [
                        #routing_address_pb{
                            pub_key = DurableValPubKeyBin,
                            uri = DurableValURI
                        }
                    ] = Routing,
                    DurableValP2PAddr = libp2p_crypto:pubkey_bin_to_p2p(DurableValPubKeyBin),
                    #{
                        host := DurableValIP,
                        port := DurableValGRPCPort
                    } = uri_string:parse(erlang:binary_to_list(DurableValURI)),
                    {ok, DurableValIP, DurableValGRPCPort, DurableValP2PAddr}
            end;
        _ ->
            lager:warning("failed to find seed validators", []),
            {error, find_validator_request_failed}
    end.

-spec connect_validator(validator()) -> {error, any()} | {ok, grpc_client_custom:connection()}.
connect_validator(#validator{ip = IP, port = Port, p2p_addr = Addr}) ->
    try
        lager:debug(
            "connecting to validator, p2paddr: ~p, ip: ~p, port: ~p",
            [Addr, IP, Port]
        ),
        case grpc_client_custom:connect(tcp, IP, Port) of
            {error, _Reason} = Error ->
                lager:debug(
                    "failed to connect to validator, will try again in a bit. Reason: ~p",
                    [_Reason]
                ),
                Error;
            {ok, Connection} = Res ->
                lager:debug("successfully connected to validator via connection ~p", [Connection]),
                Res
        end
    catch
        _Class:_Error:_Stack ->
            lager:warning(
                "error whilst connectting to validator, will try again in a bit. Reason: ~p, Details: ~p, Stack: ~p",
                [_Class, _Error, _Stack]
            ),
            {error, connect_validator_failed}
    end.

-spec fetch_config(Keys :: [string()], Validator :: validator()) ->
    {error, any()} | {ok, map()}.
fetch_config(Keys, #validator{ip = IP, port = Port}) ->
    Req2 = build_config_req(Keys),
    case send_grpc_unary_req(IP, Port, Req2, config) of
        {error, _} = Error ->
            lager:warning("request to fetch_config failed: ~p", [Error]),
            {error, Error};
        {ok, #{
            http_status := 200,
            result := #gateway_resp_v1_pb{
                msg = {_RespType, #gateway_config_resp_v1_pb{result = Vars}}
            }
        }} ->
            {ok, [blockchain_txn_vars_v1:from_var(Var) || #blockchain_var_v1_pb{} = Var <- Vars]}
    end.

-spec build_validators_req(Quantity :: pos_integer()) -> #gateway_validators_req_v1_pb{}.
build_validators_req(Quantity) ->
    #gateway_validators_req_v1_pb{
        quantity = Quantity
    }.

-spec build_config_req(Keys :: [string()]) -> #gateway_config_req_v1_pb{}.
build_config_req(Keys) ->
    #gateway_config_req_v1_pb{keys = Keys}.

-spec send_grpc_unary_req(
    PeerIP :: string(),
    GRPCPort :: non_neg_integer(),
    Req :: tuple(),
    RPC :: atom()
) -> grpc_client_custom:unary_response() | {error, req_failed}.
send_grpc_unary_req(PeerIP, GRPCPort, Req, RPC) ->
    try
        lager:debug("send unary request via new connection to ip ~s: ~p", [PeerIP, Req]),
        {ok, Connection} = grpc_client_custom:connect(tcp, PeerIP, GRPCPort),
        Res = grpc_client_custom:unary(
            Connection,
            Req,
            'helium.gateway',
            RPC,
            gateway_client_pb,
            [{callback_mod, router_chain_vars_handler}]
        ),
        lager:debug("new connection, send unary result: ~p", [Res]),
        %% we dont need the connection to hang around, so close it out
        _ = grpc_client_custom:stop_connection(Connection),
        Res
    catch
        _Class:_Error:_Stack ->
            lager:warning("send unary failed: ~p, ~p, ~p", [_Class, _Error, _Stack]),
            {error, req_failed}
    end.

block_age_timeout() ->
    ?BLOCK_AGE_TIMEOUT + rand:uniform(?BLOCK_AGE_TIMEOUT).
