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
         wait_organizations_burned/1,
         join_payload/2,
         join_packet/3, join_packet/4,
         frame_payload/6,
         frame_packet/5, frame_packet/6,
         deframe_packet/2, deframe_join_packet/3,
         tmp_dir/0, tmp_dir/1,
         wait_until/1, wait_until/3]).

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
    ok = application:set_env(router, router_device_api_module, router_console_device_api),
    ok = application:set_env(router, router_console_device_api, [{endpoint, ?CONSOLE_URL},
                                                                 {ws_endpoint, ?CONSOLE_WS_URL},
                                                                 {secret, <<>>}]),
    ok = application:set_env(router, console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, console_secret, <<"secret">>),
    ok = application:set_env(router, max_v8_context, 1),
    ok = application:set_env(router, dc_tracker, "enabled"),
    ok = application:set_env(router, metrics_port, 4000),
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
                {port, 3000}],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),

    {Swarm, Keys} = ?MODULE:start_swarm(BaseDir, TestCase, 0),
    #{public := PubKey, secret := PrivKey} = Keys,
    {ok, _GenesisMembers, ConsensusMembers, _Keys} = blockchain_test_utils:init_chain(5000, {PrivKey, PubKey}, true),

    ok = router_console_dc_tracker:refill(?CONSOLE_ORG_ID, 1, 100),

    [{app_key, AppKey},
     {ets, Tab},
     {elli, Pid},
     {base_dir, BaseDir},
     {swarm, Swarm},
     {keys, Keys},
     {consensus_member, ConsensusMembers} |Config].

end_per_testcase(_TestCase, Config) ->
    libp2p_swarm:stop(proplists:get_value(swarm, Config)),
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(500),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    e2qc:teardown(router_console_device_api_get_devices),
    e2qc:teardown(router_console_device_api_get_org),
    application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    ok.

start_swarm(BaseDir, Name, Port) ->
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := PrivKey, public := PubKey} = Keys,
    Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)},
    SwarmOpts = [{base_dir, BaseDir ++ "/" ++ erlang:atom_to_list(Name) ++ "_data"},
                 {key, Key},
                 {libp2p_group_gossip, [{seed_nodes, []}]},
                 {libp2p_nat, [{enabled, false}]},
                 {libp2p_proxy, [{limit, 1}]}],
    {ok, Swarm} = libp2p_swarm:start(Name, SwarmOpts),
    libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/" ++  erlang:integer_to_list(Port)),
    ct:pal("created swarm ~p @ ~p p2p address=~p", [Name, Swarm, libp2p_swarm:p2p_address(Swarm)]),
    {Swarm, Keys}.

get_device_channels_worker(DeviceID) ->
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(DeviceID),
    {state, _Chain, _DB, _CF, _Device, _, _, _, Pid, _, _, _IsActive} = sys:get_state(WorkerPid),
    Pid.

force_refresh_channels(DeviceID) ->
    Pid = get_device_channels_worker(DeviceID),
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
                        case Resp of
                            #blockchain_state_channel_response_v1_pb{accepted=true, downlink=undefined} ->
                                wait_state_channel_message(Msg, Device, FrameData, Type, FPending, Ack, Fport, FCnt);
                            #blockchain_state_channel_response_v1_pb{accepted=true, downlink=Packet} ->
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
                                {ok, Frame}
                        end;
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

wait_organizations_burned(Expected) ->
    try
        receive
            {organizations_burned, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_organizations_burned failed ~p", [Reason])
                end
        after 1250 ->
                ct:fail("wait_organizations_burned timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_organizations_burned stacktrace ~p~n", [{_Reason, _Stacktrace}]),
            ct:fail("wait_organizations_burned failed")
    end.

join_packet(PubKeyBin, AppKey, DevNonce) ->
    join_packet(PubKeyBin, AppKey, DevNonce, 0).

join_packet(PubKeyBin, AppKey, DevNonce, RSSI) ->
    RoutingInfo = {devaddr, 1},
    HeliumPacket = blockchain_helium_packet_v1:new(RoutingInfo, lorawan, join_payload(AppKey, DevNonce), 1000, RSSI, 923.3, <<"SF8BW125">>, 0.0),
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket, hotspot=PubKeyBin, region = 'US915'},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

join_payload(AppKey, DevNonce) ->
    MType = ?JOIN_REQ,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = lorawan_utils:reverse(?APPEUI),
    DevEUI = lorawan_utils:reverse(?DEVEUI),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:cmac(aes_cbc128, AppKey, Payload0, 4),
    <<Payload0/binary, MIC:4/binary>>.

frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt) ->
    frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt, #{}).

frame_packet(MType, PubKeyBin, NwkSessionKey, AppSessionKey, FCnt, Options) ->
    DevAddr = maps:get(devaddr, Options, <<33554431:25/integer-unsigned-little, $H:7/integer>>),
    Payload1 = frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt, Options),
    HeliumPacket = #packet_pb{
                      type=lorawan,
                      payload=Payload1,
                      frequency=923.3,
                      datarate= <<"SF8BW125">>,
                      signal_strength=maps:get(rssi, Options, 0.0)
                     },
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket, hotspot=PubKeyBin, region = 'US915'},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt, Options) ->
    MHDRRFU = 0,
    Major = 0,
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
    Data = lorawan_utils:reverse(lorawan_utils:cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)),
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
                 FOptsLen:4, FCnt:16/little-unsigned-integer, FOptsBin:FOptsLen/binary, Port:8/integer, Data/binary>>,
    B0 = router_utils:b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:cmac(aes_cbc128, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    <<Payload0/binary, MIC:4/binary>>.


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

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec match_map(map(), any()) -> true | {false, term()}.
match_map(Expected, Got) when is_map(Got) ->
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
    end;
match_map(_Expected, _Got) ->
    {false, not_map}.

-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path)->
    nonl(os:cmd("mktemp -d " ++  Path)).

nonl([$\n|T]) -> nonl(T);
nonl([H|T]) -> [H|nonl(T)];
nonl([]) -> [].

deframe_packet(Packet, SessionKey) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddr:4/binary, ADR:1, RFU:1, ACK:1, FPending:1,
      FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Packet#packet_pb.payload,
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

