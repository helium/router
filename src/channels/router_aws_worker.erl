%%%-------------------------------------------------------------------
%% @doc
%% == Router AWS Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_aws_worker).

-behavior(gen_server).

-include_lib("public_key/include/public_key.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
         start_link/1
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
-define(HEADERS, [{"content-type", "application/json"}]).
-define(THING_TYPE, <<"Helium-Thing">>).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    AccessKey = maps:get(aws_access_key, Args),
    SecretKey = maps:get(aws_secret_key, Args),
    Region = maps:get(aws_region, Args),
    DeviceID = maps:get(device_id, Args),
    {ok, AWS} = httpc_aws:start_link(),
    httpc_aws:set_credentials(AWS, AccessKey, SecretKey),
    httpc_aws:set_region(AWS, Region),
    ok = ensure_policy(AWS),
    ok = ensure_thing_type(AWS),
    ok = ensure_thing(AWS, DeviceID),
    ok = ensure_certificate(AWS, DeviceID),
    {ok, #state{}}.

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

-spec ensure_policy(pid()) -> ok | {error, any()}.
ensure_policy(AWS) ->
    case httpc_aws:get(AWS, "iot", "/policies/Helium-Policy", []) of
        {error, "Not Found", _} ->
            Policy = #{
                       <<"Version">> => <<"2012-10-17">>,
                       <<"Statement">> => #{
                                            <<"Action">> => [
                                                             <<"iot:Publish">>,
                                                             <<"iot:Subscribe">>,
                                                             <<"iot:Connect">>,
                                                             <<"iot:Receive">>
                                                            ],
                                            <<"Effect">> => <<"Allow">>,
                                            <<"Resource">> => [<<"*">>]
                                           }
                      },
            PolicyString =  jsx:encode(Policy),
            Body = binary_to_list(jsx:encode(#{policyDocument => PolicyString})),
            case httpc_aws:post(AWS, "iot", "/policies/Helium-Policy", Body, ?HEADERS) of
                {error, _Reason, _} -> {error, _Reason};
                {ok, _} -> ok
            end;
        {error, _Reason, _} ->
            {error, _Reason};
        {ok, _} ->
            ok
    end.

-spec ensure_thing_type(pid()) -> ok | {error, any()}.
ensure_thing_type(AWS) ->
    case httpc_aws:get(AWS, "iot", binary_to_list(<<"/thing-types/", ?THING_TYPE/binary>>), []) of
        {error, "Not Found", _} ->
            Type = #{
                     <<"thingTypeProperties">> => #{
                                                    <<"searchableAttributes">> => [<<"Helium">>, <<"IoT">>],
                                                    <<"thingTypeDescription">> => ?THING_TYPE
                                                   }
                    },
            Body = binary_to_list(jsx:encode(Type)),
            case httpc_aws:post(AWS, "iot", "/thing-types/Helium-Thing", Body, ?HEADERS) of
                {error, _Reason, _} -> {error, _Reason};
                {ok, _} -> ok
            end;
        {error, _Reason, _} ->
            {error, _Reason};
        {ok, _} ->
            ok
    end.

-spec ensure_thing(pid(), binary()) -> ok | {error, any()}.
ensure_thing(AWS, DeviceID) ->
    case httpc_aws:get(AWS, "iot", binary_to_list(<<"/things/", DeviceID/binary>>), []) of
        {error, "Not Found", _} ->
            Thing = #{<<"thingTypeName">> => ?THING_TYPE},
            Body = binary_to_list(jsx:encode(Thing)),
            case httpc_aws:post(AWS, "iot", binary_to_list(<<"/things/", DeviceID/binary>>), Body, ?HEADERS) of
                {error, _Reason, _} -> {error, _Reason};
                {ok, _} -> ok
            end;
        {error, _Reason, _} ->
            {error, _Reason};
        {ok, _} ->
            ok
    end.

ensure_certificate(AWS, DeviceID) ->
    case router_devices_sup:lookup_device_worker(DeviceID) of
        {error, _Reason}=Error ->
            Error;
        {ok, Pid} ->
            Key = router_device_worker:key(Pid),
            CSR = create_csr(Key, <<"US">>, <<"California">>, <<"San Francisco">>, <<"Helium">>, DeviceID),
            ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, CSR]),
            CSRReq = #{<<"certificateSigningRequest">> => public_key:pem_encode([public_key:pem_entry_encode('CertificationRequest', CSR)])},
            Body = binary_to_list(jsx:encode(CSRReq)),
            case httpc_aws:post(AWS, "iot", "/certificates?setAsActive=true", Body, ?HEADERS) of
                {error, _Reason, Stuff} ->
                    ct:pal("[~p:~p:~p] MARKER ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Stuff]),
                    {error, _Reason};
                {ok, _} -> ok
            end
    end.

create_csr(#{secret := {ecc_compact, PrivKey},
             public := {ecc_compact, {{'ECPoint', PubKey}, _}}}, Country, State, Location, Organization, CommonName) ->
    CRI = {'CertificationRequestInfo',
           v1,
           {rdnSequence, [[{'AttributeTypeAndValue', {2, 5, 4, 6},
                            pack_country(Country)}],
                          [{'AttributeTypeAndValue', {2, 5, 4, 8},
                            pack_string(State)}],
                          [{'AttributeTypeAndValue', {2, 5, 4, 7},
                            pack_string(Location)}],
                          [{'AttributeTypeAndValue', {2, 5, 4, 10},
                            pack_string(Organization)}],
                          [{'AttributeTypeAndValue', {2, 5, 4, 3},
                            pack_string(CommonName)}]]},
           {'CertificationRequestInfo_subjectPKInfo',
            {'CertificationRequestInfo_subjectPKInfo_algorithm',{1, 2, 840, 10045, 2 ,1},
             {asn1_OPENTYPE,<<6, 8, 42, 134, 72, 206, 61, 3, 1, 7>>}},
            PubKey},
           []},

    DER = public_key:der_encode('CertificationRequestInfo', CRI),
    Signature = public_key:sign(crypto:hash(sha256, DER), sha256, PrivKey),
    {'CertificationRequest', CRI, {'CertificationRequest_signatureAlgorithm', {1, 2, 840, 10045, 4, 3, 2}, asn1_NOVALUE}, Signature}.

pack_country(Bin) when size(Bin) == 2 ->
    <<19, 2, Bin:2/binary>>.

pack_string(Bin) ->
    Size = byte_size(Bin),
    <<12, Size:8/integer-unsigned, Bin/binary>>.
