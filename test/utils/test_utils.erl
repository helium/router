-module(test_utils).

-export([init_per_testcase/2, end_per_testcase/2,
         start_swarm/3,
         get_device_channels_worker/1,
         force_refresh_channels/1,
         ignore_messages/0,
         wait_for_join_resp/3,
         wait_for_channel_correction/2,
         wait_report_device_status/1, wait_report_channel_status/1,
         wait_channel_data/1,
         wait_state_channel_message/1, wait_state_channel_message/2, wait_state_channel_message/8,
         join_packet/3, join_packet/4,
         frame_packet/5, frame_packet/6,
         tmp_dir/0, tmp_dir/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("console_test.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(router, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, oui, 1),
    ok = application:set_env(router, router_device_api_module, router_device_api_console),
    ok = application:set_env(router, router_device_api_console, [{endpoint, ?CONSOLE_URL},
                                                                 {ws_endpoint, ?CONSOLE_WS_URL},
                                                                 {secret, <<>>}]),
    ok = application:set_env(router, console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, console_secret, <<"secret">>),
    filelib:ensure_dir(BaseDir ++ "/log"),
    case os:getenv("CT_LAGER", "NONE") of
        "DEBUG" ->
            FormatStr = ["[", date, " ", time, "] ", pid, " [", severity,"]",  {device_id, [" [", device_id, "]"], ""}, " [",
                         {module, ""}, {function, [":", function], ""}, {line, [":", line], ""}, "] ", message, "\n"],
            ok = application:set_env(lager, handlers, [{lager_console_backend, [{level, debug},
                                                                                {formatter_config, FormatStr}]}]);
        _ ->
            ok = application:set_env(lager, log_root, BaseDir ++ "/log")
    end,
    Tab = ets:new(TestCase, [public, set]),
    AppKey = crypto:strong_rand_bytes(16),
    ElliOpts = [{callback, console_callback},
                {callback_args, #{forward => self(), ets => Tab,
                                  app_key => AppKey, app_eui => ?APPEUI, dev_eui => ?DEVEUI}},
                {port, 3000}
               ],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),
    Swarm = ?MODULE:start_swarm(BaseDir, TestCase, 0),
    [{app_key, AppKey},
     {ets, Tab},
     {elli, Pid},
     {base_dir, BaseDir},
     {swarm, Swarm} |Config].

end_per_testcase(_TestCase, Config) ->
    libp2p_swarm:stop(proplists:get_value(swarm, Config)),
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(500),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    ok.

start_swarm(BaseDir, Name, Port) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)},
    SwarmOpts = [
                 {base_dir, BaseDir ++ "/" ++ erlang:atom_to_list(Name) ++ "_data"},
                 {key, Key},
                 {libp2p_group_gossip, [{seed_nodes, []}]},
                 {libp2p_nat, [{enabled, false}]},
                 {libp2p_proxy, [{limit, 1}]}
                ],
    {ok, Swarm} = libp2p_swarm:start(Name, SwarmOpts),
    libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/" ++  erlang:integer_to_list(Port)),
    ct:pal("created swarm ~p @ ~p p2p address=~p", [Name, Swarm, libp2p_swarm:p2p_address(Swarm)]),
    Swarm.

get_device_channels_worker(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _DB, _CF, _Device, _OUI, Pid, _, _} = router_device_worker:state(WorkerPid),
    Pid.

force_refresh_channels(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _DB, _CF, _Device, _OUI, Pid, _, _} = router_device_worker:state(WorkerPid),
    Pid ! refresh_channels,
    timer:sleep(250),
    ok.

ignore_messages() ->
    receive
        Msg ->
            ct:pal("ignored message: ~p~n", [Msg]),
            ?MODULE:ignore_messages()
    after 2000 ->
            ok
    end.

wait_for_join_resp(PubKeyBin, AppKey, JoinNonce) ->
    receive
        {client_data, PubKeyBin, Data} ->
            try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                    #blockchain_state_channel_response_v1_pb{accepted=true, downlink=Packet} = Resp,
                    ct:pal("packet ~p", [Packet]),
                    Frame = deframe_join_packet(Packet, JoinNonce, AppKey),
                    ct:pal("Join response ~p", [Frame]),
                    Frame
            catch _:_ ->
                    ct:fail("invalid join response")
            end
    after 1250 ->
            ct:fail("missing_join for")
    end.

wait_for_channel_correction(Device, HotspotName) ->
    Correction = {false, undefined, <<>>},
    {ok, _} = ?MODULE:wait_state_channel_message(Correction, Device, erlang:element(3, Correction),
                                                 ?UNCONFIRMED_DOWN, 0, 0, undefined, 0),
    ?MODULE:wait_report_device_status(#{<<"status">> => <<"success">>,
                                        <<"description">> => '_',
                                        <<"reported_at">> => fun erlang:is_integer/1,
                                        <<"category">> => <<"down">>,
                                        <<"frame_up">> => 0,
                                        <<"frame_down">> => 1,
                                        <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    ok.

wait_report_device_status(Expected) ->
    try
        receive
            {report_device_status, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_report_device_status data failed ~p", [Reason])
                end
        after 1250 ->
                ct:fail("wait_report_device_status timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_report_device_status stacktrace ~p~n", [{_Reason, _Stacktrace}]),
            ct:fail("wait_report_device_status failed")
    end.

wait_report_channel_status(Expected) ->
    try
        receive
            {report_channel_status, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_report_channel_status data failed ~p", [Reason])
                end
        after 4250 ->
                ct:fail("wait_report_channel_status timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_report_channel_status stacktrace ~p~n", [{_Reason, _Stacktrace}]),
            ct:fail("wait_report_channel_status failed")
    end.

wait_channel_data(Expected) ->
    try
        receive
            {channel_data, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_channel_data failed ~p", [Reason])
                end
        after 1250 ->
                ct:fail("wait_channel_data timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_channel_data stacktrace ~p~n", [{_Reason, _Stacktrace}]),
            ct:fail("wait_channel_data failed")
    end.

wait_state_channel_message(Timeout) ->
    wait_state_channel_message(Timeout, undefined).

wait_state_channel_message(Timeout, PubKeyBin) ->
    try
        receive
            {client_data, PubKeyBin, Data} ->
                try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                    #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                        #blockchain_state_channel_response_v1_pb{accepted=true} = Resp,
                        ok;
                    _Else ->
                        ct:fail("wait_state_channel_message wrong message ~p ", [_Else])
                catch
                    _E:_R ->
                        ct:fail("wait_state_channel_message failed to decode ~p ~p", [Data, {_E, _R}])
                end
        after Timeout ->
                ct:fail("wait_state_channel_message timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_state_channel_message stacktrace ~p~n", [{_Reason, _Stacktrace}]),
            ct:fail("wait_state_channel_message failed")
    end.

wait_state_channel_message(Msg, Device, FrameData, Type, FPending, Ack, Fport, FCnt) ->
    try
        receive
            {client_data, undefined, Data} ->
                try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                    #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                        #blockchain_state_channel_response_v1_pb{accepted=true, downlink=Packet} = Resp,
                        ct:pal("wait_state_channel_message packet ~p", [Packet]),
                        Frame = deframe_packet(Packet, router_device:app_s_key(Device)),
                        ct:pal("~p", [lager:pr(Frame, ?MODULE)]),
                        ?assertEqual(FrameData, Frame#frame.data),
                        %% we queued an unconfirmed packet
                        ?assertEqual(Type, Frame#frame.mtype),
                        ?assertEqual(FPending, Frame#frame.fpending),
                        ?assertEqual(Ack, Frame#frame.ack),
                        ?assertEqual(Fport, Frame#frame.fport),
                        ?assertEqual(FCnt, Frame#frame.fcnt),
                        {ok, Frame};
                    _Else ->
                        ct:fail("wait_state_channel_message wrong message ~p for ~p", [_Else, Msg])
                catch _E:_R ->
                        ct:fail("wait_state_channel_message failed to decode ~p ~p for ~p", [Data, {_E, _R} , Msg])
                end
        after 1250 ->
                ct:fail("wait_state_channel_message timeout for ~p", [Msg])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_state_channel_message stacktrace ~p~n", [{_Reason, _Stacktrace}]),
            ct:fail("wait_state_channel_message failed")
    end.

join_packet(PubKeyBin, AppKey, DevNonce) ->
    join_packet(PubKeyBin, AppKey, DevNonce, 0).

join_packet(PubKeyBin, AppKey, DevNonce, RSSI) ->
    MType = ?JOIN_REQ,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = lorawan_utils:reverse(?APPEUI),
    DevEUI = lorawan_utils:reverse(?DEVEUI),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:cmac(aes_cbc128, AppKey, Payload0, 4),
    Payload1 = <<Payload0/binary, MIC:4/binary>>,
    HeliumPacket = #packet_pb{
                      type=lorawan,
                      payload=Payload1,
                      signal_strength=RSSI,
                      frequency=923.3,
                      datarate= <<"SF8BW125">>
                     },
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket, hotspot=PubKeyBin},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt) ->
    frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt, #{}).

frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt, Options) ->
    MHDRRFU = 0,
    Major = 0,
    <<OUI:32/integer-unsigned-big, _DID:32/integer-unsigned-big>> = ?APPEUI,
    DevAddr = <<OUI:32/integer-unsigned-big>>,
    ADR = 0,
    ADRACKReq = 0,
    ACK = case maps:get(should_ack, Options, false) of
              true -> 1;
              false -> 0
          end,
    RFU = 0,
    FOptsBin = lorawan_mac_commands:encode_fupopts(maps:get(fopts, Options, [])),
    FOptsLen = byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = maps:get(body, Options, <<1:8>>),
    Data = lorawan_utils:reverse(lorawan_utils:cipher(Body, AppSessionKey, MType band 1, lorawan_utils:reverse(DevAddr), FCnt)),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
                 FOptsLen:4, FCnt:16/little-unsigned-integer, FOptsBin:FOptsLen/binary, Port:8/integer, Data/binary>>,
    B0 = b0(MType band 1, lorawan_utils:reverse(DevAddr), FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:cmac(aes_cbc128, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    Payload1 = <<Payload0/binary, MIC:4/binary>>,
    HeliumPacket = #packet_pb{
                      type=lorawan,
                      payload=Payload1,
                      frequency=923.3,
                      datarate= <<"SF8BW125">>,
                      signal_strength=maps:get(rssi, Options, 0.0)
                     },
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket, hotspot=PubKeyBin},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory to be used as a scratch by eunit tests
%% @end
%%-------------------------------------------------------------------
tmp_dir() ->
    os:cmd("mkdir -p " ++ ?BASE_TMP_DIR),
    create_tmp_dir(?BASE_TMP_DIR_TEMPLATE).
tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (lorawan_utils:reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

-spec match_map(map(), map()) -> true | {false, term()}.
match_map(Expected, Got) ->
    case maps:size(Expected) == maps:size(Got) of
        false ->
            {false, {size_mismatch, maps:size(Expected), maps:size(Got)}};
        true ->
            maps:fold(
              fun(_K, _V, {false, _}=Acc) ->
                      Acc;
                 (K, V, true) when is_function(V) ->
                      case V(maps:get(K, Got, undefined)) of
                          true ->
                              true;
                          false ->
                              {false, {value_predicate_failed, K, maps:get(K, Got, undefined)}}
                      end;
                 (K, '_', true) ->
                      case maps:is_key(K, Got) of
                          true -> true;
                          false -> {false, {missing_key, K}}
                      end;
                 (K, V, true) when is_map(V) ->
                      match_map(V, maps:get(K, Got, #{}));
                 (K, V0, true) when is_list(V0) ->
                      V1 = lists:zip(lists:seq(1, erlang:length(V0)), lists:sort(V0)),
                      G0 = maps:get(K, Got, []),
                      G1 = lists:zip(lists:seq(1, erlang:length(G0)), lists:sort(G0)),
                      match_map(maps:from_list(V1),  maps:from_list(G1));
                 (K, V, true) ->
                      case maps:get(K, Got, undefined) of
                          V -> true;
                          _ -> {false, {value_mismatch, K, V, maps:get(K, Got, undefined)}}
                      end
              end,
              true,
              Expected)
    end.

-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path)->
    nonl(os:cmd("mktemp -d " ++  Path)).

nonl([$\n|T]) -> nonl(T);
nonl([H|T]) -> [H|nonl(T)];
nonl([]) -> [].

deframe_packet(Packet, SessionKey) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddrReversed:4/binary, ADR:1, RFU:1, ACK:1, FPending:1,
      FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Packet#packet_pb.payload,
    DevAddr = lorawan_utils:reverse(DevAddrReversed),
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    Data = lorawan_utils:reverse(lorawan_utils:cipher(FRMPayload, SessionKey, MType band 1, DevAddr, FCnt)),
    ct:pal("FOpts ~p", [FOpts]),
    #frame{mtype=MType, devaddr=DevAddr, adr=ADR, rfu=RFU, ack=ACK, fpending=FPending,
           fcnt=FCnt, fopts=lorawan_mac_commands:parse_fdownopts(FOpts), fport=FPort, data=Data}.

deframe_join_packet(#packet_pb{payload= <<MType:3, _MHDRRFU:3, _Major:2, EncPayload/binary>>}, DevNonce, AppKey) when MType == ?JOIN_ACCEPT ->
    ct:pal("Enc join ~w", [EncPayload]),
    <<AppNonce:3/binary, NetID:3/binary, DevAddr:4/binary, DLSettings:8/integer-unsigned, RxDelay:8/integer-unsigned, MIC:4/binary>> = Payload = crypto:block_encrypt(aes_ecb, AppKey, EncPayload),
    ct:pal("Dec join ~w", [Payload]),
                                                %{?APPEUI, ?DEVEUI} = {lorawan_utils:reverse(AppEUI0), lorawan_utils:reverse(DevEUI0)},
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload)-4}),
    MIC = crypto:cmac(aes_cbc128, AppKey, <<MType:3, _MHDRRFU:3, _Major:2, Msg/binary>>, 4),
    NetID = <<"He2">>,
    NwkSKey = crypto:block_encrypt(aes_ecb,
                                   AppKey,
                                   lorawan_utils:padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    AppSKey = crypto:block_encrypt(aes_ecb,
                                   AppKey,
                                   lorawan_utils:padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    {NetID, DevAddr, DLSettings, RxDelay, NwkSKey, AppSKey}.

