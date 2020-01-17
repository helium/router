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
         send/2,
         enqueue_packet/3
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


-define(JOIN_REQUEST, 2#000).
-define(JOIN_ACCEPT, 2#001).
-define(UNCONFIRMED_UP, 2#010).
-define(UNCONFIRMED_DOWN, 2#011).
-define(CONFIRMED_UP, 2#100).
-define(CONFIRMED_DOWN, 2#101).

-record(frame, {
                mtype,
                devaddr,
                ack = 0,
                adr = 0,
                adrackreq = 0,
                rfu = 0,
                fpending = 0,
                fcnt,
                fopts = [],
                fport,
                data,
                device
               }).

-record(device, {
                 mac,
                 app_eui,
                 nwk_s_key,
                 app_s_key,
                 join_nonce,
                 fcnt,
                 fcntdown=0,
                 offset=0,
                 queue=[]
                }).

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
            lager:info("~p data sent", [_Ref]),
            {noreply, State};
        {reply, Reply} ->
            {noreply, State, Reply};
        {error, _Reason} ->
            lager:error("packet decode failed ~p ~p", [_Reason, Data]),
            {noreply, State};
        _Ref ->
            lager:info("~p data sent", [_Ref]),
            {noreply, State}
    end;
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
send(Data, _CragoEndpoint) ->
    case decode_data(Data) of
        {ok, #helium_LongFiResp_pb{id=_ID, miner_name=_MinerName, kind={_, #helium_LongFiRxPacket_pb{device_id=DID, oui=OUI}=_Packet}}=DecodedData, Reply} ->
            lager:info("decoded from ~p (id=~p) data ~p", [_MinerName, _ID, lager:pr(_Packet, ?MODULE)]),
            SendFun = e2qc:cache(console_cache, {OUI, DID}, 300, fun() -> make_send_fun(DID, OUI) end),
            R = SendFun(Data, DecodedData),
            case Reply of
                undefined ->
                    {ok, R};
                _ ->
                    {reply, Reply}
            end;
        {reply, Bin} ->
            {reply, Bin};
        {error, _Reason}=Error ->
            Error
    end.

-spec decode_data(binary()) -> {ok, #helium_LongFiResp_pb{}} | {error, any()}.
decode_data(Data) ->
    try helium_longfi_pb:decode_msg(Data, helium_LongFiResp_pb) of
        Packet ->
            {ok, Packet, undefined}
    catch
        E:R ->
            try jsx:decode(Data) of
                JSON ->
                    PacketData = base64:decode(proplists:get_value(<<"data">>, JSON)),
                    case handle_lorawan_frame(PacketData) of
                        error ->
                            {error, decoding};
                        {join, Reply} ->
                            RW = lorawan_mac_region:join1_window(<<"US902-928">>, maps:from_list(JSON)),
                            TX = maps:merge(#{ipol => true, imme => false, rfch => 0, modu => <<"LORA">>, size => byte_size(Reply), data => base64:encode(Reply)}, RW),
                            ReplyJSON = [{<<"txpk">>, TX}],
                            BinJSON = jsx:encode(ReplyJSON),
                            {reply, BinJSON};
                        {ok, #frame{device=#device{app_eui=AppEUI}=Device} = Frame} ->
                            <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
                            Res = #helium_LongFiResp_pb{miner_name= <<"fakey-fake-fakerson">>,
                                                        kind={rx,
                                                              #helium_LongFiRxPacket_pb{
                                                                 rssi=proplists:get_value(<<"rssi">>, JSON),
                                                                 snr=proplists:get_value(<<"lsnr">>, JSON),
                                                                 oui=OUI,
                                                                 device_id=DID,
                                                                 sequence=Frame#frame.fcnt,
                                                                 spreading=proplists:get_value(<<"datr">>, JSON),
                                                                 payload=Frame#frame.data, fingerprint=yolo,
                                                %tag_bits=TagBits,
                                                                 timestamp=proplists:get_value(<<"tmst">>, JSON)}}},
                            case Frame#frame.mtype == ?CONFIRMED_UP orelse length(Device#device.queue) > 0 of
                                true ->
                                    %% we have some data to send, or an ACK to make, or both
                                    ACK = case Frame#frame.mtype == ?CONFIRMED_UP of
                                              true ->
                                                  lager:info("Replying due to ack request"),
                                                  1;
                                              false -> 0
                                          end,
                                    {{Confirmed, Port, Payload}, NewQueue} = case Device#device.queue of
                                                                                 [] -> {{false, undefined, <<>>}, []};
                                                                                 [H|T] ->
                                                                                     lager:info("replying with ~p", [H]),
                                                                                     {H, T}
                                                                             end,
                                    MType = case Confirmed of
                                                true ->
                                                    lager:info("Replying with confirmed send"),
                                                    ?CONFIRMED_DOWN;
                                                false ->
                                                    ?UNCONFIRMED_DOWN
                                            end,
                                    ets:insert(router_devices, Device#device{queue=NewQueue}),
                                    {ok, Res, make_reply(JSON, #frame{mtype=MType, devaddr=Frame#frame.devaddr, fcnt=Device#device.fcntdown, fport=Port, ack=ACK, data=Payload}, Device)};
                                false ->
                                    {ok, Res, undefined}
                            end
                    end
            catch E2:R2 ->
                    lager:error("got error trying to decode  ~p - ~p", [{E, R}, {E2, R2}]),
                    {error, decoding}
            end
    end.

make_reply(Packet, Frame, Device) ->
    {FOpts, FOptsLen} = encode_fopts(Frame#frame.fopts),
    PktHdr = <<(Frame#frame.mtype):3, 0:3, 0:2, (reverse(Frame#frame.devaddr))/binary, (Frame#frame.adr):1, 0:1, (Frame#frame.ack):1, (Frame#frame.fpending):1, FOptsLen:4, (Frame#frame.fcnt):16/integer-unsigned-little, FOpts:FOptsLen/binary>>,
    PktBody = case Frame#frame.data of
                  <<>> ->
                      %% no payload
                      <<>>;
                  <<Payload/binary>> when Frame#frame.fport == 0 ->
                      lager:info("port 0 outbound"),
                      %% port 0 payload, encrypt with network key
                      <<0:8/integer-unsigned, (reverse(cipher(Payload, Device#device.nwk_s_key, 1, Frame#frame.devaddr, Frame#frame.fcnt)))/binary>>;
                  <<Payload/binary>> ->
                      lager:info("port ~p outbound", [Frame#frame.fport]),
                      <<(Frame#frame.fport):8/integer-unsigned, (reverse(cipher(Payload, Device#device.app_s_key, 1, Frame#frame.devaddr, Frame#frame.fcnt)))/binary>>
              end,
    lager:info("PktBody ~p", [PktBody]),
    Msg = <<PktHdr/binary, PktBody/binary>>,
    MIC = crypto:cmac(aes_cbc128, Device#device.nwk_s_key, <<(b0(1, Frame#frame.devaddr, Frame#frame.fcnt, byte_size(Msg)))/binary, Msg/binary>>, 4),
    Pkt = <<Msg/binary, MIC/binary>>,
    R = lorawan_mac_region:rx1_window(<<"US902-928">>, Device#device.offset, maps:from_list(Packet)),
    TX = maps:merge(#{ipol => true, imme => false, rfch => 0, modu => <<"LORA">>, size => byte_size(Pkt), data => base64:encode(Pkt)}, R),
    JSON = [{<<"txpk">>, TX}],
    jsx:encode(JSON).


make_send_fun(DID, OUI=2) ->
    Endpoint = application:get_env(router, staging_console_endpoint, undefined),
    JWT = get_token(Endpoint, staging),
    make_send_fun(OUI, DID, Endpoint, JWT);
make_send_fun(DID, OUI) ->
    Endpoint = application:get_env(router, console_endpoint, undefined),
    JWT = get_token(Endpoint, production),
    make_send_fun(OUI, DID, Endpoint, JWT).

make_send_fun(OUI, DID, Endpoint, JWT) ->
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
                                                                                     #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                       status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))}
                                                                             catch
                                                                                 What:Why:Stacktrace ->
                                                                                     lager:info("Failed to post to channel ~p ~p ~p", [What, Why, Stacktrace]),
                                                                                     #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                       delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                       status => failure, description => <<"invalid channel configuration">>}

                                                                             end,
                                                                    lager:info("Result ~p", [Result]),
                                                                    hackney:post(<<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>, [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}, {<<"Content-Type">>, <<"application/json">>}], jsx:encode(Result), [with_body]);
                                                                Other ->
                                                                    lager:warning("fingerprint mismatch for packet ~p from ~p : expected ~p got ~p", [Decoded, {OUI, DID}, Other, FP])
                                                            end
                                                    end;
                                               (Channel = #{<<"type">> := <<"mqtt">>}) ->
                                                    URL = kvc:path([<<"credentials">>, <<"endpoint">>], Channel),
                                                    Topic = kvc:path([<<"credentials">>, <<"topic">>], Channel),
                                                    ChannelID = kvc:path([<<"name">>], Channel),
                                                    fun(_Encoded, Decoded = #helium_LongFiResp_pb{miner_name=MinerName, kind={_, Packet=#helium_LongFiRxPacket_pb{rssi=RSSI, snr=SNR, payload=Payload, fingerprint=FP, timestamp=Timestamp}}}) ->
                                                            case check_fingerprint(Packet, Key) of
                                                                ok ->
                                                                    Result = case router_mqtt_sup:get_connection((OUI bsl 32) + DID, ChannelID, #{endpoint => URL, topic => Topic}) of
                                                                                 {ok, Pid} ->
                                                                                     case router_mqtt_worker:send(Pid, packet_to_json(Decoded)) of
                                                                                         {ok, PacketID} ->
                                                                                             #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                               delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                               status => success, description => list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))};
                                                                                         ok ->
                                                                                             #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                               delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                               status => success, description => <<"ok">> };
                                                                                         {error, Reason} ->
                                                                                             #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
                                                                                               delivered_at => erlang:system_time(second), rssi => RSSI, snr => SNR, hotspot_name => MinerName,
                                                                                               status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))}
                                                                                     end;
                                                                                 _ ->
                                                                                     #{channel_name => ChannelID, id => DID, oui => OUI, payload_size => byte_size(Payload), reported_at => Timestamp div 1000000,
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

-spec get_token(binary(), atom()) -> binary().
get_token(Endpoint, Env) ->
    Secret = case Env of
                 staging ->
                     application:get_env(router, staging_console_secret, undefined);
                 _ ->
                     application:get_env(router, console_secret, undefined)
             end,
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

check_fingerprint(#helium_LongFiRxPacket_pb{fingerprint=yolo}, _Key) ->
    ok;
check_fingerprint(DecodedPacket = #helium_LongFiRxPacket_pb{fingerprint=FP}, Key) ->
    case longfi:get_fingerprint(DecodedPacket, Key) of
        FP ->
            ok;
        Other ->
            Other
    end.

handle_lorawan_frame(<<MType:3, _MHDRRFU:3, _Major:2, AppEUI0:8/binary, DevEUI0:8/binary, DevNonce:2/binary, MIC:4/binary>> = Pkt) when MType == 0 ->
    Msg = binary:part(Pkt, {0, byte_size(Pkt) -4}),
    {AppEUI, DevEUI} = {reverse(AppEUI0), reverse(DevEUI0)},
                                                %AppKey = <<16#3B,16#C0,16#FB,16#09,16#32,16#4F,16#0B,16#9F,16#50,16#9E,16#5F,16#11,16#E4,16#CC,16#5B,16#84>>,
                                                %AppKey = hex_to_binary(<<"ABCB7D6A74AAAAAB543482958B555554">>),
    <<OUI:32/integer-unsigned-big, DID:32/integer-unsigned-big>> = AppEUI,
    AppKey = get_app_key(DID, OUI),
    NetID = <<"He2">>,
    case AppKey of
        undefined ->
            lager:info("no key for ~p ~p", [binary_to_hex(DevEUI), binary_to_hex(AppEUI)]),
            error;
                                                %_ when DevNonce =< PrevDevNonce ->
                                                %lager:info("duplicate join request, ignoring"),
                                                %error;
        _ ->
            case ets:lookup(router_devices, AppEUI) of
                [#device{join_nonce=OldNonce}] when DevNonce == OldNonce ->
                    lager:info("Device ~p ~p tried to join with stale nonce ~p", [OUI, DID, DevNonce]),
                    error;
                _ ->
                    case crypto:cmac(aes_cbc128, AppKey, Msg, 4) of
                        MIC ->
                            AppNonce = crypto:strong_rand_bytes(3),
                            NwkSKey = crypto:block_encrypt(aes_ecb, AppKey,
                                                           padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
                            AppSKey = crypto:block_encrypt(aes_ecb, AppKey,
                                                           padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
                            DevAddr = <<OUI:32/integer-unsigned-big>>,
                            Device = #device{mac=DevEUI, app_eui=AppEUI, app_s_key=AppSKey, nwk_s_key=NwkSKey, join_nonce=DevNonce, fcntdown=0, queue=[]},
                            ets:insert(router_devices, Device),
                            RxDelay = 0, % 1 second, section 5.7
                            DLSettings = 0, % section 5.4
                            lager:info("~p ~p ~p ~p ~p", [AppNonce, NetID, DevAddr, DLSettings, RxDelay]),
                            ReplyHdr = <<2#001:3, 0:3, 0:2>>,
                            ReplyPayload = <<AppNonce/binary, NetID/binary, DevAddr/binary, DLSettings:8/integer-unsigned, RxDelay:8/integer-unsigned>>,
                            ReplyMIC = crypto:cmac(aes_cbc128, AppKey, <<ReplyHdr/binary, ReplyPayload/binary>>, 4),
                            EncryptedReply = crypto:block_decrypt(aes_ecb, AppKey, padded(16, <<ReplyPayload/binary, ReplyMIC/binary>>)),
                            lager:info("Device ~s with AppEUI ~s tried to join with nonce ~p", [binary_to_hex(DevEUI), binary_to_hex(AppEUI), DevNonce]),
                            {join, <<ReplyHdr/binary, EncryptedReply/binary>>};
                        _ ->
                            lager:info("Device ~s with AppEUI ~s tried to join but had a bad Message Intregity Code~n", [binary_to_hex(DevEUI), binary_to_hex(AppEUI)]),
                            error
                    end
            end
    end;
handle_lorawan_frame(<<MType:3, _MHDRRFU:3, _Major:2, DevAddr0:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1, FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Pkt) ->
    Msg = binary:part(Pkt, {0, byte_size(Pkt) -4}),
    Body = binary:part(PayloadAndMIC, {0, byte_size(PayloadAndMIC) -4}),
    MIC = binary:part(PayloadAndMIC, {byte_size(PayloadAndMIC), -4}),
    {FPort, FRMPayload} = case Body of
                              <<>> -> {undefined, <<>>};
                              <<Port:8, Payload/binary>> -> {Port, Payload}
                          end,
    DevAddr = reverse(DevAddr0),
    case get_device_by_mic(get_devices(), <<(b0(MType band 1, DevAddr, FCnt, byte_size(Msg)))/binary, Msg/binary>>, MIC)  of
        undefined ->
            lager:info("unknown device ~s", [binary_to_hex(DevAddr)]),
            error;
        #device{fcnt=FCnt, app_eui=AppEUI} ->
            lager:info("discarding duplicate packet from ~p", [binary_to_hex(AppEUI)]),
            error;
        Device0 ->
            NwkSKey = Device0#device.nwk_s_key,
            Device = Device0#device{fcnt=FCnt},
            ets:insert(router_devices, Device),
            case FPort of
                0 when FOptsLen == 0 ->
                    Data = reverse(cipher(FRMPayload, NwkSKey, MType band 1, DevAddr, FCnt)),
                    lager:info("~s packet from ~s with fopts ~p~n", [mtype(MType), binary_to_hex(Device#device.app_eui), parse_fopts(Data)]),
                    {ok, #frame{mtype=MType, devaddr=DevAddr, adr=ADR, adrackreq=ADRACKReq, ack=ACK, rfu=RFU, fcnt=FCnt, fopts=parse_fopts(Data), fport=0, data = <<>>, device=Device}};
                0 ->
                    lager:info("Bad ~s packet from ~s -- double fopts~n", [mtype(MType), binary_to_hex(Device#device.app_eui)]),
                    error;
                _N ->
                    AppSKey = Device#device.app_s_key,
                    Data = reverse(cipher(FRMPayload, AppSKey, MType band 1, DevAddr, FCnt)),
                    lager:info("~s packet from ~s with ACK ~p fopts ~p and data ~s~n", [mtype(MType), binary_to_hex(Device#device.app_eui), ACK, parse_fopts(FOpts), Data]),
                    {ok, #frame{mtype=MType, devaddr=DevAddr, adr=ADR, adrackreq=ADRACKReq, ack=ACK, rfu=RFU, fcnt=FCnt, fopts=parse_fopts(Data), fport=FPort, data=Data, device=Device}}
            end
    end;
handle_lorawan_frame(Pkt) ->
    lager:info("Bad packet ~s~n", [binary_to_hex(Pkt)]),
    error.

get_app_key(DID, OUI) ->
    Endpoint = application:get_env(router, staging_console_endpoint, undefined),
    JWT = get_token(Endpoint, staging),
    case hackney:get(<<Endpoint/binary, "/api/router/devices/", (list_to_binary(integer_to_list(DID)))/binary, "?oui=", (list_to_binary(integer_to_list(OUI)))/binary>>,
                     [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            JSON = jsx:decode(Body, [return_maps]),
            base64:decode(kvc:path([<<"key">>], JSON));
        Other ->
            lager:warning("unable to get channel for ~p ~p : ~p", [OUI, DID, Other]),
            undefined
    end.

mtype(2#000) -> "Join request";
mtype(2#001) -> "Join accept";
mtype(2#010) -> "Unconfirmed data up";
mtype(2#011) -> "Unconfirmed data down";
mtype(2#100) -> "Confirmed data up";
mtype(2#101) -> "Confirmed data down";
mtype(2#110) -> "RFU";
mtype(2#111) -> "Proprietary";
mtype(X) ->
    lists:flatten(io_lib:format("~b", [X])).

cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I+1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) -> Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0,0,0,0, Dir, (reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

binxor(<<>>, <<>>, Acc) -> Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).

reverse(Bin) -> reverse(Bin, <<>>).
reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) ->
    reverse(Rest, <<H/binary, Acc/binary>>).

padded(Bytes, Msg) ->
    case bit_size(Msg) rem (8*Bytes) of
        0 -> Msg;
        N -> <<Msg/bitstring, 0:(8*Bytes-N)>>
    end.

                                                % stackoverflow.com/questions/3768197/erlang-ioformatting-a-binary-to-hex
                                                % a little magic from http://stackoverflow.com/users/2760050/himangshuj
binary_to_hex(undefined) ->
    undefined;
binary_to_hex(Id) ->
    << <<Y>> || <<X:4>> <= Id, Y <- integer_to_list(X,16)>>.

hex_to_binary(undefined) ->
    undefined;
hex_to_binary(Id) ->
    <<<<Z>> || <<X:8,Y:8>> <= Id,Z <- [binary_to_integer(<<X,Y>>,16)]>>.

parse_fopts(<<16#02, Rest/binary>>) ->
    [link_check_req | parse_fopts(Rest)];
parse_fopts(<<16#03, _RFU:5, PowerACK:1, DataRateACK:1, ChannelMaskACK:1, Rest/binary>>) ->
    [{link_adr_ans, PowerACK, DataRateACK, ChannelMaskACK} | parse_fopts(Rest)];
parse_fopts(<<16#04, Rest/binary>>) ->
    [duty_cycle_ans | parse_fopts(Rest)];
parse_fopts(<<16#05, _RFU:5, RX1DROffsetACK:1, RX2DataRateACK:1, ChannelACK:1, Rest/binary>>) ->
    [{rx_param_setup_ans, RX1DROffsetACK, RX2DataRateACK, ChannelACK} | parse_fopts(Rest)];
parse_fopts(<<16#06, Battery:8, _RFU:2, Margin:6, Rest/binary>>) ->
    [{dev_status_ans, Battery, Margin} | parse_fopts(Rest)];
parse_fopts(<<16#07, _RFU:6, DataRateRangeOK:1, ChannelFreqOK:1, Rest/binary>>) ->
    [{new_channel_ans, DataRateRangeOK, ChannelFreqOK} | parse_fopts(Rest)];
parse_fopts(<<16#08, Rest/binary>>) ->
    [rx_timing_setup_ans | parse_fopts(Rest)];
parse_fopts(<<>>) ->
    [];
parse_fopts(Unknown) ->
    [{unknown, Unknown}].

encode_fopts([]) -> {<<>>, 0}.

get_device_by_mic([], _, _) ->
    undefined;
get_device_by_mic([Device|Tail], Bin, MIC) ->
    NwkSKey = Device#device.nwk_s_key,
    case crypto:cmac(aes_cbc128, NwkSKey, Bin, 4) of
        MIC ->
            Device;
        _ ->
            get_device_by_mic(Tail, Bin, MIC)
    end.

get_devices() ->
    ets:tab2list(router_devices).

enqueue_packet(AppEUI, Payload, Confirm) ->
    case ets:lookup(router_devices, hex_to_binary(AppEUI)) of
        [#device{}=Device] ->
            ets:insert(router_devices, Device#device{queue=Device#device.queue ++ [{Confirm, 1, Payload}]});
        [] ->
            {error, not_found}
    end.


%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
