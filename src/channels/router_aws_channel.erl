%%%-------------------------------------------------------------------
%% @doc
%% == Router AWS Channel ==
%%
%% Handles connection with AWS.
%% Publishes messages to AWS MQTT
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_aws_channel).

-behaviour(gen_event).

-include_lib("public_key/include/public_key.hrl").

%% ------------------------------------------------------------------
%% gen_event Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_event/2,
    handle_call/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(PING_TIMEOUT, timer:seconds(25)).
-define(BACKOFF_MIN, timer:seconds(10)).
-define(BACKOFF_MAX, timer:minutes(5)).
-define(HEADERS, [{"content-type", "application/json"}]).
-define(THING_TYPE, <<"Helium-Thing">>).

-record(state, {
    channel :: router_channel:channel(),
    channel_id :: binary(),
    device :: router_device:device(),
    connection :: pid() | undefined,
    connection_backoff :: backoff:backoff(),
    endpoint :: binary(),
    uplink_topic :: binary(),
    downlink_topic :: binary(),
    ping :: reference() | undefined,
    aws :: pid(),
    key :: map(),
    cert :: string()
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    ok = router_utils:lager_md(Device),
    ChannelID = router_channel:id(Channel),
    DeviceID = router_device:id(Device),
    lager:info("[~s] ~p init with ~p", [ChannelID, ?MODULE, Channel]),
    #{topic := UplinkTopic} = router_channel:args(Channel),
    DownlinkTopic = <<"helium/devices/", DeviceID/binary, "/down">>,
    case setup_aws(Channel, Device) of
        {error, Reason} ->
            {error, Reason};
        {ok, AWS, Endpoint, Keys, Cert} ->
            Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
            send_connect_after(ChannelID, 0),
            {ok, #state{
                channel = Channel,
                channel_id = ChannelID,
                device = Device,
                connection_backoff = Backoff,
                endpoint = Endpoint,
                uplink_topic = UplinkTopic,
                downlink_topic = DownlinkTopic,
                aws = AWS,
                key = Keys,
                cert = Cert
            }}
    end.

handle_event({data, UUIDRef, Data}, #state{channel = Channel} = State0) ->
    Pid = router_channel:controller(Channel),

    Response = publish(Data, State0),

    RequestReport = make_request_report(Response, Data, State0),
    ok = router_device_channels_worker:report_request(Pid, UUIDRef, Channel, RequestReport),

    State1 =
        case Response of
            {error, failed_to_publish} ->
                #state{channel_id = ChannelID, connection_backoff = Backoff0} = State0,
                Backoff1 = reconnect(ChannelID, Backoff0),
                State0#state{connection_backoff = Backoff1};
            _ ->
                State0
        end,

    ResponseReport = make_response_report(Response, Channel),
    ok = router_device_channels_worker:report_response(Pid, UUIDRef, Channel, ResponseReport),

    {ok, State1};
handle_event(_Msg, #state{channel_id = ChannelID} = State) ->
    lager:warning("[~s] rcvd unknown cast msg: ~p", [ChannelID, _Msg]),
    {ok, State}.

handle_call({update, Channel, Device}, State) ->
    {swap_handler, ok, swapped, State, router_channel:handler(Channel), [Channel, Device]};
handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info(
    {?MODULE, connect, ChannelID},
    #state{
        channel_id = ChannelID,
        device = Device,
        connection = OldConn,
        connection_backoff = Backoff0,
        endpoint = Endpoint,
        downlink_topic = DownlinkTopic,
        ping = TimerRef,
        key = Key,
        cert = Cert
    } = State
) ->
    ok = cleanup_connection(OldConn),
    _ = (catch erlang:cancel_timer(TimerRef)),
    DeviceID = router_device:id(Device),
    case connect(DeviceID, Endpoint, Key, Cert) of
        {ok, Conn} ->
            case emqtt:subscribe(Conn, DownlinkTopic, 0) of
                {ok, _, _} ->
                    lager:info("[~s] connected to : ~p (~p) and subscribed to ~p", [
                        ChannelID,
                        Endpoint,
                        Conn,
                        DownlinkTopic
                    ]),
                    {_, Backoff1} = backoff:succeed(Backoff0),
                    {ok, State#state{
                        connection = Conn,
                        connection_backoff = Backoff1,
                        endpoint = Endpoint,
                        ping = ping(ChannelID)
                    }};
                {error, _SubReason} ->
                    lager:error("[~s] failed to subscribe to ~p: ~p", [
                        ChannelID,
                        DownlinkTopic,
                        _SubReason
                    ]),
                    Backoff1 = reconnect(ChannelID, Backoff0),
                    {ok, State#state{connection_backoff = Backoff1}}
            end;
        {error, _ConnReason} ->
            lager:error("[~s] failed to connect to ~p: ~p", [ChannelID, Endpoint, _ConnReason]),
            Backoff1 = reconnect(ChannelID, Backoff0),
            {ok, State#state{connection_backoff = Backoff1}}
    end;
%% Ignore connect message not for us
handle_info({?MODULE, connect, _}, State) ->
    {ok, State};
handle_info(
    {?MODULE, ping, ChannelID},
    #state{
        channel_id = ChannelID,
        connection = Conn,
        connection_backoff = Backoff0,
        ping = TimerRef
    } = State
) ->
    _ = (catch erlang:cancel_timer(TimerRef)),
    try emqtt:ping(Conn) of
        pong ->
            lager:debug("[~s] pinged MQTT connection ~p successfully", [ChannelID, Conn]),
            {ok, State#state{ping = ping(ChannelID)}}
    catch
        _:_ ->
            lager:error("[~s] failed to ping MQTT connection ~p", [ChannelID, Conn]),
            Backoff1 = reconnect(ChannelID, Backoff0),
            {ok, State#state{connection_backoff = Backoff1}}
    end;
handle_info(
    {publish, #{client_pid := Conn, payload := Payload}},
    #state{connection = Conn, channel = Channel} = State
) ->
    Controller = router_channel:controller(Channel),
    router_device_channels_worker:handle_downlink(Controller, Payload, Channel),
    {ok, State};
handle_info(
    {'EXIT', Conn, {_Type, _Reason}},
    #state{
        channel_id = ChannelID,
        connection = Conn,
        connection_backoff = Backoff0,
        ping = TimerRef
    } = State
) ->
    _ = (catch erlang:cancel_timer(TimerRef)),
    lager:error("[~s] got a EXIT message: ~p ~p", [ChannelID, _Type, _Reason]),
    Backoff1 = reconnect(ChannelID, Backoff0),
    {ok, State#state{connection_backoff = Backoff1}};
handle_info({disconnected, _Type, _Reason}, #state{channel_id = ChannelID} = State) ->
    lager:error("[~s] got a disconnected message: ~p ~p", [ChannelID, _Type, _Reason]),
    {ok, State};
%% Ignore connect message not for us
handle_info({_, ping, _}, State) ->
    {ok, State};
handle_info(_Msg, #state{channel_id = ChannelID} = State) ->
    lager:warning("[~s] rcvd unknown info msg: ~p", [ChannelID, _Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{connection = Conn}) ->
    ok = cleanup_connection(Conn).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec publish(map(), #state{}) -> {ok, any()} | {error, not_connected | failed_to_publish}.
publish(_Data, #state{connection = undefined}) ->
    {error, not_connected};
publish(Data, #state{
    channel = Channel,
    channel_id = ChannelID,
    connection = Conn,
    uplink_topic = Topic
}) ->
    Body = router_channel:encode_data(Channel, Data),

    try emqtt:publish(Conn, Topic, Body, 0) of
        Resp ->
            lager:debug("[~s] published: ~p result: ~p", [ChannelID, Data, Resp]),
            {ok, Resp}
    catch
        _:_ ->
            %% TODO: log more of the errors
            lager:error("[~s] failed to publish", [ChannelID]),
            {error, failed_to_publish}
    end.

-spec ping(binary()) -> reference().
ping(ChannelID) ->
    erlang:send_after(?PING_TIMEOUT, self(), {?MODULE, ping, ChannelID}).

-spec send_connect_after(ChannelId :: binary(), Delay :: non_neg_integer()) -> reference().
send_connect_after(ChannelId, Delay) ->
    erlang:send_after(Delay, self(), {?MODULE, connect, ChannelId}).

-spec reconnect(binary(), backoff:backoff()) -> backoff:backoff().
reconnect(ChannelID, Backoff0) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    send_connect_after(ChannelID, Delay),
    Backoff1.

-spec cleanup_connection(pid()) -> ok.
cleanup_connection(Conn) ->
    (catch emqtt:disconnect(Conn)),
    (catch emqtt:stop(Conn)),
    ok.

-spec make_request_report({ok | error, any()}, any(), #state{}) -> map().
make_request_report({error, Reason}, Data, #state{
    channel = Channel,
    endpoint = Endpoint,
    uplink_topic = Topic
}) ->
    %% Helium Error
    #{
        request => #{
            endpoint => Endpoint,
            topic => Topic,
            qos => 0,
            body => router_channel:encode_data(Channel, Data)
        },
        status => error,
        description => erlang:list_to_binary(io_lib:format("Error: ~p", [Reason]))
    };
make_request_report(Request, Data, #state{
    channel = Channel,
    endpoint = Endpoint,
    uplink_topic = Topic
}) ->
    Request = #{
        endpoint => Endpoint,
        topic => Topic,
        qos => 0,
        body => router_channel:encode_data(Channel, Data)
    },
    case Request of
        {error, Reason} ->
            %% Emqtt Error
            Description = list_to_binary(io_lib:format("Error: ~p", [Reason])),
            #{request => Request, status => error, description => Description};
        ok ->
            #{request => Request, status => success, description => <<"published">>};
        {ok, _} ->
            #{request => Request, status => success, description => <<"published">>}
    end.

-spec make_response_report({ok | error, any()}, router_channel:channel()) -> map().
make_response_report({error, Reason}, Channel) ->
    #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel),
        response => #{},
        status => error,
        description => erlang:list_to_binary(io_lib:format("Error: ~p", [Reason]))
    };
make_response_report(Res, Channel) ->
    Result0 = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel)
    },

    case Res of
        ok ->
            maps:merge(Result0, #{
                response => #{},
                status => success,
                description => <<"ok">>
            });
        {ok, PacketID} ->
            maps:merge(Result0, #{
                response => #{packet_id => PacketID},
                status => success,
                description => list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))
            });
        {error, Reason} ->
            maps:merge(Result0, #{
                response => #{},
                status => error,
                description => list_to_binary(io_lib:format("~p", [Reason]))
            })
    end.

-spec connect(
    DeviceID :: binary(),
    Hostname :: binary(),
    Keys :: map(),
    Cert :: any()
) -> {ok, MQTTConn :: pid()} | {error, any()}.
connect(DeviceID, Hostname, Key, Cert) ->
    #{secret := {ecc_compact, PrivKey}} = Key,
    EncodedPrivKey = public_key:der_encode('ECPrivateKey', PrivKey),
    Opts = [
        {host, erlang:binary_to_list(Hostname)},
        {port, 8883},
        {clientid, DeviceID},
        {keepalive, 30},
        {clean_start, true},
        {ssl, true},
        {ssl_opts, [
            {cert, der_encode_cert(Cert)},
            {key, {'ECPrivateKey', EncodedPrivKey}}
        ]}
    ],
    {ok, C} = emqtt:start_link(Opts),
    case emqtt:connect(C) of
        {ok, _Props} -> {ok, C};
        {error, Reason} -> {error, Reason}
    end.

-spec der_encode_cert(string()) -> binary().
der_encode_cert(PEMCert) ->
    Cert = public_key:pem_entry_decode(hd(public_key:pem_decode(list_to_binary(PEMCert)))),
    public_key:der_encode('Certificate', Cert).

-spec setup_aws(
    router_channel:channel(),
    router_device:device()
) -> {ok, AWSPid :: pid(), Endpoint :: binary(), Key :: map(), Cert :: any()} | {error, any()}.
setup_aws(Channel, Device) ->
    {ok, AWS} = httpc_aws:start_link(),
    #{
        aws_access_key := AccessKey,
        aws_secret_key := SecretKey,
        aws_region := Region
    } = router_channel:args(Channel),
    DeviceID = router_channel:device_id(Channel),
    httpc_aws:set_credentials(AWS, AccessKey, SecretKey),
    httpc_aws:set_region(AWS, Region),
    PassesAll =
        lists:foldl(
            fun
                (_, {error, _} = Err) -> Err;
                (Fn, ok) when is_function(Fn, 1) -> Fn(AWS);
                (Fn, ok) when is_function(Fn, 2) -> Fn(AWS, DeviceID)
            end,
            ok,
            [fun ensure_policy/1, fun ensure_thing_type/1, fun ensure_thing/2]
        ),
    case PassesAll of
        {error, _} = Error ->
            Error;
        ok ->
            case get_iot_endpoint(AWS) of
                {error, _} = Error ->
                    Error;
                {ok, Endpoint} ->
                    case ensure_certificate(AWS, Device) of
                        {error, _} = Error ->
                            Error;
                        {ok, Keys, Cert} ->
                            {ok, AWS, erlang:list_to_binary(Endpoint), Keys, Cert}
                    end
            end
    end.

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
            PolicyString = jsx:encode(Policy),
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
            case
                httpc_aws:post(
                    AWS,
                    "iot",
                    binary_to_list(<<"/things/", DeviceID/binary>>),
                    Body,
                    ?HEADERS
                )
            of
                {error, _Reason, _} -> {error, _Reason};
                {ok, _} -> ok
            end;
        {error, _Reason, _} ->
            {error, _Reason};
        {ok, _} ->
            ok
    end.

-spec ensure_certificate(pid(), router_device:device()) ->
    {ok, Keys :: map(), Cert :: string()} | {error, any()}.
ensure_certificate(AWS, Device) ->
    DeviceID = router_device:id(Device),
    Keys = router_device:ecc_compact(Device),
    case get_principals(AWS, DeviceID) of
        [] ->
            CSR = create_csr(
                Keys,
                <<"US">>,
                <<"California">>,
                <<"San Francisco">>,
                <<"Helium">>,
                DeviceID
            ),
            CSRReq = #{
                <<"certificateSigningRequest">> => public_key:pem_encode([
                    public_key:pem_entry_encode('CertificationRequest', CSR)
                ])
            },
            Body = binary_to_list(jsx:encode(CSRReq)),
            case httpc_aws:post(AWS, "iot", "/certificates?setAsActive=true", Body, ?HEADERS) of
                {error, _Reason, _} ->
                    {error, {certificate_creation_failed, _Reason}};
                {ok, {_, Res}} ->
                    CertificateArn = proplists:get_value("certificateArn", Res),
                    case attach_certificate(AWS, DeviceID, CertificateArn) of
                        {error, _} = Error ->
                            Error;
                        ok ->
                            case get_certificate_from_arn(AWS, CertificateArn) of
                                {error, _} = Error -> Error;
                                {ok, Cert} -> {ok, Keys, Cert}
                            end
                    end
            end;
        [CertificateArn] ->
            case get_certificate_from_arn(AWS, CertificateArn) of
                {error, _} = Error -> Error;
                {ok, Cert} -> {ok, Keys, Cert}
            end
    end.

-spec get_iot_endpoint(AWSPid :: pid()) -> {ok, Hostname :: string()} | {error, any()}.
get_iot_endpoint(AWS) ->
    case httpc_aws:get(AWS, "iot", "/endpoint", []) of
        {error, _Reason, _} -> {error, {get_endpoint_failed, _Reason}};
        {ok, {_, [{"endpointAddress", Hostname}]}} -> {ok, Hostname}
    end.

-spec get_certificate_from_arn(AWSPid :: pid(), CertArn :: string()) ->
    {ok, Cert :: string()} | {error, any()}.
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

-spec attach_certificate(pid(), binary(), string()) -> ok | {error, any()}.
attach_certificate(AWS, DeviceID, CertificateArn) ->
    Headers0 = [
        {"x-amzn-iot-principal", CertificateArn},
        {"content-type", "text/plain"}
    ],
    case httpc_aws:put(AWS, "iot", "/principal-policies/Helium-Policy", "", Headers0) of
        {error, _Reason, _} ->
            {error, {attach_policy_failed, _Reason}};
        {ok, _} ->
            Headers1 = [
                {"x-amzn-principal", CertificateArn},
                {"content-type", "text/plain"}
            ],
            case
                httpc_aws:put(
                    AWS,
                    "iot",
                    binary_to_list(<<"/things/", DeviceID/binary, "/principals">>),
                    "",
                    Headers1
                )
            of
                {error, _Reason, _} -> {error, {attach_principals_failed, _Reason}};
                {ok, _} -> ok
            end
    end.

-spec get_principals(AWSPid :: pid(), DeviceID :: binary()) -> list().
get_principals(AWS, DeviceID) ->
    case
        httpc_aws:get(AWS, "iot", binary_to_list(<<"/things/", DeviceID/binary, "/principals">>))
    of
        {error, _Reason, _} -> [];
        {ok, {_, Data}} -> proplists:get_value("principals", Data, [])
    end.

-spec create_csr(
    Keys :: map(),
    Country :: binary(),
    State :: binary(),
    Location :: binary(),
    Organization :: binary(),
    CommonName :: binary()
) ->
    {'CertificationRequest', CertRequestInfo :: tuple(), CertRequestSigAlgorithm :: tuple(),
        Signature :: binary()}.
create_csr(
    #{
        secret := {ecc_compact, PrivKey},
        public := {ecc_compact, {{'ECPoint', PubKey}, _}}
    },
    Country,
    State,
    Location,
    Organization,
    CommonName
) ->
    CRI =
        {'CertificationRequestInfo', v1,
            {rdnSequence, [
                [{'AttributeTypeAndValue', {2, 5, 4, 6}, pack_country(Country)}],
                [{'AttributeTypeAndValue', {2, 5, 4, 8}, pack_string(State)}],
                [{'AttributeTypeAndValue', {2, 5, 4, 7}, pack_string(Location)}],
                [{'AttributeTypeAndValue', {2, 5, 4, 10}, pack_string(Organization)}],
                [{'AttributeTypeAndValue', {2, 5, 4, 3}, pack_string(CommonName)}]
            ]},
            {'CertificationRequestInfo_subjectPKInfo',
                {'CertificationRequestInfo_subjectPKInfo_algorithm', {1, 2, 840, 10045, 2, 1},
                    {asn1_OPENTYPE, <<6, 8, 42, 134, 72, 206, 61, 3, 1, 7>>}},
                PubKey},
            []},

    DER = public_key:der_encode('CertificationRequestInfo', CRI),
    Signature = public_key:sign(DER, sha256, PrivKey),
    {'CertificationRequest', CRI,
        {'CertificationRequest_signatureAlgorithm', {1, 2, 840, 10045, 4, 3, 2}, asn1_NOVALUE},
        Signature}.

-spec pack_country(binary()) -> binary().
pack_country(Bin) when size(Bin) == 2 ->
    <<19, 2, Bin:2/binary>>.

-spec pack_string(binary()) -> binary().
pack_string(Bin) ->
    Size = byte_size(Bin),
    <<12, Size:8/integer-unsigned, Bin/binary>>.
