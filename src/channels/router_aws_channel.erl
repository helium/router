%%%-------------------------------------------------------------------
%% @doc
%% == Router AWS Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_aws_channel).

-behaviour(gen_event).

-include_lib("public_key/include/public_key.hrl").

%% ------------------------------------------------------------------
%% gen_event Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_event/2,
         handle_call/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(PING_TIMEOUT, timer:seconds(25)).
-define(HEADERS, [{"content-type", "application/json"}]).
-define(THING_TYPE, <<"Helium-Thing">>).

-record(state, {channel :: router_channel:channel(),
                aws :: pid(),
                connection :: pid(),
                pubtopic :: binary()}).
%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    lager:info("~p init with ~p", [?MODULE, Channel]),
    case setup_aws(Channel, Device) of
        {error, Reason} ->
            {error, Reason};
        {ok, AWS, Endpoint, Key, Cert} ->
            DeviceID = router_channel:device_id(Channel),
            case connect(DeviceID, Endpoint, Key, Cert) of
                {error, Reason} ->
                    {error, Reason};
                {ok, Conn} ->
                    _ = ping(Conn),
                    Topic = <<"$aws/things/", DeviceID/binary, "/shadow/#">>,  
                    {ok, _, _} = emqtt:subscribe(Conn, Topic, 0),
                    #{topic := PubTopic} = router_channel:args(Channel),
                    {ok, #state{channel=Channel, aws=AWS,
                                connection=Conn, pubtopic=PubTopic}}
            end
    end.

handle_event({data, Data}, #state{channel=Channel, connection=Conn, pubtopic=Topic}=State) ->
    DeviceID = router_channel:device_id(Channel),
    ID = router_channel:id(Channel),
    Fcnt = maps:get(sequence, Data),
    case router_channel:dupes(Channel) of
        true ->
            Res = emqtt:publish(Conn, Topic, encode_data(Data), 0),
            ok = handle_publish_res(Res, Channel, Data),
            lager:info("published: ~p result: ~p", [Data, Res]);
        false ->
            case throttle:check(packet_dedup, {DeviceID, ID, Fcnt}) of
                {ok, _, _} ->
                    Res = emqtt:publish(Conn, Topic, encode_data(Data), 0),
                    ok = handle_publish_res(Res, Channel, Data),
                    lager:info("published: ~p result: ~p", [Data, Res]);
                _ ->
                    lager:debug("ignoring duplicate ~p", [Data])
            end
    end,
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info({publish, #{client_pid := Conn}}, #state{connection=Conn}=State) ->
    %% TODO: Handle downlink
    {ok, State};
handle_info({Conn, ping}, #state{connection=Conn}=State) ->
    _ = ping(Conn),
    Res = (catch emqtt:ping(Conn)),
    lager:debug("pinging MQTT connection ~p", [Res]),
    {ok, State};
handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec ping(pid()) -> reference().
ping(Conn) ->
    erlang:send_after(?PING_TIMEOUT, self(), {Conn, ping}).

-spec encode_data(map()) -> binary().
encode_data(#{payload := Payload}=Map) ->
    jsx:encode(maps:put(payload, base64:encode(Payload), Map)).

-spec handle_publish_res(any(), router_channel:channel(), map()) -> ok.
handle_publish_res(Res, Channel, Data) ->
    DeviceWorkerPid = router_channel:device_worker(Channel),
    Payload = maps:get(payload, Data),
    Result0 = #{channel_id => router_channel:id(Channel),
                channel_name => router_channel:name(Channel),
                port => maps:get(port, Data),
                payload => base64:encode(Payload),
                payload_size => erlang:byte_size(Payload), 
                reported_at => erlang:system_time(seconds),
                rssi => maps:get(rssi, Data),
                snr => maps:get(snr, Data),
                hotspot_name => maps:get(hotspot_name, Data),
                category => <<"up">>,
                frame_up => maps:get(sequence, Data)},
    Result1 = case Res of
                  {ok, PacketID} ->
                      maps:merge(Result0, #{status => success, description => list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))});
                  ok ->
                      maps:merge(Result0, #{status => success, description => <<"ok">>});
                  {error, Reason} ->
                      maps:merge(Result0, #{status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))})
              end,
    router_device_worker:report_channel_status(DeviceWorkerPid, Result1).

-spec connect(binary(), binary(), any(), any()) -> {ok, pid()} | {error, any()}.
connect(DeviceID, Hostname, Key, Cert) ->
    #{secret := {ecc_compact, PrivKey}} = Key,
    EncodedPrivKey = public_key:der_encode('ECPrivateKey', PrivKey),
    Opts = [{host, Hostname},
            {port, 8883},
            {clientid, DeviceID},
            {keepalive, 30},
            {clean_start, true},
            {ssl, true},
            {ssl_opts, [{cert, der_encode_cert(Cert)},
                        {key, {'ECPrivateKey', EncodedPrivKey}}]}],
    {ok, C} = emqtt:start_link(Opts),
    case emqtt:connect(C) of
        {ok, _Props} -> {ok, C};
        {error, Reason} -> {error, Reason}
    end.

der_encode_cert(PEMCert) ->
    Cert = public_key:pem_entry_decode(hd(public_key:pem_decode(list_to_binary(PEMCert)))),
    public_key:der_encode('Certificate', Cert).

-spec setup_aws(router_channel:channel(),
                router_device:device()) -> {ok, pid(), binary(), any(), any()}
              | {error, any()}.
setup_aws(Channel, Device) ->
    {ok, AWS} = httpc_aws:start_link(),
    #{aws_access_key := AccessKey,
      aws_secret_key := SecretKey,
      aws_region := Region} = router_channel:args(Channel),
    DeviceID = router_channel:device_id(Channel),
    httpc_aws:set_credentials(AWS, AccessKey, SecretKey),
    httpc_aws:set_region(AWS, Region),
    Funs = [fun ensure_policy/1, fun ensure_thing_type/1, fun ensure_thing/2],
    case ensure(Funs, AWS, DeviceID) of
        {error, _}=Error ->
            Error;
        ok ->
            case get_iot_endpoint(AWS) of
                {error, _}=Error ->
                    Error;
                {ok, Endpoint} ->
                    case ensure_certificate(AWS, Device) of
                        {error, _}=Error ->
                            Error;
                        {ok, Key, Cert} ->
                            {ok, AWS, Endpoint, Key, Cert}
                    end
            end
    end.

-spec ensure([function()], pid(), binary()) -> ok | {error, any()}.
ensure(Funs, AWS, DeviceID) ->
    ensure(Funs, AWS, DeviceID, ok).

-spec ensure([function()], pid(), binary(), ok | {error, any()}) -> ok | {error, any()}.
ensure([], _AWS, _DeviceID, Acc) ->
    Acc;
ensure(_Funs, _AWS, _DeviceID, {error, _}=Error) ->
    Error;
ensure([Fun|Funs], AWS, DeviceID, _Acc) when is_function(Fun, 1) ->
    ensure(Funs, AWS, DeviceID, Fun(AWS));
ensure([Fun|Funs], AWS, DeviceID, _Acc) when is_function(Fun, 2) ->
    ensure(Funs, AWS, DeviceID, Fun(AWS, DeviceID)).

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

-spec ensure_certificate(pid(), router_device:device()) -> {ok, any(), string()} | {error, any()}.
ensure_certificate(AWS, Device) ->
    DeviceID = router_device:id(Device),
    Key = router_device:keys(Device),
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
