%%%-------------------------------------------------------------------
%% @doc
%% == Router Azure Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_azure_channel).

-behaviour(gen_event).

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

-define(CONNECTION_STRING, "HostName=pierre-iot-hub.azure-devices.net;SharedAccessKeyName=TestPolicy;SharedAccessKey=bMNBzrn+5BXtuRmZ6wv5NBS483IW2I/4Za9dDaVq7IE=").

-record(state, {
    channel :: router_channel:channel()
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    ok = router_utils:lager_md(Device),
    lager:info("init with ~p", [Channel]),
    {ok, #state{
        channel = Channel
    }}.

handle_event({data, _UUIDRef, _Data}, State) ->
    lager:debug("got data: ~p", [_Data]),
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call({update, Channel, _Device}, State) ->
    {ok, ok, State#state{
        channel = Channel
    }};
handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

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

-spec get_device(string(), binary(), binary()) -> {ok, map()} | error.
get_device(Hostname, Token, DeviceID) ->
    URI = lists:flatten(
        io_lib:format("~s/devices/~s?api-version=2020-03-13", [Hostname, DeviceID])
    ),
    Headers = [{<<"Authorization">>, Token}],
    URL = "https://" ++ URI,
    lager:info("get_device ~p", [URL]),
    case
        hackney:get(URL, Headers, <<>>, [
            with_body,
            {ssl_options, [{versions, ['tlsv1.2']}]}
        ])
    of
        {ok, 200, _Headers, Body} ->
            {ok, maps:from_list(jsx:decode(Body))};
        Other ->
            lager:warning("failed to fetch device ~p ~p", [DeviceID, Other]),
            error
    end.

-spec create_device(binary(), binary(), binary(), map()) -> {ok, map()} | {error, any()}.
create_device(HostName, Token, DesiredID, DeviceOptions) ->
    URL = lists:flatten(
            io_lib:format("https://~s/devices/~s?api-version=2020-03-13", [HostName, http_uri:encode(DesiredID)])
           ),
    Headers = [
               {<<"Authorization">>, Token},
               {<<"Content-Type">>, <<"application/json; charset=utf-8">>},
               {<<"Accept">>, <<"application/json">>}
              ],

    Auth = #{
             <<"type">> => <<"sas">>,
             <<"symmetricKey">> => #{
                                     <<"primaryKey">>  => <<"">>,
                                     <<"secondaryKey">> => <<"">>
                                    }
            },

    Payload = jsx:encode(maps:merge(DeviceOptions, #{<<"authentication">> =>Auth})),

    lager:info("create_device ~p", [URL]),
    case hackney:put(URL, Headers, Payload, [with_body, {ssl_options, [{versions, ['tlsv1.2']}]}]) of
        {ok, 200, _Headers, Body} ->
            Device = maps:from_list(jsx:decode(Body)),
            {ok, Device};
        Other ->
            lager:warning("failed to create device ~p ~p", [DesiredID, Other]),
            {error, Other}
    end.

-spec delete_device(binary(), binary(), binary(), binary() | force | explicit) -> {ok, map()} | {error, any()}.
delete_device(HostName, Token, DeviceID, force) ->
    delete_device(HostName, Token, DeviceID, <<"*">>);
delete_device(HostName, Token, DeviceID, explicit) ->
    {ok, #{<<"etag">> := ETag}} = get_device(HostName, Token, DeviceID),
    delete_device(HostName, Token, DeviceID, ETag);
delete_device(HostName, Token, DeviceID, ETag) ->
    URL = lists:flatten(
            io_lib:format("https://~s/devices/~s?api-version=2020-03-13", [HostName, http_uri:encode(DeviceID)])
           ),
    Headers = [
               {<<"Authorization">>, Token},
               {<<"Content-Type">>, <<"application/json; charset=utf-8">>},
               {<<"Accept">>, <<"application/json">>},
               {<<"If-Match">>, ETag}
              ],

    case hackney:delete(URL, Headers, <<>>, [with_body, {ssl_options, [{versions, ['tlsv1.2']}]}]) of
        {ok, 204, _Headers, Body} ->
            {ok, Body};
        Other ->
            lager:warning("failed to delete device ~p ~p", [DeviceID, Other]),
            {error, Other}
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

parse_connection_string_test() ->
    ?assertEqual(
        {ok, <<"test.azure-devices.net">>, <<"TestPolicy">>, <<"U2hhcmVkQWNjZXNzS2V5">>},
        parse_connection_string(
            "HostName=test.azure-devices.net;SharedAccessKeyName=TestPolicy;SharedAccessKey=U2hhcmVkQWNjZXNzS2V5"
        )
    ),
    ok.

get_device_test() ->
    application:ensure_all_started(lager),
    application:ensure_all_started(hackney),

    ConnString = ?CONNECTION_STRING,
    {ok, HostName, Policy, Key} = parse_connection_string(ConnString),

    Token = generate_sas_token(
              http_uri:encode(erlang:binary_to_list(HostName)),
              Key,
              Policy,
              _Expiry = 3600
             ),
    DeviceID = <<"test-device-1">>,

    {ok, Device} = get_device(HostName, Token, DeviceID),
    lager:info("Retrieved Device ~s", [io_lib:format("~n~120p~n", [Device])]),

    ok.

create_device_test() ->
    application:ensure_all_started(lager),
    application:ensure_all_started(hackney),

    ConnString = ?CONNECTION_STRING,
    {ok, HostName, Policy, Key} = parse_connection_string(ConnString),


    Token = generate_sas_token(
              http_uri:encode(erlang:binary_to_list(HostName)),
              Key,
              Policy,
              _Expiry = 3600
             ),

    DeviceForceName = <<"test-device-force">>,
    DeviceForceOptions = #{<<"deviceId">> => DeviceForceName},
    DeviceExplicitName = <<"test-device-explicit">>,
    DeviceExplicitOptions = #{<<"deviceID">> => DeviceExplicitName},

    {ok, DeviceForce} = create_device(HostName, Token, DeviceForceName, DeviceForceOptions),
    lager:info("Created Device ~s", [io_lib:format("~n~120p~n", [DeviceForce])]),

    {ok, DeviceExplicit} = create_device(HostName, Token, DeviceExplicitName, DeviceExplicitOptions),
    lager:info("Created Device ~s", [io_lib:format("~n~120p~n", [DeviceExplicit])]),

    ok.

delete_device_force_test() ->
    application:ensure_all_started(lager),
    application:ensure_all_started(hackney),

    ConnString = ?CONNECTION_STRING,
    {ok, HostName, Policy, Key} = parse_connection_string(ConnString),

    DeviceID = <<"test-device-force">>,
    Token = generate_sas_token(
              http_uri:encode(erlang:binary_to_list(HostName)),
              Key,
              Policy,
              _Expiry = 3600
             ),

    {ok, Device} = delete_device(HostName, Token, DeviceID, force),
    lager:info("Deleted Device ~p", [Device]),

    ok.

delete_device_explicit_test() ->
    application:ensure_all_started(lager),
    application:ensure_all_started(hackney),

    ConnString = ?CONNECTION_STRING,
    {ok, HostName, Policy, Key} = parse_connection_string(ConnString),

    DeviceID = <<"test-device-explicit">>,
    Token = generate_sas_token(
              http_uri:encode(erlang:binary_to_list(HostName)),
              Key,
              Policy,
              _Expiry = 3600
             ),

    {ok, Device} = delete_device(HostName, Token, DeviceID, force),
    lager:info("Deleted Device ~p", [Device]),

    ok.

%% get_device_test() ->
%%     application:ensure_all_started(hackney),
%%     application:ensure_all_started(lager),

%%     Hostname = <<"pierre-iot-hub.azure-devices.net">>,
%%     KeyName = <<"iothubowner">>,
%%     Key = <<"XXXX">>,
%%     Expires = 3600,
%%     Token = generate_sas_token(
%%         http_uri:encode(erlang:binary_to_list(Hostname)),
%%         Key,
%%         KeyName,
%%         Expires
%%     ),
%%     DeviceID = <<"test-device-1">>,
%%     {ok, Device} = get_device(Hostname, Token, DeviceID),
%%     lager:notice("Device ~p", [Device]),
%%     ?assert(false),
%%     ok.

generate_sas_token(URI, Key, PolicyName, Expires) ->
    ExpireString = erlang:integer_to_list(erlang:system_time(seconds) + Expires),
    ToSign = URI ++ "\n" ++ ExpireString,
    SAS =
        "SharedAccessSignature sr=" ++
            URI ++
            "&sig=" ++
            http_uri:encode(
                erlang:binary_to_list(
                    base64:encode(crypto:hmac(sha256, base64:decode(Key), ToSign))
                )
            ) ++ "&se=" ++ ExpireString,
    case PolicyName of
        "" ->
            SAS;
        _ ->
            SAS ++ "&skn=" ++ http_uri:encode(erlang:binary_to_list(PolicyName))
    end.

%% create_device_test() ->
%%     application:ensure_all_started(hackney),
%%     application:ensure_all_started(lager),

%%     Hostname = <<"XXX.azure-devices.net">>,
%%     KeyName = <<"XXX">>,
%%     Key = <<"XXXX">>,
%%     Expires = 3600,
%%     Token = generate_sas_token(
%%         http_uri:encode(erlang:binary_to_list(Hostname)),
%%         Key,
%%         KeyName,
%%         Expires
%%     ),
%%     DeviceID = <<"test-device-1">>,

%%     ok.

%% create_certificate() ->
%%     <<SerialNumber:128/integer-unsigned>> = crypto:strong_rand_bytes(16),
%%     Rdn =
%%         {rdnSequence, [
%%             #'AttributeTypeAndValue'{
%%                 type = ?'id-at-countryName',
%%                 value = pack_country(<<"US">>)
%%             },
%%             #'AttributeTypeAndValue'{
%%                 type = ?'id-at-stateOrProvinceName',
%%                 value = pack_string(<<"California">>)
%%             },
%%             #'AttributeTypeAndValue'{
%%                 type = ?'id-at-localityName',
%%                 value = pack_string(<<"San Francisco">>)
%%             },
%%             #'AttributeTypeAndValue'{
%%                 type = ?'id-at-organizationName',
%%                 value = pack_string(<<"Helium">>)
%%             },
%%             #'AttributeTypeAndValue'{
%%                 type = ?'id-at-commonName',
%%                 value = pack_string(<<"Device id and hotsname here?">>)
%%             }
%%         ]},
%%     TBSCertificate = #'TBSCertificate'{
%%         version = 0,
%%         serialNumber = SerialNumber,
%%         signature = #'AlgorithmIdentifier'{
%%             algorithm = ?'ecdsa-with-SHA256',
%%             parameters = asn1_NOVALUE
%%         },
%%         issuer = Rdn,
%%         validity = validity(30 * 12 * 10),
%%         subject = Rdn,
%%         subjectPublicKeyInfo = #'SubjectPublicKeyInfo'{
%%             algorithm = #'AlgorithmIdentifier'{
%%                 algorithm = ?'id-ecPublicKey',
%%                 parameters = <<6, 8, 42, 134, 72, 206, 61, 3, 1, 7>>
%%             },
%%             subjectPublicKey = PublicKey
%%         },
%%         issuerUniqueID = asn1_NOVALUE,
%%         subjectUniqueID = asn1_NOVALUE,
%%         extensions = asn1_NOVALUE
%%     },
%%     DER = public_key:der_encode('TBSCertificate', TBSCertificate),
%%     Signature = public_key:sign(DER, sha256, PrivateKey),
%%     #'Certificate'{
%%         tbsCertificate = TBSCertificate,
%%         signatureAlgorithm = #'AlgorithmIdentifier'{
%%             algorithm = ?md5WithRSAEncryption,
%%             parameters = <<5, 0>>
%%         },
%%         signature = {0, Signature}
%%     }.

%% pack_country(Bin) when size(Bin) == 2 ->
%%     <<19, 2, Bin:2/binary>>.

%% pack_string(Bin) ->
%%     Size = byte_size(Bin),
%%     <<12, Size:8/integer-unsigned, Bin/binary>>.

%% validity(Days) ->
%%     Now = calendar:universal_time(),
%%     Start = minute_before(Now),
%%     {Date, Time} = Start,
%%     StartDays = calendar:date_to_gregorian_days(Date),
%%     EndDays = StartDays + Days,
%%     End = {calendar:gregorian_days_to_date(EndDays), Time},
%%     #'Validity'{
%%         notBefore = datetime_to_utc_time(Start),
%%         notAfter = datetime_to_utc_time(End)
%%     }.

-endif.
