-module(router_azure_connection).

%% Create API
-export([
    from_connection_string/2,
    new/4
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

%% HTTP API
-export([
    ensure_device_exists/1,
    fetch_device/1,
    create_device/1,
    delete_device/2
]).

%% Helper API
-export([
    parse_connection_string/1,
    connection_information/2,
    generate_http_sas_token/1,
    generate_mqtt_sas_token/1
]).

-export_type([azure/0]).

%% longest expiration time for azure is 365 days
-define(EXPIRATION_TIME, timer:hours(25)).
-define(REQUEST_OPTIONS, [with_body, {ssl_options, [{versions, ['tlsv1.2']}]}]).
-define(MQTT_API_VERSION, "/?api-version=2018-06-30").
-define(HTTP_API_VERSION, "/?api-version=2020-03-13").
-define(AZURE_HOST, <<".azure-devices.net">>).

-record(azure, {
    hub_name :: binary(),
    policy_name :: binary(),
    policy_key :: binary(),
    device_id :: binary(),
    http_url :: binary(),
    http_sas_uri :: binary(),
    mqtt_host :: binary(),
    mqtt_port :: 1883 | 8883,
    mqtt_username :: binary(),
    mqtt_sas_uri :: binary(),
    mqtt_connection :: pid() | undefined
}).

-type azure() :: #azure{}.

-spec from_connection_string(binary(), binary()) -> {ok, #azure{}} | {error, any()}.
from_connection_string(ConnString, DeviceID) ->
    case ?MODULE:parse_connection_string(ConnString) of
        {ok, HubName, PName, PKey} ->
            ?MODULE:new(HubName, PName, PKey, DeviceID);
        error ->
            {error, invalid_connection_string}
    end.

new(HubName, PName, PKey, DeviceID) ->
    #{
        http_sas_uri := HttpSasUri,
        http_url := HttpUrl,
        mqtt_sas_uri := MqttSasUri,
        mqtt_host := MqttHost,
        mqtt_port := MqttPort,
        mqtt_username := MqttUsername
    } = ?MODULE:connection_information(HubName, DeviceID),

    {ok, #azure{
        % General
        hub_name = HubName,
        policy_name = PName,
        policy_key = PKey,
        device_id = DeviceID,
        % HTTP
        http_url = HttpUrl,
        http_sas_uri = HttpSasUri,
        % MQTT
        mqtt_host = MqttHost,
        mqtt_port = MqttPort,
        mqtt_username = MqttUsername,
        mqtt_sas_uri = MqttSasUri
    }}.

-spec connection_information(binary(), binary()) -> map().
connection_information(HubName, DeviceID) ->
    HttpSasUri = <<HubName/binary, ?AZURE_HOST/binary>>,
    HttpUrl =
        <<"https://", HubName/binary, ?AZURE_HOST/binary, "/devices/", DeviceID/binary,
            ?HTTP_API_VERSION>>,

    MqttSasUri =
        <<HubName/binary, ?AZURE_HOST/binary, "/", DeviceID/binary, ?MQTT_API_VERSION>>,
    MqttHost = <<HubName/binary, ?AZURE_HOST/binary>>,
    MqttUsername = <<MqttHost/binary, "/", DeviceID/binary, ?MQTT_API_VERSION>>,
    #{
        http_sas_uri => HttpSasUri,
        http_url => HttpUrl,
        mqtt_sas_uri => MqttSasUri,
        mqtt_host => MqttHost,
        mqtt_port => 8883,
        mqtt_username => MqttUsername
    }.

%% -------------------------------------------------------------------
%% MQTT
%% -------------------------------------------------------------------

-spec mqtt_connect(#azure{}) -> {ok, #azure{}} | {error, any()}.
mqtt_connect(
    #azure{
        mqtt_host = Host,
        mqtt_port = Port,
        mqtt_username = Username,
        device_id = DeviceID
    } = Azure
) ->
    Password = generate_mqtt_sas_token(Azure),

    {ok, Connection} = emqtt:start_link(#{
        clientid => DeviceID,
        ssl => Port == 8883,
        ssl_opts => [{verify, verify_none}],
        host => erlang:binary_to_list(Host),
        port => Port,
        username => Username,
        password => Password,
        keepalive => 30,
        clean_start => false,
        force_ping => true,
        active => true
    }),

    case emqtt:connect(Connection) of
        {ok, _Props} ->
            {ok, Azure#azure{mqtt_connection = Connection}};
        Err ->
            lager:error("azure mqtt could not connect ~p", [Err]),
            {error, Err}
    end.

-spec mqtt_subscribe(#azure{}) -> {ok, any(), any()} | {error, any()}.
mqtt_subscribe(#azure{mqtt_connection = Conn, device_id = DeviceID}) ->
    DownlinkTopic = <<"devices/", DeviceID/binary, "/messages/devicebound/#">>,
    emqtt:subscribe(Conn, DownlinkTopic, 0).

-spec mqtt_publish(#azure{}, binary()) -> {ok, any()} | {error, not_connected | failed_to_publish}.
mqtt_publish(#azure{mqtt_connection = undefined}, _Data) ->
    {error, not_connected};
mqtt_publish(#azure{mqtt_connection = Conn, device_id = DeviceID, mqtt_host = Host}, Data) ->
    UplinkTopic = <<"devices/", DeviceID/binary, "/messages/events">>,
    try emqtt:publish(Conn, UplinkTopic, Data, 0) of
        Resp ->
            {ok, Resp}
    catch
        _Class:_Reason ->
            lager:warning("could not publish to azure ~p: ~p", [Host, {_Class, _Reason}]),
            {error, failed_to_publish}
    end.

-spec mqtt_response(#azure{}, map()) -> {ok, binary()} | {error, unrecognized_response}.
mqtt_response(#azure{mqtt_connection = Connection}, #{client_pid := ClientPid, payload := Payload}) ->
    case ClientPid == Connection of
        true -> {ok, Payload};
        false -> {error, unrecognized_response}
    end.

-spec mqtt_cleanup(#azure{}) -> {ok, #azure{}}.
mqtt_cleanup(#azure{mqtt_connection = Conn} = Azure) ->
    (catch emqtt:disconnect(Conn)),
    (catch emqtt:stop(Conn)),
    {ok, Azure#azure{mqtt_connection = undefined}}.

-spec mqtt_ping(#azure{}) -> ok | {error, any()}.
mqtt_ping(#azure{mqtt_connection = Conn, mqtt_host = Host}) ->
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

-spec ensure_device_exists(#azure{}) -> ok | {error, any()}.
ensure_device_exists(#azure{} = Azure) ->
    case ?MODULE:fetch_device(Azure) of
        {ok, _} ->
            ok;
        _ ->
            case ?MODULE:create_device(Azure) of
                {ok, _} ->
                    ok;
                Err ->
                    Err
            end
    end.

-spec fetch_device(#azure{}) -> {ok, map()} | {error, any()}.
fetch_device(#azure{http_url = URL} = Azure) ->
    Token = generate_http_sas_token(Azure),
    Headers = default_headers(Token),

    case hackney:get(URL, Headers, <<>>, ?REQUEST_OPTIONS) of
        {ok, 200, _Headers, Body} ->
            {ok, jsx:decode(Body, [return_maps])};
        Other ->
            {error, Other}
    end.

-spec create_device(#azure{}) -> {ok, map()} | {error, any()}.
create_device(#azure{http_url = URL, device_id = Name} = Azure) ->
    Token = generate_http_sas_token(Azure),
    Headers = default_headers(Token),

    PayloadMap = #{
        <<"deviceId">> => Name,
        <<"authentication">> => #{
            <<"type">> => <<"sas">>,
            <<"symmetricKey">> => #{
                <<"primaryKey">> => <<"">>,
                <<"secondaryKey">> => <<"">>
            }
        }
    },
    EncodedPayload = jsx:encode(PayloadMap),

    case hackney:put(URL, Headers, EncodedPayload, ?REQUEST_OPTIONS) of
        {ok, 200, _Headers, Body} ->
            {ok, jsx:decode(Body, [return_maps])};
        Other ->
            {error, Other}
    end.

-spec delete_device(#azure{}, force | explicit) -> ok | {error, any()}.
delete_device(#azure{http_url = URL} = Azure, DeleteType) ->
    Token = generate_http_sas_token(Azure),
    Headers =
        case DeleteType of
            explicit ->
                {ok, #{<<"etag">> := ETag}} = ?MODULE:fetch_device(Azure),
                [{<<"If-Match">>, ensure_quoted(ETag)} | default_headers(Token)];
            force ->
                [{<<"If-Match">>, <<"*">>} | default_headers(Token)]
        end,

    case hackney:delete(URL, Headers, <<>>, ?REQUEST_OPTIONS) of
        {ok, 204, _Headers, _Body} ->
            ok;
        Other ->
            {error, Other}
    end.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

-spec parse_connection_string(binary()) -> {ok, binary(), binary(), binary()} | error.
parse_connection_string(Str) ->
    {ok, KV} = clean_connection_string(Str),
    case
        {
            lists:keyfind(<<"HostName">>, 1, KV),
            lists:keyfind(<<"SharedAccessKeyName">>, 1, KV),
            lists:keyfind(<<"SharedAccessKey">>, 1, KV)
        }
    of
        {
            {<<"HostName">>, HostName},
            {<<"SharedAccessKeyName">>, KeyName},
            {<<"SharedAccessKey">>, Key}
        } ->
            [HubName | _] = binary:split(HostName, <<".">>),
            {ok, HubName, KeyName, Key};
        _ ->
            error
    end.

-spec generate_http_sas_token(#azure{}) -> binary().
generate_http_sas_token(#azure{http_sas_uri = URI, policy_name = PName, policy_key = PKey}) ->
    generate_sas_token(URI, PName, PKey, ?EXPIRATION_TIME).

-spec generate_mqtt_sas_token(#azure{}) -> binary().
generate_mqtt_sas_token(#azure{mqtt_sas_uri = URI, policy_name = PName, policy_key = PKey}) ->
    generate_sas_token(URI, PName, PKey, ?EXPIRATION_TIME).

-spec generate_sas_token(binary(), binary(), binary(), number()) -> binary().
generate_sas_token(URI, PolicyName, PolicyKey, Expires) ->
    EncodedURI = http_uri:encode(URI),
    ExpireBin = erlang:integer_to_binary(erlang:system_time(seconds) + Expires),
    ToSign = <<EncodedURI/binary, "\n", ExpireBin/binary>>,
    Signed = http_uri:encode(base64:encode(crypto:hmac(sha256, base64:decode(PolicyKey), ToSign))),

    <<"SharedAccessSignature ", "sr=", EncodedURI/binary, "&sig=", Signed/binary, "&se=",
        ExpireBin/binary, "&skn=", PolicyName/binary>>.

-spec clean_connection_string(ConnectionString :: binary()) -> {ok, list(tuple())}.
clean_connection_string(ConnectionString) ->
    Pairs = binary:split(ConnectionString, <<";">>, [global]),
    KV = [erlang:list_to_tuple(binary:split(P, <<"=">>)) || P <- Pairs],
    {ok, KV}.

-spec default_headers(binary()) -> proplists:proplist().
default_headers(Token) ->
    [
        {<<"Authorization">>, Token},
        {<<"Content-Type">>, <<"application/json; charset=utf-8">>},
        {<<"Accept">>, <<"application/json">>}
    ].

%%--------------------------------------------------------------------
%% @doc
%% ETags need to be quoted _inside_ their strings.
%% @end
%%--------------------------------------------------------------------
-spec ensure_quoted(binary()) -> binary().
ensure_quoted(<<$", _/binary>> = Bin) -> Bin;
ensure_quoted(Bin) -> <<$", Bin/binary, $">>.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

parse_connection_string_test() ->
    ?assertEqual(
        {ok, <<"test">>, <<"TestPolicy">>, <<"U2hhcmVkQWNjZXNzS2V5">>},
        parse_connection_string(
            <<"HostName=test.azure-devices.net;SharedAccessKeyName=TestPolicy;SharedAccessKey=U2hhcmVkQWNjZXNzS2V5">>
        )
    ),
    ok.

%% get_device_test() ->
%%     application:ensure_all_started(hackney),
%%     %% application:ensure_all_started(lager),

%%     {ok, Azure} = ?MODULE:new(
%%         <<"michael-iot-hub">>,
%%         <<"device">>,
%%         <<"B2AUxyck5UgbutoUIgYbyUUeMgmkWOHJa6I+fUuoeA4=">>,
%%         <<"test-device-2">>
%%     ),

%%     {ok, Device} = ?MODULE:fetch_device(Azure),
%%     lager:info("Retrieved Device ~s", [io_lib:format("~n~120p~n", [Device])]),

%%     ok.

%% create_and_delete_device_force_test() ->
%%     application:ensure_all_started(hackney),

%%     Name = <<"test-device-force">>,
%%     {ok, Azure} = ?MODULE:new(
%%         <<"michael-iot-hub">>,
%%         <<"device">>,
%%         <<"B2AUxyck5UgbutoUIgYbyUUeMgmkWOHJa6I+fUuoeA4=">>,
%%         Name
%%     ),

%%     {ok, _DeviceForce} = ?MODULE:create_device(Azure),

%%     ok = ?MODULE:delete_device(Azure, force),
%%     lager:info("Deleted Device ~p", [Name]),

%%     ok.

%% create_and_delete_device_explicit_test() ->
%%     application:ensure_all_started(hackney),

%%     Name = <<"test-device-explicit">>,
%%     {ok, Azure} = ?MODULE:new(
%%         <<"michael-iot-hub">>,
%%         <<"device">>,
%%         <<"B2AUxyck5UgbutoUIgYbyUUeMgmkWOHJa6I+fUuoeA4=">>,
%%         Name
%%     ),

%%     {ok, _DeviceExplicit} = ?MODULE:create_device(Azure),
%%     lager:info("Crated Device ~s", [io_lib:format("~n~120p~n", [_DeviceExplicit])]),

%%     ok = ?MODULE:delete_device(Azure, explicit),
%%     lager:info("Deleted Device ~p", [Name]),

%%     ok.

-endif.
