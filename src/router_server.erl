%%%-------------------------------------------------------------------
%% @doc
%% == Router Server ==
%% @end
%%%-------------------------------------------------------------------
-module(router_server).

-behavior(gen_server).

-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").

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

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("init with ~p", [Args]),
    ok = blockchain_state_channels_server:packet_forward(self()),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({packet, Packet}, State) ->
    Data = blockchain_state_channel_packet_v1:packet(Packet),
    lager:info("got data ~p", [Data]),
    case send(Data) of
        {ok, _Ref} ->
            lager:info("~p data sent", [_Ref]);
        {error, _Reason} ->
            lager:error("packet decode failed ~p ~p", [_Reason, Data]);
        _Ref ->
            lager:info("~p data sent", [_Ref])
    end,
    {noreply, State};
handle_info({hackney_response, _Ref, {status, 200, _Reason}}, State) ->
    lager:info("~p got 200/~p", [_Ref, _Reason]),
    {noreply, State};
handle_info({hackney_response, _Ref, {status, _StatusCode, _Reason}}, State) ->
    lager:warning("~p got ~p/~p", [_Ref, _StatusCode, _Reason]),
    {noreply, State};
handle_info({hackney_response, _Ref, done}, State) ->
    lager:info("~p done", [_Ref]),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    lager:error("~p terminated: ~p", [?MODULE, _Reason]).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec send(binary()) -> any() | {error, any()}.
send(Data) ->
    case decode_data(Data) of
        {ok, #helium_LongFiResp_pb{id=_ID, miner_name=_MinerName, kind={_, #helium_LongFiRxPacket_pb{device_id=DID, oui=OUI}=_Packet}}=DecodedData} ->
            lager:info("decoded from ~p (id=~p) data ~p", [_MinerName, _ID, lager:pr(_Packet, ?MODULE)]),
            SendFun = e2qc:cache(console_cache, {OUI, DID}, 300, fun() -> make_send_fun(DID, OUI) end),
            SendFun(Data, DecodedData);
        {error, _Reason}=Error ->
            Error
    end.

-spec decode_data(binary()) -> {ok, #helium_LongFiResp_pb{}} | {error, any()}.
decode_data(Data) ->
    try helium_longfi_pb:decode_msg(Data, helium_LongFiResp_pb) of
        Packet ->
            {ok, Packet}
    catch
        E:R ->
            lager:error("got error trying to decode  ~p", [{E, R}]),
            {error, decoding}
    end.

make_send_fun(DID, OUI) ->
    Endpoint = application:get_env(router, console_endpoint, undefined),
    JWT = get_token(),
    case hackney:get(<<Endpoint/binary, "/api/router/devices/", (list_to_binary(integer_to_list(DID)))/binary, "?oui=", (list_to_binary(integer_to_list(OUI)))/binary>>,
                     [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            JSON = jsx:decode(Body, [return_maps]),
            DeviceID = kvc:path([<<"id">>], JSON),
            Key = base64:decode(kvc:path([<<"key">>], JSON)),
            ChannelFuns = case kvc:path([<<"channels">>], JSON) of
                              [] ->
                                  [fun(_Input, Decoded=#helium_LongFiResp_pb{miner_name=MinerName, kind={_, Packet=#helium_LongFiRxPacket_pb{rssi=RSSI, snr=SNR, payload=Payload, fingerprint=FP, timestamp=Timestamp}}}) ->
                                           spawn(fun() ->
                                                         case check_fingerprint(Packet, Key) of
                                                             ok ->
                                                                 Result = #{id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                            delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                            status => <<"No Channel">>},
                                                                 hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body]);
                                                             Other ->
                                                                 lager:warning("fingerprint mismatch for packet ~p from ~p : expected ~p got ~p", [Decoded, {OUI, DID}, Other, FP])
                                                         end
                                                 end)
                                   end];
                              Channels ->
                                  lists:map(fun(Channel = #{<<"type">> := <<"http">>}) ->
                                                    Headers = kvc:path([<<"credentials">>, <<"headers">>], Channel),
                                                    lager:info("Headers ~p", [Headers]),
                                                    URL = kvc:path([<<"credentials">>, <<"endpoint">>], Channel),
                                                    lager:info("URL ~p", [URL]),
                                                    Method = list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], Channel))),
                                                    lager:info("Method ~p", [Method]),
                                                    ChannelID = kvc:path([<<"name">>], Channel),
                                                    fun(_Encoded, Decoded = #helium_LongFiResp_pb{miner_name=MinerName, kind={_, Packet=#helium_LongFiRxPacket_pb{rssi=RSSI, snr=SNR, payload=Payload, fingerprint=FP, timestamp=Timestamp}}}) ->
                                                            case check_fingerprint(Packet, Key) of
                                                                ok ->
                                                                    Result = try hackney:request(Method, URL, maps:to_list(Headers), packet_to_json(Decoded), [with_body]) of
                                                                                 {ok, StatusCode, _ResponseHeaders, ResponseBody} when StatusCode >=200, StatusCode =< 300 ->
                                                                                     #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                       status => success, description => ResponseBody};
                                                                                 {ok, StatusCode, _ResponseHeaders, ResponseBody} ->
                                                                                     #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                       status => failure, description => <<"ResponseCode: ", (list_to_binary(integer_to_list(StatusCode)))/binary, " Body ", ResponseBody/binary>>};
                                                                                 {error, Reason} ->
                                                                                     #{channel_id => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                       status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))}
                                                                             catch
                                                                                 What:Why:Stacktrace ->
                                                                                     lager:info("Failed to post to channel ~p ~p ~p", [What, Why, Stacktrace]),
                                                                                     #{channel_id => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                       status => failure, description => <<"invalid channel configuration">>}

                                                                             end,
                                                                    lager:info("Result ~p", [Result]),
                                                                    hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body]);
                                                                Other ->
                                                                    lager:warning("fingerprint mismatch for packet ~p from ~p : expected ~p got ~p", [Decoded, {OUI, DID}, Other, FP])
                                                            end
                                                    end
                                            end, Channels)
                          end,
            fun(Input, DecodedInput) ->
                    [ spawn(fun() -> C(Input, DecodedInput) end) || C <- ChannelFuns]
            end;
        Other ->
            lager:warning("unable to get channel ~p", [Other]),
            fun(_, _) ->
                    ok
            end
    end.

-spec get_token() -> binary().
get_token() ->
    Endpoint = application:get_env(router, console_endpoint, undefined),
    Secret = application:get_env(router, console_secret, undefined),
    e2qc:cache(
      console_cache,
      jwt,
      600,
      fun() ->
              case hackney:post(<<Endpoint/binary, "/api/router/sessions">>, [{<<"Content-Type">>, <<"application/json">>}], jsx:encode(#{secret => Secret}) , [with_body]) of
                  {ok, 201, _Headers, Body} ->
                      #{<<"jwt">> := JWT} = jsx:decode(Body, [return_maps]),
                      JWT
              end
      end
     ).


packet_to_json(#helium_LongFiResp_pb{miner_name=MinerName, kind={_,
                                                                 #helium_LongFiRxPacket_pb{rssi=RSSI, payload=Payload, timestamp=_Timestamp,
                                                                                           oui=OUI, device_id=DeviceID, fingerprint=Fingerprint,
                                                                                           sequence=Sequence, spreading=Spreading,
                                                                                           snr=SNR
                                                                                          }}}) ->
    jsx:encode(#{timestamp => erlang:system_time(seconds),
                 oui => OUI,
                 device_id => DeviceID,
                 fingerprint => Fingerprint,
                 sequence => Sequence,
                 spreading => Spreading,
                 payload => base64:encode(Payload),
                 gateway => MinerName,
                 rssi => RSSI,
                 snr => SNR}).

check_fingerprint(DecodedPacket = #helium_LongFiRxPacket_pb{fingerprint=FP}, Key) ->
    case longfi:get_fingerprint(DecodedPacket, Key) of
        FP ->
            ok;
        Other ->
            Other
    end.


%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.