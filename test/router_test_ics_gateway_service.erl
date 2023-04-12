-module(router_test_ics_gateway_service).

-behaviour(helium_iot_config_gateway_bhvr).
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    init/2,
    handle_info/2
]).

-export([
    region_params/2,
    load_region/2,
    location/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_Msg, StreamState) ->
    StreamState.

region_params(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

load_region(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

location(Ctx, Req) ->
    case verify_location_req(Req) of
        true ->
            lager:info("got location req ~p", [Req]),
            Res = #iot_config_gateway_location_res_v1_pb{
                location = "8c29a962ed5b3ff"
            },
            catch persistent_term:get(?MODULE) ! {?MODULE, location, Req},
            {ok, Res, Ctx};
        false ->
            lager:error("failed to verify location req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

-spec verify_location_req(Req :: #iot_config_gateway_location_req_v1_pb{}) -> boolean().
verify_location_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#iot_config_gateway_location_req_v1_pb{
            signature = <<>>
        },
        iot_config_gateway_location_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#iot_config_gateway_location_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(blockchain_swarm:pubkey_bin())
    ).
