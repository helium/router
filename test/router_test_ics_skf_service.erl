-module(router_test_ics_skf_service).

-behaviour(helium_iot_config_session_key_filter_bhvr).
-include("../src/grpc/autogen/iot_config_pb.hrl").

-export([
    init/2,
    handle_info/2
]).

-export([
    list/2,
    get/2,
    update/2,
    stream/2
]).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({eui_pair, EUIPair, Last}, StreamState) ->
    lager:info("got eui_pair ~p, eos: ~p", [EUIPair, Last]),
    grpcbox_stream:send(Last, EUIPair, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

list(Req, StreamState) ->
    case verify_list_req(Req) of
        true ->
            lager:info("got list req ~p", [Req]),
            {ok, StreamState};
        false ->
            lager:error("failed to verify list req ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

get(_Ctx, _Msg) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

update(eos, StreamState) ->
    lager:info("got EOS"),
    {ok, #iot_config_route_euis_res_v1_pb{}, StreamState};
update(Req, StreamState) ->
    case verify_skf_update_req(Req) of
        true ->
            lager:info("got skf_update ~p", [Req]),
            catch persistent_term:get(?MODULE) ! {?MODULE, update, Req},
            {ok, StreamState};
        false ->
            lager:error("failed to skf_update ~p", [Req]),
            {grpc_error, {7, <<"PERMISSION_DENIED">>}}
    end.

stream(_RouteStreamReq, _StreamState) ->
    {grpc_error, {12, <<"UNIMPLEMENTED">>}}.

-spec verify_list_req(Req :: #iot_config_session_key_filter_list_req_v1_pb{}) -> boolean().
verify_list_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#iot_config_session_key_filter_list_req_v1_pb{
            signature = <<>>
        },
        iot_config_session_key_filter_list_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#iot_config_session_key_filter_list_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#iot_config_session_key_filter_list_req_v1_pb.signer)
    ).

-spec verify_skf_update_req(Req :: #iot_config_session_key_filter_update_req_v1_pb{}) -> boolean().
verify_skf_update_req(Req) ->
    EncodedReq = iot_config_pb:encode_msg(
        Req#iot_config_session_key_filter_update_req_v1_pb{
            signature = <<>>
        },
        iot_config_session_key_filter_update_req_v1_pb
    ),
    libp2p_crypto:verify(
        EncodedReq,
        Req#iot_config_session_key_filter_update_req_v1_pb.signature,
        libp2p_crypto:bin_to_pubkey(Req#iot_config_session_key_filter_update_req_v1_pb.signer)
    ).
