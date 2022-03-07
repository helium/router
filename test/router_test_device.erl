%%%-------------------------------------------------------------------
%% @doc
%% == Router Test Device ==
%% @end
%%%-------------------------------------------------------------------
-module(router_test_device).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include("router_test_console.hrl").
-include("lorawan_vars.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/1,
    join/2,
    uplink/2,
    hotspot_pubkey_bin/1,
    device/1,
    joined/1,
    fcnt/1,
    downlinks/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(POST_INIT, post_init).
-define(APP_EUI, <<0, 0, 0, 0, 0, 0, 0, 1>>).

-record(state, {
    hotspot_privkey :: libp2p_crypto:privkey(),
    hotspot_sig_fun :: libp2p_crypto:sig_fun(),
    hotspot_pubkey :: libp2p_crypto:pubkey(),
    hotspot_pubkey_bin :: libp2p_crypto:pubkey_bin(),
    hotspot_name :: string(),
    device :: router_device:device(),
    device_app_key = crypto:strong_rand_bytes(16) :: binary(),
    device_dev_nonce = crypto:strong_rand_bytes(2) :: binary(),
    device_joined = false :: boolean(),
    device_fcnt = 0 :: non_neg_integer(),
    device_downlinks = queue:new() :: queue:queue()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start(Args) ->
    gen_server:start(?SERVER, Args, []).

-spec join(Pid :: pid(), Opts :: map()) ->
    {ok, blockchain_helium_packet_v1:packet()} | {error, any()}.
join(Pid, Opts) ->
    gen_server:call(Pid, {join, Opts}).

-spec uplink(Pid :: pid(), Opts :: map()) ->
    {ok, blockchain_helium_packet_v1:packet()} | {error, any()}.
uplink(Pid, Opts) ->
    gen_server:call(Pid, {uplink, Opts}).

-spec hotspot_pubkey_bin(Pid :: pid()) -> libp2p_crypto:pubkey_bin().
hotspot_pubkey_bin(Pid) ->
    gen_server:call(Pid, hotspot_pubkey_bin).

-spec device(Pid :: pid()) -> router_device:device().
device(Pid) ->
    gen_server:call(Pid, device).

-spec joined(Pid :: pid()) -> boolean().
joined(Pid) ->
    gen_server:call(Pid, joined).

-spec fcnt(Pid :: pid()) -> non_neg_integer().
fcnt(Pid) ->
    gen_server:call(Pid, fcnt).

-spec downlinks(Pid :: pid()) -> blockchain_helium_packet_v1:packet() | undefined.
downlinks(Pid) ->
    gen_server:call(Pid, downlinks).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    #{secret := PrivKey, public := PubKey} = maps:get(
        hotspot_keys,
        Args,
        libp2p_crypto:generate_keys(ecc_compact)
    ),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    DeviceID = maps:get(id, Args, router_utils:uuid_v4()),
    OrgID = maps:get(organization_id, Args, router_utils:uuid_v4()),
    DefaultMeta = #{
        channels => [?CONSOLE_HTTP_CHANNEL],
        labels => #{},
        organization_id => OrgID,
        multi_buy => 1,
        adr_allowed => false,
        cf_list_enabled => true,
        rx_delay => 0
    },
    DeviceUpdates = [
        {name, <<"DEVICE_", DeviceID/binary>>},
        {dev_eui, crypto:strong_rand_bytes(8)},
        {app_eui, ?APP_EUI},
        {is_active, maps:get(is_active, Args, true)},
        {metadata, maps:merge(DefaultMeta, maps:get(metadata, Args, #{}))}
    ],
    Device = router_device:update(DeviceUpdates, router_device:new(DeviceID)),
    ok = router_console_dc_tracker:refill(OrgID, 1, 100),
    {ok,
        #state{
            hotspot_privkey = PrivKey,
            hotspot_sig_fun = libp2p_crypto:mk_sig_fun(PrivKey),
            hotspot_pubkey = PubKey,
            hotspot_pubkey_bin = PubKeyBin,
            hotspot_name = blockchain_utils:addr2name(PubKeyBin),
            device = Device
        },
        {continue, ?POST_INIT}}.

handle_continue(
    ?POST_INIT,
    #state{hotspot_name = Name, device = Device, device_app_key = AppKey} = State
) ->
    ok = router_test_console:insert_device(Device, AppKey),
    lager:info("post init for hotspot ~p device ~p", [Name, router_device:id(Device)]),
    {noreply, State};
handle_continue(_Msg, State) ->
    lager:warning("rcvd unknown continue msg: ~p", [_Msg]),
    {noreply, State}.

handle_call({join, Opts}, _From, State) ->
    SCPacket = build_join_req(Opts, State),
    Result = router_device_routing:handle_packet(
        SCPacket,
        erlang:system_time(millisecond),
        self()
    ),
    case Result of
        ok ->
            lager:info("join ~p", [Result]),
            {reply, {ok, SCPacket}, State};
        _ ->
            lager:info("failed to join ~p", [Result]),
            {reply, Result, State}
    end;
handle_call({uplink, Opts}, _From, State0) ->
    {SCPacket, FCnt1} = build_uplink(Opts, State0),
    State1 = State0#state{device_fcnt = FCnt1},
    Result = router_device_routing:handle_packet(
        SCPacket,
        erlang:system_time(millisecond),
        self()
    ),
    case Result of
        ok ->
            lager:info("uplink ~p", [Result]),
            {reply, {ok, SCPacket}, State1};
        _ ->
            lager:info("failed to uplink ~p", [Result]),
            {reply, Result, State1}
    end;
handle_call(device, _From, #state{device = Device} = State) ->
    {reply, Device, State};
handle_call(hotspot_pubkey_bin, _From, #state{hotspot_pubkey_bin = PubKeyBin} = State) ->
    {reply, PubKeyBin, State};
handle_call(joined, _From, #state{device_joined = Joined} = State) ->
    {reply, Joined, State};
handle_call(fcnt, _From, #state{device_fcnt = FCnt} = State) ->
    {reply, FCnt, State};
handle_call(downlinks, _From, #state{device_downlinks = Downlinks0} = State) ->
    case queue:out_r(Downlinks0) of
        {{value, Downlink}, Downlinks1} ->
            {reply, Downlink, State#state{device_downlinks = Downlinks1}};
        {empty, _} ->
            {reply, undefined, State}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {send_response, #blockchain_state_channel_response_v1_pb{
        downlink = #packet_pb{payload = Payload}
    }},
    #state{
        device = Device0,
        device_app_key = AppKey,
        device_dev_nonce = DevNonce,
        device_joined = false
    } = State
) ->
    %% TODO: we could do more join check here
    {ok, NwkSKey, AppSKey, DevAddr, _DLSettings, _RxDelay, _CFList} = decrypt_join_accept(
        Payload,
        DevNonce,
        AppKey
    ),
    Device1 = router_device:devaddr(DevAddr, Device0),
    Device2 = router_device:keys([{NwkSKey, AppSKey}], Device1),
    lager:info("joined", []),
    {noreply, State#state{device = Device2, device_joined = true}};
handle_info(
    {send_response, #blockchain_state_channel_response_v1_pb{
        downlink = Packet
    }},
    #state{device_joined = true, device_downlinks = Downlinks} = State
) ->
    lager:info("got downlink ~p", [lager:pr(Packet, blockchain_helium_packet_v1)]),
    {noreply, State#state{device_downlinks = queue:in_r(Packet, Downlinks)}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{}) ->
    lager:warning("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

build_join_req(Opts, #state{
    hotspot_pubkey_bin = PubKeyBin,
    device = Device,
    device_app_key = AppKey,
    device_dev_nonce = DevNonce
}) ->
    lager:info("joining with DevNonce=~p", [DevNonce]),
    AppEUI = router_device:app_eui(Device),
    DevEUI = router_device:dev_eui(Device),
    HeliumPacket = blockchain_helium_packet_v1:new(
        lorawan,
        join_payload(AppEUI, DevEUI, AppKey, DevNonce),
        erlang:system_time(millisecond),
        maps:get(rssi, Opts, 0.0),
        maps:get(freq, Opts, 923.3),
        maps:get(dr, Opts, "SF8BW125"),
        maps:get(snr, Opts, 0.0),
        {eui, bin_to_int(DevEUI), bin_to_int(AppEUI)}
    ),
    lager:info("joining with HeliumPacket=~p", [lager:pr(HeliumPacket, blockchain_helium_packet_v1)]),
    SCPacket = blockchain_state_channel_packet_v1:new(
        HeliumPacket,
        PubKeyBin,
        maps:get(region, Opts, 'US915'),
        maps:get(hold_time, Opts, rand:uniform(2000))
    ),
    lager:info("joining with SCPacket=~p", [lager:pr(SCPacket, blockchain_state_channel_packet_v1)]),
    SCPacket.

-spec join_payload(
    AppEUI0 :: binary(),
    DevEUI0 :: binary(),
    AppKey :: binary(),
    DevNonce :: binary()
) -> binary().
join_payload(AppEUI0, DevEUI0, AppKey, DevNonce) ->
    MType = ?JOIN_REQ,
    MHDRRFU = 0,
    Major = 0,
    AppEUI1 = lorawan_utils:reverse(AppEUI0),
    DevEUI1 = lorawan_utils:reverse(DevEUI0),
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, AppEUI1:8/binary, DevEUI1:8/binary, DevNonce:2/binary>>,
    MIC = crypto:macN(cmac, aes_128_cbc, AppKey, Payload0, 4),
    <<Payload0/binary, MIC:4/binary>>.

-spec decrypt_join_accept(binary(), binary(), binary()) -> any().
decrypt_join_accept(
    <<MType:3, _MHDRRFU:3, _Major:2, EncPayload/binary>>,
    DevNonce,
    AppKey
) when MType == ?JOIN_ACCEPT ->
    Payload = crypto:crypto_one_time(aes_128_ecb, AppKey, EncPayload, true),
    {AppNonce, NetID, DevAddr, DLSettings, RxDelay, MIC, CFList} =
        case Payload of
            <<AN:3/binary, NID:3/binary, DA:4/binary, DL:8/integer-unsigned, RxD:8/integer-unsigned,
                M:4/binary>> ->
                CFL = <<>>,
                {AN, NID, DA, DL, RxD, M, CFL};
            <<AN:3/binary, NID:3/binary, DA:4/binary, DL:8/integer-unsigned, RxD:8/integer-unsigned,
                CFL:16/binary, M:4/binary>> ->
                {AN, NID, DA, DL, RxD, M, CFL}
        end,
    Msg = binary:part(Payload, {0, erlang:byte_size(Payload) - 4}),
    MIC = crypto:macN(cmac, aes_128_cbc, AppKey, <<MType:3, _MHDRRFU:3, _Major:2, Msg/binary>>, 4),
    NwkSKey = crypto:crypto_one_time(
        aes_128_ecb,
        AppKey,
        lorawan_utils:padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>),
        true
    ),
    AppSKey = crypto:crypto_one_time(
        aes_128_ecb,
        AppKey,
        lorawan_utils:padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>),
        true
    ),
    {ok, NwkSKey, AppSKey, DevAddr, DLSettings, RxDelay, CFList}.

build_uplink(Opts, #state{
    hotspot_pubkey_bin = PubKeyBin,
    device = Device,
    device_fcnt = FCnt
}) ->
    lager:info("uplink with FCnt=~p", [FCnt]),
    DevAddr = router_device:devaddr(Device),
    <<DevNum:32/integer-unsigned-little>> = DevAddr,
    AppSKey = router_device:app_s_key(Device),
    NwkSKey = router_device:nwk_s_key(Device),
    HeliumPacket = blockchain_helium_packet_v1:new(
        lorawan,
        uplink_payload(FCnt, NwkSKey, AppSKey, DevAddr, Opts),
        erlang:system_time(millisecond),
        maps:get(rssi, Opts, 0),
        maps:get(freq, Opts, 923.3),
        maps:get(dr, Opts, "SF8BW125"),
        maps:get(snr, Opts, 0.0),
        {devaddr, DevNum}
    ),
    lager:info("uplink with HeliumPacket=~p", [lager:pr(HeliumPacket, blockchain_helium_packet_v1)]),
    SCPacket = blockchain_state_channel_packet_v1:new(
        HeliumPacket,
        PubKeyBin,
        maps:get(region, Opts, 'US915'),
        maps:get(hold_time, Opts, rand:uniform(2000))
    ),
    lager:info("uplink with SCPacket=~p", [lager:pr(SCPacket, blockchain_state_channel_packet_v1)]),
    {SCPacket, FCnt + 1}.

uplink_payload(FCnt, NwkSKey, AppSKey, DevAddr, Opts) ->
    MType = maps:get(mtype, Opts, ?UNCONFIRMED_UP),
    OptionsBoolToBit = fun(Key) ->
        case maps:get(Key, Opts, false) of
            true -> 1;
            false -> 0
        end
    end,
    MHDRRFU = 0,
    Major = 0,
    ADR = OptionsBoolToBit(wants_adr),
    ADRACKReq = OptionsBoolToBit(wants_adr_ack),
    ACK = OptionsBoolToBit(wants_ack),
    RFU = 0,
    FOptsBin = lorawan_mac_commands:encode_fupopts(maps:get(fopts, Opts, [])),
    FOptsLen = erlang:byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = maps:get(body, Opts, <<1:8>>),
    Data = lorawan_utils:reverse(
        lorawan_utils:cipher(Body, AppSKey, MType band 1, DevAddr, FCnt)
    ),
    FCntSize = maps:get(fcnt_size, Opts, 16),
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
            FOptsLen:4, FCnt:FCntSize/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = router_utils:b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:macN(cmac, aes_128_cbc, NwkSKey, <<B0/binary, Payload0/binary>>, 4),
    <<Payload0/binary, MIC:4/binary>>.

-spec bin_to_int(binary()) -> integer().
bin_to_int(<<EUI:64/integer-unsigned-big>>) ->
    EUI.
