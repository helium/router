-module(router_SUITE).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device.hrl").

-export([
         all/0,
         init_per_testcase/2,
         end_per_testcase/2
        ]).

-export([
         http_test/1
        ]).

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).

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
     http_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase) ++ "_data",
    ok = application:set_env(router, base_dir, BaseDir),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, staging_console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, staging_console_secret, <<"secret">>),
    ElliOpts = [
                {callback, console_callback},
                {callback_args, [self()]},
                {port, 3000}
               ],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),
    [{elli, Pid}, {base_dir, BaseDir}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(elli, Config),
    ok = elli:stop(Pid),
    ok = application:stop(router),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

http_test(Config) ->
    BaseDir = proplists:get_value(base_dir, Config),
    Swarm = start_swarm(BaseDir, http_test_swarm, 3616),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(Swarm,
                                                   Address,
                                                   router_handler_test:version(),
                                                   router_handler_test,
                                                   [self()]),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),

    %% Send join packet
    Stream ! {send, join_packet(PubKeyBin, <<"appkey_000000001">>)},

    %% Waiting for console repor status sent
    ok = wait_for_report_status(),
    %% Waiting for reply resp form router
    ok = wait_for_reply(),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    {ok, Device} = get_device(DB, CF, router_devices_sup:id(?APPEUI, ?DEVEUI)),
    ct:pal("DEVICE= ~p", [Device]),

    %% Send join packet
    Stream ! {send, frame_packet(PubKeyBin, Device#device.nwk_s_key)},

    ok = wait_for_post_channel(),
    ok = wait_for_report_status(),

    libp2p_swarm:stop(Swarm),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

wait_for_report_status() ->
    receive
        {report_status, Body} ->
            #{<<"status">> := <<"success">>} = jsx:decode(Body, [return_maps]),
            ok
    after 250 ->
            ct:fail("report_status timeout")
    end.

wait_for_post_channel() ->
    receive
        {channel, Data} ->
            #{
              <<"device_id">> := 1,
              <<"oui">> := 2,
              <<"payload">> := <<>>,
              <<"spreading">> := <<"SF8BW125">>
             } = jsx:decode(Data, [return_maps]),
            ok
    after 250 ->
            ct:fail("wait_for_post_channel timeout")
    end.

wait_for_reply() ->
    receive
        {client_data, Data} ->
            try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                    #blockchain_state_channel_response_v1_pb{accepted=true} = Resp,
                    ok;
                _Else ->
                    ct:fail("wrong message ~p ", [_Else])
            catch
                _E:_R ->
                    ct:fail("failed to decode ~p ~p", [Data, {_E, _R}])
            end
    after 250 ->
            ct:fail("reply timeout")
    end.

start_swarm(BaseDir, Name, Port) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)},
    SwarmOpts = [
                 {base_dir, BaseDir},
                 {key, Key},
                 {libp2p_group_gossip, [{seed_nodes, []}]},
                 {libp2p_nat, [{enabled, false}]},
                 {libp2p_proxy, [{limit, 1}]}
                ],
    {ok, Swarm} = libp2p_swarm:start(Name, SwarmOpts),
    libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/" ++  erlang:integer_to_list(Port)),
    ct:pal("created swarm ~p @ ~p p2p address=~p", [Name, Swarm, libp2p_swarm:p2p_address(Swarm)]),
    Swarm.

join_packet(PubKeyBin, AppKey) ->
    MType = 2#000,
    MHDRRFU = 0,
    Major = 0,
    AppEUI = lorawan_utils:reverse(?APPEUI),
    DevEUI = lorawan_utils:reverse(?DEVEUI),
    DevNonce = <<0,0>>,
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, AppEUI:8/binary, DevEUI:8/binary, DevNonce:2/binary>>,
    MIC = crypto:cmac(aes_cbc128, AppKey, Payload0, 4),
    Payload1 = <<Payload0/binary, MIC:4/binary>>,
    HeliumPacket = #packet_pb{
                      type=lorawan,
                      oui=2,
                      payload=Payload1,
                      frequency=923.3,
                      datarate= <<"SF8BW125">>
                     },
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket, hotspot=PubKeyBin},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).

frame_packet(PubKeyBin, SessionKey) ->
    MType = 2#101,
    MHDRRFU = 0,
    Major = 0,
    <<OUI:32/integer-unsigned-big, _DID:32/integer-unsigned-big>> = ?APPEUI,
    DevAddr = <<OUI:32/integer-unsigned-big>>,
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FOptsLen = 0,
    FCnt = 0,
    FOpts = <<>>,
    Body = <<0:8>>,
    Payload0 = <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
                 FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, Body/binary>>,
    B0 = b0(MType band 1, lorawan_utils:reverse(DevAddr), FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:cmac(aes_cbc128, SessionKey, <<B0/binary, Payload0/binary>>, 4),
    ct:pal("MAKER0, ~w", [{SessionKey, <<B0/binary, Payload0/binary>>, MIC}]),
    Payload1 = <<Payload0/binary, MIC:4/binary>>,
    HeliumPacket = #packet_pb{
                      type=lorawan,
                      oui=2,
                      payload=Payload1,
                      frequency=923.3,
                      datarate= <<"SF8BW125">>
                     },
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket, hotspot=PubKeyBin},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).


b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (lorawan_utils:reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

-spec get_device(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) -> {ok, #device{}} | {error, any()}.
get_device(DB, CF, ID) ->
    case rocksdb:get(DB, CF, ID, [{sync, true}]) of
        {ok, BinDevice} -> {ok, erlang:binary_to_term(BinDevice)};
        not_found -> {error, not_found};
        Error -> Error
    end.