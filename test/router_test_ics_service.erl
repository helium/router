-module(router_test_ics_service).

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

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) -> StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, StreamState) ->
    StreamState.

list(Ctx, Req) ->
    case verify_list_req(Req) of
        true ->
            lager:info("got list req ~p", [Req]),
            Route = #iot_config_route_v1_pb{id = "test_route_id"},
            Res = #iot_config_route_list_res_v1_pb{
                routes = [Route]
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

get_euis(_Msg, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update_euis(Req, _StreamState) ->
    case verify_update_euis_req_req(Req) of
        true ->
            lager:info("got update_euis_req ~p", [Req]),
            catch persistent_term:get(?MODULE) ! {?MODULE, update_euis, Req},
            % {ok, #iot_config_route_euis_res_v1_pb{}, ctx:new()};
            {ok, _StreamState};
        false ->
            lager:error("failed to update_euis_req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

delete_euis(Ctx, Req) ->
    case verify_delete_euis_req_req(Req) of
        true ->
            lager:info("got delete_euis_req ~p", [Req]),
            catch persistent_term:get(?MODULE) ! {?MODULE, delete_euis, Req},
            {ok, #iot_config_route_euis_res_v1_pb{}, Ctx};
        false ->
            lager:error("failed to delete_euis_req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

get_devaddr_ranges(_Msg, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update_devaddr_ranges(_Msg, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

delete_devaddr_ranges(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

stream(_RouteStreamReq, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

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
        libp2p_crypto:bin_to_pubkey(Req#iot_config_route_list_req_v1_pb.signer)
    ).

-spec verify_update_euis_req_req(Req :: #iot_config_route_update_euis_req_v1_pb{}) -> boolean().
verify_update_euis_req_req(Req) ->
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

-spec verify_delete_euis_req_req(Req :: #iot_config_route_delete_euis_req_v1_pb{}) -> boolean().
verify_delete_euis_req_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#iot_config_route_delete_euis_req_v1_pb{
            signature = <<>>
        },
        iot_config_route_delete_euis_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#iot_config_route_delete_euis_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#iot_config_route_delete_euis_req_v1_pb.signer)
    ).
