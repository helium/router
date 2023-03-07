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
    stream/2
]).

-export([
    eui_pair/2,
    devaddr_range/2,
    devaddr_ranges/1
]).

-define(GET_EUIS_STREAM, get_euis_stream).
-define(GET_DEVADDRS_STREAM, get_devaddrs_stream).

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

list(Ctx, Req) ->
    case verify_list_req(Req) of
        true ->
            Routes = application:get_env(router, test_route_list, [
                #iot_config_route_v1_pb{
                    id = "test_route_id"
                }
            ]),
            lager:info("got list req ~p", [Req]),

            Res = #iot_config_route_list_res_v1_pb{
                routes = Routes
            },
            catch persistent_term:get(?MODULE) ! {?MODULE, list, Req},
            {ok, Res, Ctx};
        false ->
            lager:error("failed to verify list req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

get(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

create(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

get_euis(Req, StreamState) ->
    case verify_get_euis_req(Req) of
        true ->
            lager:info("got update_euis_req ~p", [Req]),
            catch persistent_term:get(?MODULE) ! {?MODULE, get_euis, Req},
            Self = self(),
            true = erlang:register(?GET_EUIS_STREAM, self()),
            lager:notice("register ~p @ ~p", [?GET_EUIS_STREAM, Self]),
            {ok, StreamState};
        false ->
            lager:error("failed to get_euis_req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

update_euis(eos, StreamState) ->
    lager:info("got EOS"),
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
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

get_devaddr_ranges(Req, StreamState) ->
    case verify_get_devaddrs_req(Req) of
        true ->
            Self = self(),
            true = erlang:register(?GET_DEVADDRS_STREAM, Self),
            lager:notice("register ~p @ ~p", [?GET_DEVADDRS_STREAM, Self]),
            catch persistent_term:get(?MODULE) ! {?MODULE, get_devaddr_ranges, Req},
            {ok, StreamState};
        false ->
            lager:error("failed to get_devaddr_ranges_req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

update_devaddr_ranges(_Msg, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete_devaddr_ranges(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

stream(_RouteStreamReq, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

-spec eui_pair(EUIPair :: iot_config_pb:iot_config_eui_pair_v1_pb(), Last :: boolean()) -> ok.
eui_pair(EUIPair, Last) ->
    lager:notice("eui_pair ~p  eos: ~p @ ~p", [EUIPair, Last, erlang:whereis(?GET_EUIS_STREAM)]),
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
    lager:notice("devaddr_range ~p eos: ~p @ ~p", [
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

-spec verify_list_req(Req :: #iot_config_route_list_req_v1_pb{}) -> boolean().
verify_list_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#iot_config_route_list_req_v1_pb{
            signature = <<>>
        },
        iot_config_route_list_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#iot_config_route_list_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(blockchain_swarm:pubkey_bin())
    ).

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
        libp2p_crypto:bin_to_pubkey(blockchain_swarm:pubkey_bin())
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
        libp2p_crypto:bin_to_pubkey(blockchain_swarm:pubkey_bin())
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
        libp2p_crypto:bin_to_pubkey(blockchain_swarm:pubkey_bin())
    ).
