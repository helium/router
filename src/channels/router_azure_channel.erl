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

-define(BACKOFF_MIN, timer:seconds(10)).
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    channel :: router_channel:channel(),
    channel_id :: binary(),
    azure :: router_azure_connection:azure(),
    conn_backoff :: backoff:backoff(),
    conn_backoff_ref :: reference() | undefined
}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init({[Channel, Device], _}) ->
    ok = router_utils:lager_md(Device),
    ChannelID = router_channel:id(Channel),
    lager:info("init azure with ~p", [Channel]),
    case setup_azure(Channel) of
        {ok, Account} ->
            Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
            send_connect_after(ChannelID, 0),
            {ok, #state{
                channel = Channel,
                channel_id = ChannelID,
                azure = Account,
                conn_backoff = Backoff
            }};
        Err ->
            lager:warning("could not setup azure connection ~p", [Err]),
            Err
    end.

handle_event(
    {data, UUIDRef, Data},
    #state{azure = Azure, channel = Channel, channel_id = ChannelID} = State0
) ->
    lager:debug("got data: ~p", [Data]),

    EncodedData = router_channel:encode_data(Channel, Data),
    Response = router_azure_connection:mqtt_publish(Azure, EncodedData),

    RequestReport = make_request_report(Response, Data, State0),
    Pid = router_channel:controller(Channel),
    ok = router_device_channels_worker:report_request(Pid, UUIDRef, Channel, RequestReport),

    State1 =
        case Response of
            {error, failed_to_publish} ->
                lager:error("[~s] failed to publish", [ChannelID]),
                reconnect(State0);
            _ ->
                lager:debug("[~s] published result: ~p data: ~p", [ChannelID, Response, EncodedData]),
                State0
        end,

    ResponseReport = make_response_report(Response, Channel),
    ok = router_device_channels_worker:report_response(Pid, UUIDRef, Channel, ResponseReport),

    {ok, State1};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call({update, Channel, Device}, State) ->
    {swap_handler, ok, swapped, State, router_channel:handler(Channel), [Channel, Device]};
handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info({?MODULE, connect, ChannelID}, #state{channel_id = ChannelID} = State) ->
    {ok, connect(State)};
%% Ignore connect message not for us
handle_info({?MODULE, connect, _}, State) ->
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

-spec setup_azure(router_channel:channel()) ->
    {ok, router_azure_connection:azure()} | {error, any()}.
setup_azure(Channel) ->
    #{
        azure_hub_name := HubName,
        azure_policy_name := PolicyName,
        azure_policy_key := PolicyKey
    } = router_channel:args(Channel),

    DeviceID = router_channel:device_id(Channel),
    {ok, Account} = router_azure_connection:new(HubName, PolicyName, PolicyKey, DeviceID),

    case router_azure_connection:ensure_device_exists(Account) of
        ok -> {ok, Account};
        Err -> Err
    end.

-spec connect(#state{}) -> #state{}.
connect(#state{azure = Azure0, conn_backoff = Backoff0, channel_id = ChannelID} = State) ->
    {ok, Azure1} = router_azure_connection:mqtt_cleanup(Azure0),

    case router_azure_connection:mqtt_connect(Azure1) of
        {ok, Azure2} ->
            case router_azure_connection:mqtt_subscribe(Azure2) of
                {ok, _, _} ->
                    lager:info("[~s] connected and subscribed", [ChannelID]),
                    {_, Backoff1} = backoff:succeed(Backoff0),
                    State#state{
                        conn_backoff = Backoff1,
                        azure = Azure2
                    };
                {error, _SubReason} ->
                    lager:error("[~s] failed to subscribe: ~p", [ChannelID, _SubReason]),
                    reconnect(State#state{azure = Azure2})
            end;
        {error, _ConnReason} ->
            lager:error("[~s] failed to connect to: ~p", [ChannelID, _ConnReason]),
            reconnect(State)
    end.

-spec reconnect(#state{}) -> #state{}.
reconnect(#state{channel_id = ChannelID, conn_backoff = Backoff0} = State) ->
    {Delay, Backoff1} = backoff:fail(Backoff0),
    TimerRef1 = send_connect_after(ChannelID, Delay),
    State#state{
        conn_backoff = Backoff1,
        conn_backoff_ref = TimerRef1
    }.

-spec send_connect_after(ChannelID :: binary(), Delay :: non_neg_integer()) -> reference().
send_connect_after(ChannelID, Delay) ->
    lager:info("[~s] trying connect in ~p", [ChannelID, Delay]),
    erlang:send_after(Delay, self(), {?MODULE, connect, ChannelID}).

%% ------------------------------------------------------------------
%% Reporting
%% ------------------------------------------------------------------

-spec make_request_report({ok | error, any()}, any(), #state{}) -> map().
make_request_report({error, Reason}, Data, #state{channel = Channel}) ->
    %% Helium Error
    #{
        request => #{
            qos => 0,
            body => router_channel:encode_data(Channel, Data)
        },
        status => error,
        description => erlang:list_to_binary(io_lib:format("Error: ~p", [Reason]))
    };
make_request_report({ok, Response}, Data, #state{channel = Channel}) ->
    Request = #{
        qos => 0,
        body => router_channel:encode_data(Channel, Data)
    },
    case Response of
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
make_response_report({ok, Response}, Channel) ->
    Result0 = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel)
    },

    case Response of
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

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

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
