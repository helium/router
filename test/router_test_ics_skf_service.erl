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

-export([
    send_list/2
]).

-define(SFK_LIST, skf_list_stream).

-spec init(atom(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    StreamState.

-spec handle_info(Msg :: any(), StreamState :: grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({send_list, SKF, Last}, StreamState) ->
    lager:info("got send_list ~p, eos: ~p", [SKF, Last]),
    grpcbox_stream:send(Last, SKF, StreamState);
handle_info(_Msg, StreamState) ->
    StreamState.

list(Req, StreamState) ->
    case verify_list_req(Req) of
        true ->
            lager:info("got list req ~p", [Req]),
            catch persistent_term:get(?MODULE) ! {?MODULE, list, Req},
            Self = self(),
            true = erlang:register(?SFK_LIST, Self),
            lager:notice("register ~p @ ~p", [?SFK_LIST, Self]),
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

-spec send_list(SKF :: iot_config_pb:iot_config_session_key_filter_v1_pb(), Last :: boolean()) ->
    ok.
send_list(SKF, Last) ->
    lager:notice("list ~p  eos: ~p @ ~p", [SKF, Last, erlang:whereis(?SFK_LIST)]),
    case erlang:whereis(?SFK_LIST) of
        undefined ->
            timer:sleep(100),
            send_list(SKF, Last);
        Pid ->
            Pid ! {send_list, SKF, Last},
            ok
    end.

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
        libp2p_crypto:bin_to_pubkey(blockchain_swarm:pubkey_bin())
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
        libp2p_crypto:bin_to_pubkey(blockchain_swarm:pubkey_bin())
    ).
