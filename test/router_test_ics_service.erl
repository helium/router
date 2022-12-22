-module(router_test_ics_service).

-behaviour(helium_iot_config_route_bhvr).
-include("../src/grpc/autogen/server/iot_config_pb.hrl").

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
    euis/2,
    devaddrs/2,
    stream/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) -> StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, StreamState) ->
    StreamState.

list(Ctx, Req) ->
    case verify_list_req(Req) of
        true ->
            lager:notice("got list req ~p", [Req]),
            Route = #route_v1_pb{id = "test_route_id"},
            Res = #route_list_res_v1_pb{
                routes = [Route]
            },
            catch persistent_term:get(?MODULE) ! {?MODULE, list, Req},
            {ok, Res, Ctx};
        false ->
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

euis(Ctx, Req) ->
    case verify_euis_req(Req) of
        true ->
            lager:notice("got euis req ~p", [Req]),
            Res = #route_euis_res_v1_pb{
                id = Req#route_euis_req_v1_pb.id,
                action = Req#route_euis_req_v1_pb.action,
                euis = Req#route_euis_req_v1_pb.euis
            },
            catch persistent_term:get(?MODULE) ! {?MODULE, euis, Req},
            {ok, Res, Ctx};
        false ->
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

devaddrs(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

stream(_RouteStreamReq, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

-spec verify_list_req(Req :: #route_list_req_v1_pb{}) -> boolean().
verify_list_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#route_list_req_v1_pb{
            signature = <<>>
        },
        route_list_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#route_list_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#route_list_req_v1_pb.signer)
    ).

-spec verify_euis_req(Req :: #route_euis_req_v1_pb{}) -> boolean().
verify_euis_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#route_euis_req_v1_pb{
            signature = <<>>
        },
        route_euis_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#route_euis_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#route_euis_req_v1_pb.signer)
    ).
