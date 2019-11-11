%%%-------------------------------------------------------------------
%% @doc
%% == Console Stream ==
%% Routes a packet depending on Helium Console provided information.
%% @end
%%%-------------------------------------------------------------------
-module(console_stream).

-behavior(libp2p_framed_stream).

-include("router.hrl").
-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
         server/4,
         client/2,
         add_stream_handler/1,
         version/0,
         send/2
        ]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
         init/3,
         handle_data/3,
         handle_info/3
        ]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(VERSION, "simple_http/1.0.0").

-record(state, {cargo :: string() | undefined}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

-spec add_stream_handler(pid()) -> ok.
add_stream_handler(Swarm) ->
    ok = libp2p_swarm:add_stream_handler(
           Swarm,
           ?VERSION,
           {libp2p_framed_stream, server, [?MODULE, self()]}
          ).

-spec version() -> string().
version() ->
    ?VERSION.

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(server, _Conn, _Args) ->
    CragoEndpoint = application:get_env(router, cargo_endpoint, undefined),
    {ok, #state{cargo=CragoEndpoint}};
init(client, _Conn, _Args) ->
    {ok, #state{}}.

handle_data(server, Data, #state{cargo=CragoEndpoint}=State) ->
    lager:info("got data ~p", [Data]),
    case send(Data, CragoEndpoint) of
        {ok, _Ref} ->
            lager:info("~p data sent", [_Ref]);
        {error, _Reason} ->
            lager:error("packet decode failed ~p ~p", [_Reason, Data]);
        _Ref ->
            lager:info("~p data sent", [_Ref])
    end,
    {noreply, State};
handle_data(_Type, _Bin, State) ->
    lager:warning("~p got data ~p", [_Type, _Bin]),
    {noreply, State}.

handle_info(server, {hackney_response, _Ref, {status, 200, _Reason}}, State) ->
    lager:info("~p got 200/~p", [_Ref, _Reason]),
    {noreply, State};
handle_info(server, {hackney_response, _Ref, {status, _StatusCode, _Reason}}, State) ->
    lager:warning("~p got ~p/~p", [_Ref, _StatusCode, _Reason]),
    {noreply, State};
handle_info(server, {hackney_response, _Ref, done}, State) ->
    lager:info("~p done", [_Ref]),
    {noreply, State};
handle_info(_Type, _Msg, State) ->
    lager:debug("~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec send(binary(), string()) -> any().
send(Data, CragoEndpoint) ->
    case decode_data(Data) of
        {ok, #helium_LongFiResp_pb{id=_ID, miner_name=_MinerName, kind={_, #helium_LongFiRxPacket_pb{oui=2}=_Packet}}} ->
            lager:info("decoded from ~p (id=~p) data ~p", [_MinerName, _ID, lager:pr(_Packet, ?MODULE)]),
            send_to_cargo(Data, CragoEndpoint);
        {ok, #helium_LongFiResp_pb{id=_ID, miner_name=_MinerName, kind={_, #helium_LongFiRxPacket_pb{device_id=DID, oui=OUI}=_Packet}}=DecodedData} ->
            lager:info("decoded from ~p (id=~p) data ~p", [_MinerName, _ID, lager:pr(_Packet, ?MODULE)]),
            SendFun = e2qc:cache(console_cache, {OUI, DID}, 300, fun() -> make_send_fun(DID, OUI) end),
            SendFun(Data, DecodedData);
        {error, _Reason}=Error ->
            Error
    end.

send_to_cargo(Data, CragoEndpoint) ->
    Headers = [{<<"Content-Type">>, <<"application/octet-stream">>}],
    Options = [{pool, ?HTTP_POOL}, async],
    hackney:post(CragoEndpoint, Headers, Data, Options).

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
                                                                    Result = case hackney:request(Method, URL, maps:to_list(Headers), packet_to_json(Decoded), [with_body]) of
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
                                                                 #helium_LongFiRxPacket_pb{rssi=RSSI, payload=Payload, timestamp=Timestamp,
                                                                                           oui=OUI, device_id=DeviceID, fingerprint=Fingerprint,
                                                                                           sequence=Sequence, spreading=Spreading,
                                                                                           snr=SNR
                                                                                          }}}) ->
    jsx:encode(#{timestamp => Timestamp,
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
