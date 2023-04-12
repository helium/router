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

-export([register_gateway_location/2]).

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
            PubKeyBin = Req#iot_config_gateway_location_req_v1_pb.gateway,
            case maybe_get_registered_location(PubKeyBin) of
                {ok, Location} ->
                    lager:info("got location req ~p", [Req]),
                    Res = #iot_config_gateway_location_res_v1_pb{
                        %% location = "8c29a962ed5b3ff"
                        location = Location
                    },
                    catch persistent_term:get(?MODULE) ! {?MODULE, location, Req},
                    {ok, Res, Ctx};
                {error, not_found} ->
                    %% 5, not_found
                    {grpc_error, {grpcbox_stream:code_to_status(5), <<"gateway not asserted">>}}
            end;
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

-spec register_gateway_location(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Location :: string()
) -> ok.
register_gateway_location(PubKeyBin, Location) ->
    Map = persistent_term:get(known_locations, #{}),
    ok = persistent_term:put(known_locations, Map#{PubKeyBin => Location}).

-spec maybe_get_registered_location(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, string()} | {error, not_found}.
maybe_get_registered_location(PubKeyBin) ->
    Map = persistent_term:get(known_locations, #{}),
    case maps:get(PubKeyBin, Map, undefined) of
        undefined -> {error, not_found};
        Location -> {ok, Location}
    end.

%% NOTE: if more asserted gateways are needed, use these locations.
%% location = "8828308281fffff", %% original from location worker
%% location = "8c29a962ed5b3ff" %% from blockchain init
%%
%% all locations inserted into chain
%% ["8C29A962ED5B3FF","8C29A975818B3FF","8C29A97497733FF",
%%  "8C29A92809AEDFF","8C29A92A98DE7FF","8C29A92E404ABFF",
%%  "8C29A92552F31FF","8C29A924C86E7FF","8C2834535A1B5FF",
%%  "8C2834CD22653FF","8C2834CCE41C3FF","8C28341B06945FF"]
