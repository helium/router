-module(router_test_ics_route_service).

-behaviour(helium_iot_config_route_bhvr).
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    init/2,
    handle_info/2
]).

-export([
    list/2,
    get/2,
    create/2,
    update/2,
    delete/2,
    get_euis/2,
    update_euis/2,
    delete_euis/2,
    get_devaddr_ranges/2,
    update_devaddr_ranges/2,
    delete_devaddr_ranges/2,
    list_skfs/2,
    get_skfs/2,
    update_skfs/2,
    stream/2
]).

-export([
    eui_pair/2,
    devaddr_range/2,
    devaddr_ranges/1
]).

-export([
    test_init/0,
    add_skf/1,
    clear_skf/0
]).

-define(GET_EUIS_STREAM, get_euis_stream).
-define(GET_DEVADDRS_STREAM, get_devaddrs_stream).

-define(PERMISSION_DENIED, {grpcbox_stream:code_to_status(7), <<"PERMISSION_DENIED">>}).
-define(UNIMPLEMENTED, {grpcbox_stream:code_to_status(12), <<"UNIMPLEMENTED">>}).

-define(ETS_SKF, ets_test_skf_list).

%% ------------------------------------------------------------------
%% Test Callbacks
%% ------------------------------------------------------------------

-spec test_init() -> ok.
test_init() ->
    ct:print("intializing ets for route service"),
    ?ETS_SKF = ets:new(?ETS_SKF, [public, named_table, bag]),
    true = erlang:register(skf_callback, self()),
    ok.

-spec add_skf(#iot_config_skf_v1_pb{} | list(#iot_config_skf_v1_pb{})) -> ok.
add_skf(SKFs) ->
    true = ets:insert(?ETS_SKF, SKFs),
    ok.

-spec remove_skf(#iot_config_skf_v1_pb{}) -> ok.
remove_skf(SKF) ->
    true = ets:delete_object(?ETS_SKF, SKF),
    ok.

-spec clear_skf() -> ok.
clear_skf() ->
    true = ets:delete_all_objects(?ETS_SKF),
    ok.

%% ------------------------------------------------------------------
%% Stream Callbacks
%% ------------------------------------------------------------------

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({eui_pair, EUIPair, Last}, StreamState) ->
    lager:info("got eui_pair ~p, eos: ~p", [EUIPair, Last]),
    grpcbox_stream:send(Last, EUIPair, StreamState);
handle_info({devaddr_range, DevaddrRange, Last}, StreamState) ->
    lager:info("got devaddr_range ~p, eos: ~p", [DevaddrRange, Last]),
    grpcbox_stream:send(Last, DevaddrRange, StreamState);
handle_info({devaddr_ranges, Ranges}, StreamState) ->
    lager:info("got ~p devaddr ranges", [erlang:length(Ranges)]),
    lists:foreach(
        fun({Last, Range}) ->
            lager:info("sending devaddr range: ~p at ~p", [Range, Last]),
            grpcbox_stream:send(Last, Range, StreamState)
        end,
        router_utils:enumerate_last(Ranges)
    ),
    StreamState;
handle_info(_Msg, StreamState) ->
    StreamState.

%% ------------------------------------------------------------------
%% Route Callbacks
%% ------------------------------------------------------------------

list(_Ctx, _Req) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

get(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

create(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

stream(_RouteStreamReq, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

%% ------------------------------------------------------------------
%% EUI Callbacks
%% ------------------------------------------------------------------

get_euis(Req, StreamState) ->
    case verify_get_euis_req(Req) of
        true ->
            lager:info("got update_euis_req ~p", [Req]),
            catch persistent_term:get(?MODULE) ! {?MODULE, get_euis, Req},
            Self = self(),
            true = erlang:register(?GET_EUIS_STREAM, self()),
            lager:info("register ~p @ ~p", [?GET_EUIS_STREAM, Self]),
            {ok, StreamState};
        false ->
            lager:error("failed to get_euis_req ~p", [Req]),
            {grpc_error, ?PERMISSION_DENIED}
    end.

update_euis(eos, StreamState) ->
    Timeout = application:get_env(router, test_eui_update_eos_timeout, 0),
    lager:info("got EOS, waiting ~wms to return with close", [Timeout]),
    timer:sleep(Timeout),
    lager:info("closing server side of eui update stream"),
    {ok, #iot_config_route_euis_res_v1_pb{}, StreamState};
update_euis(Req, _StreamState) ->
    case verify_update_euis_req(Req) of
        true ->
            lager:info("got update_euis_req ~p", [Req]),
            catch persistent_term:get(?MODULE) ! {?MODULE, update_euis, Req},
            {ok, _StreamState};
        false ->
            lager:error("failed to update_euis_req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

delete_euis(_Ctx, _Msg) ->
    {grpc_error, ?UNIMPLEMENTED}.

%% ------------------------------------------------------------------
%% Devaddr Callbacks
%% ------------------------------------------------------------------

get_devaddr_ranges(Req, StreamState) ->
    case verify_get_devaddrs_req(Req) of
        true ->
            Self = self(),
            catch (true = erlang:register(?GET_DEVADDRS_STREAM, Self)),
            lager:info("register ~p @ ~p", [?GET_DEVADDRS_STREAM, Self]),
            catch persistent_term:get(?MODULE) ! {?MODULE, get_devaddr_ranges, Req},
            {ok, StreamState};
        false ->
            lager:error("failed to get_devaddr_ranges_req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

update_devaddr_ranges(_Msg, _StreamState) ->
    {grpc_error, ?UNIMPLEMENTED}.

delete_devaddr_ranges(_Ctx, _Msg) ->
    {grpc_error, ?UNIMPLEMENTED}.

%% ------------------------------------------------------------------
%% Session Key Filter Callbacks
%% ------------------------------------------------------------------

list_skfs(_Req, StreamState) ->
    case ets:tab2list(?ETS_SKF) of
        [] ->
            {stop, StreamState};
        SKFs ->
            lists:foreach(
                fun({Last, SKF}) ->
                    grpcbox_stream:send(Last, SKF, StreamState)
                end,
                router_utils:enumerate_last(SKFs)
            ),
            {ok, StreamState}
    end.

get_skfs(_Req, _StreamState) ->
    {grpc_error, ?UNIMPLEMENTED}.

update_skfs(Ctx, Req) ->
    RouteID = Req#iot_config_route_skf_update_req_v1_pb.route_id,
    lists:foreach(
        fun(
            #iot_config_route_skf_update_v1_pb{
                action = Action,
                devaddr = Devaddr,
                session_key = SessionKey,
                max_copies = MaxCopies
            }
        ) ->
            SKF = #iot_config_skf_v1_pb{
                devaddr = Devaddr,
                session_key = SessionKey,
                route_id = RouteID,
                max_copies = MaxCopies
            },
            case Action of
                add -> add_skf(SKF);
                remove -> remove_skf(SKF)
            end
        end,
        Req#iot_config_route_skf_update_req_v1_pb.updates
    ),

    ok = timer:sleep(application:get_env(router, test_update_skf_delay_ms, 0)),

    {ok, #iot_config_route_skf_update_res_v1_pb{}, Ctx}.
%% {grpc_error, ?UNIMPLEMENTED}.

%% ------------------------------------------------------------------
%% Internal Functions
%% ------------------------------------------------------------------

-spec eui_pair(EUIPair :: iot_config_pb:iot_config_eui_pair_v1_pb(), Last :: boolean()) -> ok.
eui_pair(EUIPair, Last) ->
    lager:info("eui_pair ~p  eos: ~p @ ~p", [EUIPair, Last, erlang:whereis(?GET_EUIS_STREAM)]),
    case erlang:whereis(?GET_EUIS_STREAM) of
        undefined ->
            timer:sleep(100),
            eui_pair(EUIPair, Last);
        Pid ->
            Pid ! {eui_pair, EUIPair, Last},
            ok
    end.

-spec devaddr_range(
    DevaddrRange :: iot_config_pb:iot_config_devaddr_range_v1_pb(), Last :: boolean()
) -> ok.
devaddr_range(DevaddrRange, Last) ->
    lager:info("devaddr_range ~p eos: ~p @ ~p", [
        DevaddrRange, Last, erlang:whereis(?GET_DEVADDRS_STREAM)
    ]),
    case erlang:whereis(?GET_DEVADDRS_STREAM) of
        undefined ->
            timer:sleep(100),
            devaddr_range(DevaddrRange, Last);
        Pid ->
            Pid ! {devaddr_range, DevaddrRange, Last},
            ok
    end.

-spec devaddr_ranges(DevaddrRanges :: list(iot_config_pb:iot_config_devaddr_range_v1_pb())) -> ok.
devaddr_ranges(DevaddrRanges) ->
    lager:info("~p devaddr_ranges @ ~p", [
        erlang:length(DevaddrRanges), erlang:whereis(?GET_DEVADDRS_STREAM)
    ]),
    case erlang:whereis(?GET_DEVADDRS_STREAM) of
        undefined ->
            timer:sleep(100),
            devaddr_ranges(DevaddrRanges);
        Pid ->
            Pid ! {devaddr_ranges, DevaddrRanges},
            ok
    end.

-spec verify_update_euis_req(Req :: #iot_config_route_update_euis_req_v1_pb{}) -> boolean().
verify_update_euis_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#iot_config_route_update_euis_req_v1_pb{
            signature = <<>>
        },
        iot_config_route_update_euis_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#iot_config_route_update_euis_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#iot_config_route_update_euis_req_v1_pb.signer)
    ).

-spec verify_get_euis_req(Req :: #iot_config_route_get_euis_req_v1_pb{}) -> boolean().
verify_get_euis_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#iot_config_route_get_euis_req_v1_pb{
            signature = <<>>
        },
        iot_config_route_get_euis_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#iot_config_route_get_euis_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#iot_config_route_get_euis_req_v1_pb.signer)
    ).

-spec verify_get_devaddrs_req(Req :: #iot_config_route_get_devaddr_ranges_req_v1_pb{}) -> boolean().
verify_get_devaddrs_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#iot_config_route_get_devaddr_ranges_req_v1_pb{signature = <<>>},
        iot_config_route_get_devaddr_ranges_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#iot_config_route_get_devaddr_ranges_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#iot_config_route_get_devaddr_ranges_req_v1_pb.signer)
    ).
