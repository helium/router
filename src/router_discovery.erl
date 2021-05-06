-module(router_discovery).

-include_lib("helium_proto/include/discovery_pb.hrl").
-include("lorawan_vars.hrl").

-define(NO_ERROR, 0).
-define(CONNECT_ERROR, 1).

-export([start/1]).

-spec start(Map :: map()) -> ok.
start(Map) ->
    Hotspot = maps:get(<<"hotspot">>, Map),
    PubKeyBin = libp2p_crypto:b58_to_bin(erlang:binary_to_list(Hotspot)),
    TxnID = maps:get(<<"transaction_id">>, Map),
    Sig = maps:get(<<"signature">>, Map),
    DeviceID = maps:get(<<"device_id">>, Map),
    lager:md([{device_id, DeviceID}]),
    case verify_signature(Hotspot, PubKeyBin, Sig) of
        false ->
            lager:info("failed to verify signature for ~p (device_id=~p txn_id=~p sig=~p)", [
                blockchain_utils:addr2name(PubKeyBin),
                DeviceID,
                TxnID,
                Sig
            ]);
        true ->
            lager:info("starting discovery with ~p", [Map]),
            {ok, WorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),
            Device = router_device_worker:fake_join(WorkerPid, PubKeyBin),
            Body = jsx:encode(#{txn_id => TxnID, error => ?NO_ERROR}),
            Packets = lists:map(
                fun(FCnt) ->
                    frame_payload(
                        ?UNCONFIRMED_UP,
                        router_device:devaddr(Device),
                        router_device:nwk_s_key(Device),
                        router_device:app_s_key(Device),
                        FCnt,
                        #{body => <<1:8, Body/binary>>}
                    )
                end,
                lists:seq(1, 10)
            ),
            case send(PubKeyBin, DeviceID, Packets, Sig, 10) of
                ok ->
                    ok;
                error ->
                    send_error(WorkerPid, Device, TxnID, PubKeyBin, ?CONNECT_ERROR)
            end
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec send(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    DeviceID :: binary(),
    Packets :: [binary()],
    Sig :: binary(),
    Attempts :: non_neg_integer()
) -> ok | error.
send(PubKeyBin, _DeviceID, _Packets, _Sig, 0) ->
    lager:info("failed to dial hotspot after max attempts ~p", [
        blockchain_utils:addr2name(PubKeyBin)
    ]),
    error;
send(PubKeyBin, DeviceID, Packets, Sig, Attempts) ->
    case router_discovery_handler:dial(PubKeyBin) of
        {error, _Reason} ->
            lager:info("failed to dial hotspot ~p: ~p", [
                blockchain_utils:addr2name(PubKeyBin),
                _Reason
            ]),
            timer:sleep(1000),
            send(PubKeyBin, DeviceID, Packets, Sig, Attempts - 1);
        {ok, Stream} ->
            lager:info(
                "Sent discovery request to hotspot ~p (device_id=~p Packets=~p)",
                [
                    blockchain_utils:addr2name(PubKeyBin),
                    DeviceID,
                    Packets
                ]
            ),
            BinMsg = discovery_pb:encode_msg(#discovery_start_pb{
                hotspot = PubKeyBin,
                packets = Packets,
                signature = Sig
            }),
            ok = router_discovery_handler:send(Stream, BinMsg)
    end.

-spec send_error(
    WorkerPid :: pid(),
    Device :: router_device:device(),
    TxnID :: non_neg_integer(),
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Error :: non_neg_integer()
) -> ok.
send_error(WorkerPid, Device, TxnID, PubKeyBin, Error) ->
    Body = jsx:encode(#{txn_id => TxnID, error => Error}),
    Payload = frame_payload(
        ?UNCONFIRMED_UP,
        router_device:devaddr(Device),
        router_device:nwk_s_key(Device),
        router_device:app_s_key(Device),
        1,
        #{body => <<1:8, Body/binary>>}
    ),
    <<DevAddr:32/integer-unsigned-big>> = router_device:devaddr(Device),
    router_device_worker:handle_frame(
        WorkerPid,
        router_device:nwk_s_key(Device),
        blockchain_helium_packet_v1:new(
            lorawan,
            Payload,
            erlang:system_time(millisecond),
            0.0,
            904.7,
            "SF8BW125",
            0.0,
            {devaddr, DevAddr}
        ),
        erlang:system_time(millisecond),
        1,
        PubKeyBin,
        'US915',
        self()
    ).

-spec verify_signature(
    Hotspot :: binary(),
    HotspotPubKeyBin :: libp2p_crypto:pubkey_bin(),
    Sig :: binary()
) -> boolean().
verify_signature(Hotspot, HotspotPubKeyBin, Sig) ->
    case get_hotspot_owner(HotspotPubKeyBin) of
        {error, _Reason} ->
            lager:info("failed to find owner for hotspot ~p: ~p", [
                {Hotspot, HotspotPubKeyBin},
                _Reason
            ]),
            false;
        {ok, OwnerPubKeyBin} ->
            libp2p_crypto:verify(
                <<Hotspot/binary>>,
                base64:decode(Sig),
                libp2p_crypto:bin_to_pubkey(OwnerPubKeyBin)
            )
    end.

-spec get_hotspot_owner(PubKeyBin :: libp2p_crypto:pubkey_bin()) ->
    {ok, libp2p_crypto:pubkey_bin()} | {error, any()}.
get_hotspot_owner(PubKeyBin) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    blockchain_ledger_v1:find_gateway_owner(PubKeyBin, Ledger).

-spec frame_payload(
    MType :: non_neg_integer(),
    DevAddr :: binary(),
    NwkSessionKey :: binary(),
    AppSessionKey :: binary(),
    FCnt :: non_neg_integer(),
    Options :: map()
) -> binary().
frame_payload(MType, DevAddr, NwkSessionKey, AppSessionKey, FCnt, Options) ->
    MHDRRFU = 0,
    Major = 0,
    ADR = 0,
    ADRACKReq = 0,
    ACK = 0,
    RFU = 0,
    FOptsBin = lorawan_mac_commands:encode_fupopts(maps:get(fopts, Options, [])),
    FOptsLen = byte_size(FOptsBin),
    <<Port:8/integer, Body/binary>> = maps:get(body, Options, <<1:8>>),
    Data = lorawan_utils:reverse(
        lorawan_utils:cipher(Body, AppSessionKey, MType band 1, DevAddr, FCnt)
    ),
    FCntSize = maps:get(fcnt_size, Options, 16),
    Payload0 =
        <<MType:3, MHDRRFU:3, Major:2, DevAddr:4/binary, ADR:1, ADRACKReq:1, ACK:1, RFU:1,
            FOptsLen:4, FCnt:FCntSize/little-unsigned-integer, FOptsBin:FOptsLen/binary,
            Port:8/integer, Data/binary>>,
    B0 = router_utils:b0(MType band 1, DevAddr, FCnt, erlang:byte_size(Payload0)),
    MIC = crypto:cmac(aes_cbc128, NwkSessionKey, <<B0/binary, Payload0/binary>>, 4),
    <<Payload0/binary, MIC:4/binary>>.
