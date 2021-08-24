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
    mqtt_cleanup/1
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
    parse_connection_string/1
]).

-export_type([azure/0]).

-define(EXPIRATION_TIME, 3600).
-define(REQUEST_OPTIONS, [with_body, {ssl_options, [{versions, ['tlsv1.2']}]}]).
-define(MQTT_API_VERSION, "/?api-version=2020-06-30").
-define(HTTP_API_VERSION, "/?api-version=2020-03-13").

-record(azure, {
    hub_name :: binary(),
    policy_name :: binary(),
    policy_key :: binary(),
    device_id :: binary(),
    http_url :: binary(),
    http_token :: binary(),
    mqtt_host :: binary(),
    mqtt_username :: binary(),
    mqtt_password :: binary(),
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
    HTTP_SAS_URI = <<HubName/binary, ".azure-devices.net">>,
    SAS_URI =
        <<HubName/binary, ".azure-devices.net/", DeviceID/binary, ?MQTT_API_VERSION>>,

    HttpUrl =
        <<"https://", HubName/binary, ".azure-devices.net/devices/", DeviceID/binary,
            ?HTTP_API_VERSION>>,
    HttpToken = generate_sas_token(HTTP_SAS_URI, PName, PKey, ?EXPIRATION_TIME),

    MqttHost = <<HubName/binary, ".azure-evices.net">>,
    MqttUsername = <<MqttHost/binary, "/", DeviceID/binary, ?MQTT_API_VERSION>>,
    MqttPassword = generate_sas_token(SAS_URI, PName, PKey, ?EXPIRATION_TIME),

    {ok, #azure{
        % General
        hub_name = HubName,
        policy_name = PName,
        policy_key = PKey,
        device_id = DeviceID,
        % HTTP
        http_url = HttpUrl,
        http_token = HttpToken,
        % MQTT
        mqtt_host = MqttHost,
        mqtt_username = MqttUsername,
        mqtt_password = MqttPassword
    }}.

%% -------------------------------------------------------------------
%% MQTT
%% -------------------------------------------------------------------

-spec mqtt_connect(#azure{}) -> {ok, #azure{}} | {error, any()}.
mqtt_connect(
    #azure{
        mqtt_host = Host,
        mqtt_username = Username,
        mqtt_password = Password,
        device_id = DeviceID
    } = Azure
) ->
    Port = 8883,

    {ok, Connection} = emqtt:start_link(#{
        clientid => DeviceID,
        ssl => true,
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
mqtt_publish(#azure{mqtt_connection = Conn, device_id = DeviceID}, Data) ->
    UplinkTopic = <<"devices/", DeviceID/binary, "/messages/events">>,
    try emqtt:publish(Conn, UplinkTopic, Data, 0) of
        Resp ->
            {ok, Resp}
    catch
        _:_ ->
            {error, failed_to_publish}
    end.

-spec mqtt_cleanup(#azure{}) -> {ok, #azure{}}.
mqtt_cleanup(#azure{mqtt_connection = Conn} = Azure) ->
    (catch emqtt:disconnect(Conn)),
    (catch emqtt:stop(Conn)),
    {ok, Azure#azure{mqtt_connection = undefined}}.

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
fetch_device(#azure{http_url = URL, http_token = Token} = _Azure) ->
    Headers = default_headers(Token),

    case hackney:get(URL, Headers, <<>>, ?REQUEST_OPTIONS) of
        {ok, 200, _Headers, Body} ->
            {ok, jsx:decode(Body, [return_maps])};
        Other ->
            {error, Other}
    end.

-spec create_device(#azure{}) -> {ok, map()} | {error, any()}.
create_device(#azure{http_url = URL, http_token = Token, device_id = Name} = _Azure) ->
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
delete_device(#azure{http_url = URL, http_token = Token} = Azure, DeleteType) ->
    Headers =
        case DeleteType of
            explicit ->
                {ok, #{<<"etag">> := ETag}} = ?MODULE:fetch_device(Azure),
                [{<<"If-Match">>, ensure_quoted(ETag)} | ?MODULE:default_headers(Token)];
            force ->
                [{<<"If-Match">>, <<"*">>} | ?MODULE:default_headers(Token)]
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

-spec generate_sas_token(binary(), binary(), binary(), number()) -> binary().
generate_sas_token(URI, PolicyName, PolicyKey, Expires) ->
    ExpireBin = erlang:integer_to_binary(erlang:system_time(seconds) + Expires),
    ToSign = <<URI/binary, "\n", ExpireBin/binary>>,
    Signed = http_uri:encode(base64:encode(crypto:hmac(sha256, base64:decode(PolicyKey), ToSign))),

    <<"SharedAccessSignature ", "sr=", URI/binary, "&sig=", Signed/binary, "&se=", ExpireBin/binary,
        "&skn=", PolicyName/binary>>.

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
            "HostName=test.azure-devices.net;SharedAccessKeyName=TestPolicy;SharedAccessKey=U2hhcmVkQWNjZXNzS2V5"
        )
    ),
    ok.

get_device_test() ->
    application:ensure_all_started(hackney),
    %% application:ensure_all_started(lager),

    {ok, Azure} = ?MODULE:new(
        <<"michael-iot-hub">>,
        <<"device">>,
        <<"B2AUxyck5UgbutoUIgYbyUUeMgmkWOHJa6I+fUuoeA4=">>,
        <<"test-device-2">>
    ),

    {ok, Device} = ?MODULE:fetch_device(Azure),
    lager:info("Retrieved Device ~s", [io_lib:format("~n~120p~n", [Device])]),

    ok.

create_and_delete_device_force_test() ->
    application:ensure_all_started(hackney),

    Name = <<"test-device-force">>,
    {ok, Azure} = ?MODULE:new(
        <<"michael-iot-hub">>,
        <<"device">>,
        <<"B2AUxyck5UgbutoUIgYbyUUeMgmkWOHJa6I+fUuoeA4=">>,
        Name
    ),

    {ok, _DeviceForce} = ?MODULE:create_device(Azure),

    ok = ?MODULE:delete_device(Azure, force),
    lager:info("Deleted Device ~p", [Name]),

    ok.

create_and_delete_device_explicit_test() ->
    application:ensure_all_started(hackney),

    Name = <<"test-device-explicit">>,
    {ok, Azure} = ?MODULE:new(
        <<"michael-iot-hub">>,
        <<"device">>,
        <<"B2AUxyck5UgbutoUIgYbyUUeMgmkWOHJa6I+fUuoeA4=">>,
        Name
    ),

    {ok, _DeviceExplicit} = ?MODULE:create_device(Azure),
    lager:info("Crated Device ~s", [io_lib:format("~n~120p~n", [_DeviceExplicit])]),

    ok = ?MODULE:delete_device(Azure, explicit),
    lager:info("Deleted Device ~p", [Name]),

    ok.

-endif.
