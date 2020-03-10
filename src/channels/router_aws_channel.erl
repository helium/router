%%%-------------------------------------------------------------------
%% @doc
%% == Router AWS Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_aws_channel).

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

-record(state, {channel :: router_channel:channel(),
                aws :: pid(),
                connection :: pid()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Channel) ->
    lager:info("~p init with ~p", [?SERVER, Channel]),
    #{aws_access_key := AccessKey, aws_secret_key := SecretKey, aws_region := Region} = router_channel:args(Channel),
    DeviceID = router_channel:device_id(Channel),
    {ok, AWS} = httpc_aws:start_link(),
    httpc_aws:set_credentials(AWS, AccessKey, SecretKey),
    httpc_aws:set_region(AWS, Region),
    ok = ensure_policy(AWS),
    ok = ensure_thing_type(AWS),
    ok = ensure_thing(AWS, DeviceID),
    {ok, Key, Cert} = ensure_certificate(AWS, DeviceID),
    {ok, Endpoint} = get_iot_endpoint(AWS),
    {ok, Conn} = connect(DeviceID, Endpoint, Key, Cert),
    {ok, _, _} = emqtt:subscribe(Conn, {<<"$aws/things/", DeviceID/binary, "/shadow/#">>, 0}),    
    (catch emqtt:ping(Conn)),
    erlang:send_after(25000, self(), ping),
    {ok, #state{channel=Channel, connection=Conn}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({publish, _Map}, State) ->
    %% TODO
    {noreply, State};
handle_info(ping, State = #state{connection=Con}) ->
    erlang:send_after(25000, self(), ping),
    Res = (catch emqtt:ping(Con)),
    lager:debug("pinging MQTT connection ~p", [Res]),
    {noreply, State};
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

connect(DeviceID, Hostname, Key, Cert) ->
    #{secret := {ecc_compact, PrivKey}} = Key,
    EncodedPrivKey = public_key:der_encode('ECPrivateKey', PrivKey),
    Opts = [{host, Hostname},
            {port, 8883},
            {client_id, DeviceID},
            {logger, {lager, debug}},
            {keepalive, 30},
            {connack_timeout, 5},
            {clean_sess, true},
            {ssl, true},
            {ssl_opts, [{cert, der_encode_cert(Cert)},
                        {key, {'ECPrivateKey', EncodedPrivKey}}]}],
    {ok, C} = emqtt:start_link(Opts),
    {ok, _Props} = emqtt:connect(C),
    {ok, C}.

der_encode_cert(PEMCert) ->
    Cert = public_key:pem_entry_decode(hd(public_key:pem_decode(list_to_binary(PEMCert)))),
    public_key:der_encode('Certificate', Cert).

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

-spec ensure_certificate(pid(), binary()) -> {ok, any(), string()} | {error, any()}.
ensure_certificate(AWS, DeviceID) ->
    case router_devices_sup:lookup_device_worker(DeviceID) of
        {error, _Reason} ->
            {error, {no_device_key, _Reason}};
        {ok, Pid} ->
            Key = router_device_worker:key(Pid),
            case get_principals(AWS, DeviceID) of
                [] ->
                    CSR = create_csr(Key, <<"US">>, <<"California">>, <<"San Francisco">>, <<"Helium">>, DeviceID),
                    CSRReq = #{<<"certificateSigningRequest">> => public_key:pem_encode([public_key:pem_entry_encode('CertificationRequest', CSR)])},
                    Body = binary_to_list(jsx:encode(CSRReq)),
                    case httpc_aws:post(AWS, "iot", "/certificates?setAsActive=true", Body, ?HEADERS) of
                        {error, _Reason, _} ->
                            {error, {certificate_creation_failed, _Reason}};
                        {ok, {_, Res}} ->
                            CertificateArn = proplists:get_value("certificateArn", Res),
                            case attach_certificate(AWS, DeviceID, CertificateArn) of
                                {error, _}=Error ->
                                    Error;
                                ok ->
                                    case get_certificate_from_arn(AWS, CertificateArn) of
                                        {error, _}=Error -> Error;
                                        {ok, Cert} -> {ok, Key, Cert}
                                    end 
                            end
                    end;
                [CertificateArn] ->
                    case get_certificate_from_arn(AWS, CertificateArn) of
                        {error, _}=Error -> Error;
                        {ok, Cert} -> {ok, Key, Cert}
                    end
            end
    end.

get_iot_endpoint(AWS) ->
    case httpc_aws:get(AWS, "iot", "/endpoint", []) of
        {error, _Reason, _} -> {error, {get_endpoint_failed, _Reason}};
        {ok, {_, [{"endpointAddress", Hostname}]}} -> {ok, Hostname}
    end.

get_certificate_from_arn(AWS, CertificateArn) ->
    ["arn", _Partition, "iot", _Region, _Account, Resource] = string:tokens(CertificateArn, ":"),
    ["cert", CertificateId] = string:tokens(Resource, "/"),
    case httpc_aws:get(AWS, "iot", "/certificates/" ++ CertificateId) of
        {error, _Reason, _} ->
            {error, {get_certificate_failed, _Reason}};
        {ok, {_, Data}} ->
            CertificateDesc = proplists:get_value("certificateDescription", Data),
            {ok, proplists:get_value("certificatePem", CertificateDesc)}
    end.

attach_certificate(AWS, DeviceID, CertificateArn) ->
    Headers0 = [{"x-amzn-iot-principal", CertificateArn},
                {"content-type", "text/plain"}],
    case httpc_aws:put(AWS, "iot", "/principal-policies/Helium-Policy", "", Headers0) of
        {error, _Reason, _} ->
            {error, {attach_policy_failed, _Reason}};
        {ok, _} ->
            Headers1 = [{"x-amzn-principal", CertificateArn},
                        {"content-type", "text/plain"}],
            case httpc_aws:put(AWS, "iot", binary_to_list(<<"/things/", DeviceID/binary, "/principals">>), "", Headers1) of
                {error, _Reason, _} -> {error, {attach_principals_failed, _Reason}};
                {ok, _} -> ok
            end
    end.

get_principals(AWS, DeviceID) ->
    case httpc_aws:get(AWS, "iot", binary_to_list(<<"/things/", DeviceID/binary, "/principals">>)) of
        {error, _Reason, _} -> [];
        {ok, {_, Data}} -> proplists:get_value("principals", Data, [])
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
    Signature = public_key:sign(DER, sha256, PrivKey),
    {'CertificationRequest', CRI, {'CertificationRequest_signatureAlgorithm', {1, 2, 840, 10045, 4, 3, 2}, asn1_NOVALUE}, Signature}.

pack_country(Bin) when size(Bin) == 2 ->
    <<19, 2, Bin:2/binary>>.

pack_string(Bin) ->
    Size = byte_size(Bin),
    <<12, Size:8/integer-unsigned, Bin/binary>>.
