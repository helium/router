%%%-------------------------------------------------------------------
%% @doc
%% == Router Azure IoT Central Channel ==
%%
%% - Ensure device is created in iot-central application.
%% - Ensure device is registered to an underlying iot-hub with the DPS.
%% - Connect and communcate as device over mqtt.
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_iot_central_connection).

-compile([export_all, nowarn_export_all]).
%% TODO: Replace with `uri_string:quote/1' when it get's released.
%% https://github.com/erlang/otp/pull/5700
-compile({nowarn_deprecated_function, [{http_uri, encode, 1}]}).

%% Create API
-export([
    new/4,
    %% flow
    http_device_setup/1,
    mqtt_device_setup/1,
    setup/1
]).

%% HTTP API
-export([
    http_device_get/1,
    http_device_create/1,
    http_device_credentials/1,
    http_device_ensure_exists/1,
    http_device_check_registration/2,
    http_device_register/1
]).

%% MQTT API
-export([
    mqtt_connect/1,
    mqtt_subscribe/1,
    mqtt_publish/2,
    mqtt_response/2,
    mqtt_cleanup/1,
    mqtt_ping/1
]).

%% Helper API
-export([
    generate_mqtt_sas_token/1,
    generate_mqtt_sas_token/3,
    generate_registration_sas_token/2,
    http_device_setup_/1,
    mqtt_device_setup_/1
]).

-export_type([azure/0]).

-define(DPS_API_VERSION, "?api-version=2021-06-01").
-define(IOT_CENTRAL_API_VERSION, "?api-version=1.0").
-define(IOT_CENTRAL_MQTT_USERNAME_API_VERSION, "?api-version=2021-04-12").

-define(MAX_REGISTRATION_ATTEMPTS, 10).

-record(iot_central, {
    %% User provided:
    %% hubname
    prefix :: binary(),
    %% retrieved from central app
    scope_id :: binary(),
    %% generated from iot-central permissions
    api_key :: binary(),

    %% Helium provided:
    %% double duty as device ID and Name
    device_id :: binary(),

    %% May change some day:
    iot_central_host = <<"azureiotcentral.com">> :: binary(),
    dps_host = <<"global.azure-devices-provisioning.net">> :: binary(),

    %% Computed after device creation:
    %%
    device_primary_key :: undefined | binary(),
    %% Able to generate after device is registered in DPS
    mqtt_connection :: undefined | pid(),
    mqtt_host :: undefined | binary(),
    mqtt_username :: undefined | binary(),
    mqtt_port = 8883 :: 8883 | 1883
}).

-type azure() :: #iot_central{}.

-spec new(
    Prefix :: binary(),
    ScopeID :: binary(),
    ApiKey :: binary(),
    DeviceID :: binary()
) -> {ok, #iot_central{}}.
new(Prefix, ScopeID, ApiKey, DeviceID) ->
    {ok, #iot_central{
        prefix = Prefix,
        scope_id = ScopeID,
        api_key = ApiKey,
        device_id = DeviceID
    }}.

%% -------------------------------------------------------------------
%% Flows
%% -------------------------------------------------------------------

-spec setup(#iot_central{}) -> {ok, #iot_central{}}.
setup(#iot_central{} = Central0) ->
    {ok, Central1} = ?MODULE:http_device_setup(Central0),
    {ok, Central2} = ?MODULE:mqtt_device_setup(Central1),
    {ok, Central2}.

-spec http_device_setup(#iot_central{}) -> {ok, #iot_central{}} | {error, any()}.
http_device_setup(#iot_central{} = Central) ->
    %% HTTP setup includes all setup involving HTTP requests.
    %% That results in mostly MQTT values.
    try ?MODULE:http_device_setup_(Central) of
        #{
            device_primary_key := DevicePrimaryKey,
            mqtt_host := MqttHost,
            mqtt_username := MqttUsername,
            mqtt_port := MqttPort
        } ->
            lager:debug("http device setup success"),
            {ok, Central#iot_central{
                device_primary_key = DevicePrimaryKey,
                mqtt_host = MqttHost,
                mqtt_username = MqttUsername,
                mqtt_port = MqttPort
            }}
    catch
        _:Err:_Stack ->
            lager:error("http device setup failed: ~p", [Err]),
            {error, Err}
    end.

-spec mqtt_device_setup(#iot_central{}) -> {ok, #iot_central{}} | {error, any()}.
mqtt_device_setup(#iot_central{} = Central) ->
    %% MQTT setup includes all setup touching emqtt.
    try ?MODULE:mqtt_device_setup_(Central) of
        #{mqtt_connection := MqttConnection} ->
            {ok, Central#iot_central{
                mqtt_connection = MqttConnection
            }}
    catch
        _:Err -> {error, Err}
    end.

%% Flow Helpers ======================================================

-spec http_device_setup_(#iot_central{}) -> map().
http_device_setup_(#iot_central{} = Central0) ->
    ok = ?MODULE:http_device_ensure_exists(Central0),
    {ok, Central1} = ?MODULE:http_device_credentials(Central0),
    {ok, RetryAfter, _Body} = ?MODULE:http_device_register(Central1),
    {ok, Central2} = ?MODULE:http_device_check_registration(Central1, RetryAfter),
    #{
        device_primary_key => Central2#iot_central.device_primary_key,
        mqtt_host => Central2#iot_central.mqtt_host,
        mqtt_username => Central2#iot_central.mqtt_username,
        mqtt_port => Central2#iot_central.mqtt_port
    }.

-spec mqtt_device_setup_(#iot_central{}) -> map().
mqtt_device_setup_(#iot_central{} = Central0) ->
    {ok, Central1} = ?MODULE:mqtt_connect(Central0),
    {ok, _, _} = ?MODULE:mqtt_subscribe(Central1),
    #{
        mqtt_connection => Central1#iot_central.mqtt_connection
    }.

%% -------------------------------------------------------------------
%% MQTT
%% -------------------------------------------------------------------

-spec mqtt_connect(#iot_central{}) -> {ok, #iot_central{}} | {error, any()}.
mqtt_connect(
    #iot_central{
        device_id = DeviceID,
        mqtt_host = Host,
        mqtt_username = Username,
        mqtt_port = Port
    } = Central
) ->
    Password = generate_mqtt_sas_token(Central),

    {ok, Connection} = emqtt:start_link(#{
        clientid => erlang:binary_to_list(DeviceID),
        ssl => Port == 8883,
        host => erlang:binary_to_list(Host),
        port => Port,
        username => erlang:binary_to_list(Username),
        password => erlang:binary_to_list(Password),
        keepalive => 180,
        clean_start => false,
        force_ping => true,
        active => true
    }),

    case emqtt:connect(Connection) of
        {ok, _Props} ->
            lager:debug("iot central mqtt successfully connected"),
            {ok, Central#iot_central{mqtt_connection = Connection}};
        Err ->
            lager:error("iot central mqtt could not connect [error: ~p]", [Err]),
            {error, Err}
    end.

-spec mqtt_subscribe(#iot_central{}) -> {ok, any(), any()} | {error, any()}.
mqtt_subscribe(#iot_central{mqtt_connection = Conn, device_id = DeviceID}) ->
    DownlinkTopic = <<"devices/", DeviceID/binary, "/messages/devicebound/#">>,
    lager:debug("  subscribing to ~p", [DownlinkTopic]),
    emqtt:subscribe(Conn, DownlinkTopic, 0).

-spec mqtt_publish(#iot_central{}, binary()) ->
    {ok, any()} | {error, not_connected | failed_to_publish}.
mqtt_publish(#iot_central{mqtt_host = Host, mqtt_connection = Conn, device_id = DeviceID}, Data) ->
    UplinkTopic = <<"devices/", DeviceID/binary, "/messages/events/">>,
    try emqtt:publish(Conn, UplinkTopic, Data, 0) of
        Resp ->
            {ok, Resp}
    catch
        _Class:_Reason ->
            lager:warning("could not publish to iot-central ~p: ~p", [Host, {_Class, _Reason}]),
            {error, failed_to_publish}
    end.

-spec mqtt_response(
    #iot_central{},
    Payload :: map()
) -> {ok, binary()} | {error, unrecognized_response}.
mqtt_response(
    #iot_central{mqtt_connection = Connection},
    #{client_pid := ClientPid, payload := Payload}
) ->
    case ClientPid == Connection of
        true -> {ok, Payload};
        false -> {error, unrecognized_response}
    end.

-spec mqtt_cleanup(#iot_central{}) -> {ok, #iot_central{}}.
mqtt_cleanup(#iot_central{mqtt_connection = Conn} = Central) ->
    (catch emqtt:disconnect(Conn)),
    (catch emqtt:stop(Conn)),
    {ok, Central#iot_central{mqtt_connection = undefined}}.

-spec mqtt_ping(#iot_central{}) -> ok | {error, any()}.
mqtt_ping(#iot_central{mqtt_connection = Conn, mqtt_host = Host}) ->
    try emqtt:ping(Conn) of
        pong ->
            ok
    catch
        _Class:Reason ->
            lager:warning("could not ping azure ~p: ~p", [Host, {_Class, Reason}]),
            {error, Reason}
    end.

%% -------------------------------------------------------------------
%% HTTP
%% -------------------------------------------------------------------

%% IOT Central Functions =============================================

-spec http_device_ensure_exists(Central :: #iot_central{}) -> ok | {error, any()}.
http_device_ensure_exists(#iot_central{} = Central) ->
    case ?MODULE:http_device_get(Central) of
        {ok, _} ->
            lager:debug("  device already exists"),
            ok;
        _ ->
            lager:debug("  creating device"),
            case ?MODULE:http_device_create(Central) of
                {ok, _} -> ok;
                Err -> Err
            end
    end.

-spec http_device_get(#iot_central{}) -> {ok, map()} | {error, any()}.
http_device_get(#iot_central{
    prefix = Prefix,
    iot_central_host = Host,
    api_key = Token,
    device_id = DeviceID
}) ->
    FetchURL = format_url(
        "https://{{prefix}}.{{host}}/api/devices/{{device_id}}{{api_version}}",
        [
            {prefix, Prefix},
            {host, Host},
            {device_id, DeviceID},
            {api_version, ?IOT_CENTRAL_API_VERSION}
        ]
    ),
    Headers = default_headers(Token),
    case hackney:get(FetchURL, Headers, <<>>, [with_body]) of
        {ok, 200, _, Body} -> {ok, jsx:decode(Body, [return_maps])};
        Other -> {error, Other}
    end.

-spec http_device_create(#iot_central{}) -> {ok, map()} | {error, any()}.
http_device_create(#iot_central{
    prefix = Prefix,
    iot_central_host = Host,
    api_key = Token,
    device_id = DeviceID
}) ->
    CreateURL =
        format_url(
            "https://{{prefix}}.{{host}}/api/devices/{{device_id}}{{api_version}}",
            [
                {prefix, Prefix},
                {host, Host},
                {device_id, DeviceID},
                {api_version, ?IOT_CENTRAL_API_VERSION}
            ]
        ),
    Payload = #{
        'displayName' => DeviceID,
        'enabled' => true,
        'simulated' => false
    },
    Headers = default_headers(Token),
    case hackney:put(CreateURL, Headers, jsx:encode(Payload), [with_body]) of
        {ok, 200, _, Body} -> {ok, jsx:decode(Body)};
        Other -> {error, Other}
    end.

-spec http_device_credentials(#iot_central{}) -> {ok, #iot_central{}} | {error, any()}.
http_device_credentials(
    #iot_central{
        prefix = Prefix,
        iot_central_host = Host,
        api_key = ApiKey,
        device_id = DeviceID
    } =
        Central
) ->
    URL = format_url(
        "https://{{prefix}}.{{host}}/api/devices/{{device_id}}/credentials{{api_version}}",
        [
            {prefix, Prefix},
            {host, Host},
            {device_id, DeviceID},
            {api_version, ?IOT_CENTRAL_API_VERSION}
        ]
    ),
    Headers = default_headers(ApiKey),
    case hackney:get(URL, Headers, <<>>, [with_body]) of
        {ok, 200, _, Body} ->
            try jsx:decode(Body, [return_maps]) of
                #{<<"symmetricKey">> := #{<<"primaryKey">> := PrimaryKey}} ->
                    {ok, Central#iot_central{device_primary_key = PrimaryKey}}
            catch
                _:Err ->
                    {error, Err}
            end;
        Other ->
            {error, Other}
    end.

%% DPS Functions ===============================================================

-spec http_device_check_registration(
    Central :: #iot_central{},
    RetryWaitTimeSeconds :: non_neg_integer()
) ->
    {ok, #iot_central{}} | {error, any()}.
http_device_check_registration(#iot_central{device_id = DeviceID} = Central, RetryWaitSeconds) ->
    case http_device_check_registration(Central, RetryWaitSeconds / 2, 0) of
        {ok, AssignedHub} ->
            {ok, Central#iot_central{
                mqtt_host = AssignedHub,
                mqtt_username =
                    <<AssignedHub/binary, "/", DeviceID/binary, "/",
                        ?IOT_CENTRAL_MQTT_USERNAME_API_VERSION>>
            }};
        Other ->
            Other
    end.

-spec http_device_check_registration(
    Central :: #iot_central{},
    RetryWaitTimeSeconds :: float(),
    Attempts :: non_neg_integer()
) -> {ok, AssignedHub :: binary()} | {error, any()}.
http_device_check_registration(
    #iot_central{prefix = Prefix, device_id = DeviceID} = _Central,
    _RetryWaitSeconds,
    ?MAX_REGISTRATION_ATTEMPTS
) ->
    lager:warning(
        "max retries, bailing on checking registration [prefix: ~p] [device_id: ~p]",
        [Prefix, DeviceID]
    ),
    {error, max_registration_attempts};
http_device_check_registration(Central, RetryWaitSeconds, Attempts) ->
    lager:debug("getting assignment [attempts: ~p]", [Attempts]),
    case do_http_device_check_registration(Central) of
        %% {ok, _} = Resp ->
        %%     Resp;
        {error, {device_not_assigned, _}} ->
            timer:sleep(erlang:round(RetryWaitSeconds * 1000)),
            http_device_check_registration(Central, RetryWaitSeconds, Attempts + 1);
        Other ->
            Other
    end.

-spec do_http_device_check_registration(Central :: #iot_central{}) ->
    {ok, AssignedHub :: binary()}
    | {error, any()}.
do_http_device_check_registration(#iot_central{device_primary_key = undefined}) ->
    {error, device_credentials_unfetched};
do_http_device_check_registration(
    #iot_central{
        scope_id = ScopeID,
        dps_host = Host,
        device_id = DeviceID,
        device_primary_key = DevicePrimaryKey
    } = _Central
) ->
    URL = format_url(
        "https://{{host}}/{{scope_id}}/registrations/{{device_id}}{{api_version}}",
        [{host, Host}, {scope_id, ScopeID}, {device_id, DeviceID}, {api_version, ?DPS_API_VERSION}]
    ),

    TokenPath = erlang:list_to_binary(io_lib:format("~s/registrations/~s", [ScopeID, DeviceID])),
    Token = generate_registration_sas_token(TokenPath, DevicePrimaryKey),
    Headers = default_headers(Token),
    Payload = #{registrationId => DeviceID},
    case hackney:post(URL, Headers, jsx:encode(Payload), [with_body]) of
        {ok, 200, _, Body} ->
            try jsx:decode(Body, [return_maps]) of
                #{<<"status">> := <<"assigned">>, <<"assignedHub">> := AssignedHub} ->
                    {ok, AssignedHub};
                #{<<"status">> := Status} ->
                    {error, {device_not_assigned, Status}}
            catch
                _:Err ->
                    {error, Err}
            end;
        Other ->
            {error, Other}
    end.

-spec http_device_register(Central :: #iot_central{}) ->
    {ok, RetryAfterSeconds :: non_neg_integer(), RequestBody :: map()} | {error, any()}.
http_device_register(#iot_central{device_primary_key = undefined}) ->
    {error, device_credentials_unfetched};
http_device_register(
    #iot_central{
        scope_id = ScopeID,
        dps_host = Host,
        device_id = DeviceID,
        device_primary_key = DevicePrimaryKey
    } = _Central
) ->
    URL = format_url(
        "https://{{host}}/{{scope_id}}/registrations/{{device_id}}/register{{api_version}}",
        [{host, Host}, {scope_id, ScopeID}, {device_id, DeviceID}, {api_version, ?DPS_API_VERSION}]
    ),

    TokenPath = erlang:list_to_binary(io_lib:format("~s/registrations/~s", [ScopeID, DeviceID])),
    Token = generate_registration_sas_token(TokenPath, DevicePrimaryKey),
    Headers = default_headers(Token),
    Payload = #{registrationId => DeviceID},
    case hackney:put(URL, Headers, jsx:encode(Payload), [with_body]) of
        {ok, 202, RespHeaders, Body} ->
            %% Reported in seconds
            RetryAfter = erlang:binary_to_integer(
                proplists:get_value(<<"Retry-After">>, RespHeaders, <<"1">>)
            ),
            lager:debug("  registration successful"),
            {ok, RetryAfter, jsx:decode(Body, [return_maps])};
        Other ->
            lager:debug("  registration failed"),
            {error, Other}
    end.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

-spec default_headers(Token :: binary()) -> propslist:proplist().
default_headers(Token) ->
    [
        {<<"Authorization">>, Token},
        {<<"Content-Type">>, <<"application/json;charset=utf-8">>},
        {<<"Accept">>, <<"application/json">>}
    ].

-spec generate_registration_sas_token(Path :: binary(), DevicePrimaryKey :: binary()) -> binary().
generate_registration_sas_token(Path, DevicePrimaryKey) ->
    OneHour = 3600,
    ExpireBin = erlang:integer_to_binary(erlang:system_time(seconds) + OneHour),

    ToSign = <<Path/binary, "\n", ExpireBin/binary>>,
    Signed = base64:encode(crypto:mac(hmac, sha256, base64:decode(DevicePrimaryKey), ToSign)),

    <<
        "SharedAccessSignature ",
        "sr=",
        Path/binary,
        "&sig=",
        %% NOTE: It's important that only this part of the token is encoded
        (http_uri:encode(Signed))/binary,
        "&se=",
        ExpireBin/binary,
        "&skn=registration"
    >>.

-spec generate_mqtt_sas_token(#iot_central{}) -> binary().
generate_mqtt_sas_token(#iot_central{
    mqtt_host = Host,
    device_id = DeviceID,
    device_primary_key = SigningKey
}) ->
    URI = format_url(
        "{{host}}/devices/{{device_id}}",
        [{host, Host}, {device_id, DeviceID}]
    ),
    Expiry = erlang:integer_to_binary(erlang:system_time(seconds) + 3600),
    generate_mqtt_sas_token(URI, SigningKey, Expiry).

%% Similar to azure-iot-hub but no policy name. Signing Key is the device's primary key.
-spec generate_mqtt_sas_token(
    URI :: binary(),
    DeviceKey :: binary(),
    ExpireBin :: binary()
) -> binary().
generate_mqtt_sas_token(URI, SigningKey, ExpireBin) ->
    %% TODO: Replace with `uri_string:quote/1' when it get's released.
    %% https://github.com/erlang/otp/pull/5700
    EncodedURI = http_uri:encode(URI),
    ToSign = <<EncodedURI/binary, "\n", ExpireBin/binary>>,
    Signed = base64:encode(crypto:mac(hmac, sha256, base64:decode(SigningKey), ToSign)),

    %% NOTE: Do not double encode URI
    Params = uri_string:compose_query([
        {<<"sr">>, URI},
        {<<"sig">>, Signed},
        {<<"se">>, ExpireBin}
    ]),
    <<"SharedAccessSignature ", Params/binary>>.

format_url(S, Args) when erlang:is_list(S) ->
    format_url(erlang:list_to_binary(S), Args);
format_url(Bin, Args) ->
    bbmustache:render(Bin, Args, [{key_type, atom}]).
