-module(router_lorawan_SUITE).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").

-export([
         all/0,
         init_per_testcase/2,
         end_per_testcase/2
        ]).

-export([
         join_test/1
        ]).

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,0,0,0,0,0>>).
-define(DEVEUI, <<16#EF, 16#BE, 16#AD, 16#DE, 16#EF, 16#BE, 16#AD, 16#DE>>).
-define(ETS, suite_config).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
     join_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(router, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, console_secret, <<"secret">>),
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    Tab = ets:new(?ETS, [public, set]),
    AppKey = <<16#2B, 16#7E, 16#15, 16#16, 16#28, 16#AE, 16#D2, 16#A6, 16#AB, 16#F7, 16#15, 16#88, 16#09, 16#CF, 16#4F, 16#3C>>,
    ElliOpts = [
                {callback, console_callback},
                {callback_args, #{forward => self(), ets => Tab, app_key => AppKey}},
                {port, 3000}
               ],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),
    [{app_key, AppKey}, {ets, Tab}, {elli, Pid}, {base_dir, BaseDir}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(500),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    e2qc:teardown(console_cache),
    ok = application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    catch exit(whereis(client_swarm), kill),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

join_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    Swarm0 = start_swarm(BaseDir, join_test_swarm_0, 3620),
    register(client_swarm, Swarm0),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),
    {ok, Stream0} = libp2p_swarm:dial_framed_stream(Swarm0,
                                                    Address,
                                                    router_lorawan_handler_test:version(),
                                                    router_lorawan_handler_test,
                                                    [self(), PubKeyBin0]),
    receive
        {client_data, _,  _Data3} ->
            ct:fail("join didn't fail")
    after 0 ->
            ok
    end,


    %% Send join packet
    JoinNonce = <<5, 0>>,
    receive joining -> ok end,
    receive joined -> ok end,
    ok = wait_for_report_status(PubKeyBin0, <<"success">>),

    %% Waiting for reply resp form router
    {_NetID, _DevAddr, _DLSettings, _RxDelay, NwkSKey, AppSKey} = wait_for_join_resp(PubKeyBin0, AppKey, JoinNonce),


    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(<<"yolo_id">>),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    NwkSKey = router_device:nwk_s_key(Device0),
    AppSKey = router_device:app_s_key(Device0),
    JoinNonce = router_device:join_nonce(Device0),

    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Msg1 = {true, 2, <<"someotherpayload">>},
    router_device_worker:queue_message(WorkerPid, Msg1),
    Msg2 = {false, 55, <<"sharkfed">>},
    router_device_worker:queue_message(WorkerPid, Msg2),


    receive rx -> ok
    after 1000 -> ct:fail("nothing received from device")
    end,
    wait_for_post_channel(PubKeyBin0),

    receive rx -> ok
    after 1000 -> ct:fail("nothing received from device")
    end,
    wait_for_post_channel(PubKeyBin0),

    Stream0 ! get_channel_mask,
    receive {channel_mask, Mask} ->
            ExpectedMask = lists:seq(48, 55),
            Mask = ExpectedMask
    after 100 ->
            ct:fail("channel mask not corrected")
    end,

    %% check the device got our downlink
    receive {tx, 2, true, <<"someotherpayload">>} -> ok
    after 5000 -> ct:fail("device did not see downlink 1")
    end,
    receive {tx, 55, false, <<"sharkfed">>} -> ok
    after 5000 -> ct:fail("device did not see downlink 2")
    end,

    libp2p_swarm:stop(Swarm0),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

wait_for_report_status(PubKeyBin) ->
    wait_for_report_status(PubKeyBin, <<"success">>).

wait_for_report_status(PubKeyBin, Status) ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
    BinName = erlang:list_to_binary(AName),
    receive
        {report_status, Body} ->
            Map = jsx:decode(Body, [return_maps]),
            case Map of
                #{<<"status">> := Status,
                  <<"hotspot_name">> := BinName} ->
                    ok;
                _ ->
                    wait_for_report_status(PubKeyBin),
                    self()  ! {report_status, Body},
                    ok
            end
    after 250 ->
            ct:fail("report_status timeout")
    end.

wait_for_post_channel(PubKeyBin) ->
    {ok, AName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),
    BinName = erlang:list_to_binary(AName),
    receive
        {channel, Data} ->
            Map = jsx:decode(Data, [return_maps]),
            AppEUI = lorawan_utils:binary_to_hex(?APPEUI),
            DevEUI = lorawan_utils:binary_to_hex(?DEVEUI),
            Payload = base64:encode(<<0>>),
            ct:pal("[~p:~p:~p] MARKER ~p ~p ~p ~p~n", [?MODULE, ?FUNCTION_NAME, ?LINE, Map, AppEUI, DevEUI, BinName]),
            #{
              <<"app_eui">> := AppEUI,
              <<"dev_eui">> := DevEUI,
              <<"payload">> := Payload,
                                                %<<"spreading">> := <<"SF8BW125">>,
              <<"gateway">> := BinName
             } = Map,
            ok
    after 2500 ->
            ct:fail("wait_for_post_channel timeout")
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
    after 1000 ->
            ct:fail("missing_join for")
    end.

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
