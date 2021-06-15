-module(router_azure_connection).

-export([new/1]).
-export([fetch_device/2, create_device/2, delete_device/3]).

-define(EXPIRATION_TIME, 3600).
-define(REQUEST_OPTIONS, [with_body, {ssl_options, [{versions, ['tlsv1.2']}]}]).

-define(CONNECTION_STRING,
    "HostName=pierre-iot-hub.azure-devices.net;SharedAccessKeyName=TestPolicy;SharedAccessKey=bMNBzrn+5BXtuRmZ6wv5NBS483IW2I/4Za9dDaVq7IE="
).

-record(azure_connection, {
    connection_string :: binary(),
    host_name :: binary(),
    policy :: binary(),
    key :: binary(),
    token :: binary()
}).

-spec new(binary()) -> #azure_connection{}.
new(ConnectionString) ->
    {ok, Hostname, Policy, Key} = parse_connection_string(ConnectionString),
    {ok, Token} = generate_sas_token(Hostname, Key, Policy, ?EXPIRATION_TIME),
    {ok, #azure_connection{
        connection_string = ConnectionString,
        host_name = Hostname,
        policy = Policy,
        key = Key,
        token = Token
    }}.

-spec fetch_device(#azure_connection{}, binary()) -> {ok, map()} | {error, any()}.
fetch_device(#azure_connection{} = Conn, Name) ->
    URL = make_url(Conn, Name),
    Headers = default_headers(Conn),

    lager:info("get device ~p", [URL]),
    case hackney:get(URL, Headers, <<>>, ?REQUEST_OPTIONS) of
        {ok, 200, _Headers, Body} ->
            {ok, maps:from_list(jsx:decode(Body))};
        Other ->
            {error, Other}
    end.

-spec create_device(#azure_connection{}, binary()) -> {ok, map()} | {error, any()}.
create_device(#azure_connection{} = Conn, Name) ->
    URL = make_url(Conn, Name),
    Headers = default_headers(Conn),

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

    lager:info("create device ~p", [URL]),
    case hackney:put(URL, Headers, EncodedPayload, ?REQUEST_OPTIONS) of
        {ok, 200, _Headers, Body} ->
            Device = maps:from_list(jsx:decode(Body)),
            {ok, Device};
        Other ->
            lager:warning("failed to create device ~p ~p", [Name, Other]),
            {error, Other}
    end.

-spec delete_device(#azure_connection{}, binary(), force | explicit) -> ok | {error, any()}.
delete_device(#azure_connection{} = Conn, Name, explicit) ->
    {ok, #{<<"etag">> := ETag}} = ?MODULE:fetch_device(Conn, Name),

    URL = make_url(Conn, Name),
    Headers = [{<<"If-Match">>, ensure_quoted(ETag)} | default_headers(Conn)],

    lager:info("deleting device ~p", [URL]),
    case hackney:delete(URL, Headers, <<>>, ?REQUEST_OPTIONS) of
        {ok, 204, _Headers, _Body} ->
            ok;
        Other ->
            lager:warning("failed to explicitly delete device ~p ~p", [Name, Other]),
            {error, Other}
    end;
delete_device(#azure_connection{} = Conn, Name, force) ->
    URL = make_url(Conn, Name),
    Headers = [{<<"If-Match">>, <<"*">>} | default_headers(Conn)],

    lager:info("deleting device ~p", [URL]),
    case hackney:delete(URL, Headers, <<>>, ?REQUEST_OPTIONS) of
        {ok, 204, _Headers, _Body} ->
            ok;
        Other ->
            lager:warning("failed to force delete device ~p ~p", [Name, Other]),
            {error, Other}
    end.

%% -------------------------------------------------------------------
%% Internal Functions
%% -------------------------------------------------------------------

-spec parse_connection_string(string()) -> {ok, string(), string(), string()} | error.
parse_connection_string(Str) ->
    Pairs = string:tokens(Str, ";"),
    KV = [erlang:list_to_tuple(binary:split(erlang:list_to_binary(P), <<"=">>)) || P <- Pairs],
    case
        {lists:keyfind(<<"HostName">>, 1, KV), lists:keyfind(<<"SharedAccessKeyName">>, 1, KV),
            lists:keyfind(<<"SharedAccessKey">>, 1, KV)}
    of
        {{<<"HostName">>, HostName}, {<<"SharedAccessKeyName">>, KeyName},
            {<<"SharedAccessKey">>, Key}} ->
            {ok, HostName, KeyName, Key};
        _ ->
            error
    end.

-spec generate_sas_token(binary(), binary(), binary(), number()) -> {ok, binary()}.
generate_sas_token(URI, Key, PolicyName, Expires) ->
    ExpireBin = erlang:integer_to_binary(erlang:system_time(seconds) + Expires),
    ToSign = <<URI/binary, "\n", ExpireBin/binary>>,
    Signed = http_uri:encode(base64:encode(crypto:hmac(sha256, base64:decode(Key), ToSign))),

    SAS =
        <<"SharedAccessSignature ", "sr=", URI/binary, "&sig=", Signed/binary, "&se=",
            ExpireBin/binary, "&skn=", PolicyName/binary>>,
    {ok, SAS}.

-spec default_headers(#azure_connection{}) -> proplists:proplist().
default_headers(#azure_connection{token = Token}) ->
    [
        {<<"Authorization">>, Token},
        {<<"Content-Type">>, <<"application/json; charset=utf-8">>},
        {<<"Accept">>, <<"application/json">>}
    ].

-spec make_url(#azure_connection{}, binary()) -> binary().
make_url(#azure_connection{host_name = Hostname}, Name) ->
    <<"https://", Hostname/binary, "/devices/", Name/binary, "?api-version=2020-03-13">>.

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
        {ok, <<"test.azure-devices.net">>, <<"TestPolicy">>, <<"U2hhcmVkQWNjZXNzS2V5">>},
        parse_connection_string(
            "HostName=test.azure-devices.net;SharedAccessKeyName=TestPolicy;SharedAccessKey=U2hhcmVkQWNjZXNzS2V5"
        )
    ),
    ok.

get_device_test() ->
    application:ensure_all_started(hackney),

    ConnString = ?CONNECTION_STRING,
    {ok, Conn} = ?MODULE:new(ConnString),

    {ok, Device} = ?MODULE:fetch_device(Conn, <<"test-device-1">>),
    lager:info("Retrieved Device ~s", [io_lib:format("~n~120p~n", [Device])]),

    ok.

create_and_delete_device_force_test() ->
    application:ensure_all_started(hackney),

    ConnString = ?CONNECTION_STRING,
    {ok, Conn} = ?MODULE:new(ConnString),

    Name = <<"test-device-force">>,
    {ok, _DeviceForce} = ?MODULE:create_device(Conn, Name),

    ok = ?MODULE:delete_device(Conn, Name, force),
    lager:info("Deleted Device ~p", [Name]),

    ok.

create_and_delete_device_explicit_test() ->
    application:ensure_all_started(hackney),

    ConnString = ?CONNECTION_STRING,
    {ok, Conn} = ?MODULE:new(ConnString),

    Name = <<"test-device-explicit">>,
    {ok, _DeviceExplicit} = ?MODULE:create_device(Conn, Name),
    lager:info("Crated Device ~s", [io_lib:format("~n~120p~n", [_DeviceExplicit])]),

    ok = ?MODULE:delete_device(Conn, Name, explicit),
    lager:info("Deleted Device ~p", [Name]),

    ok.

-endif.
