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
