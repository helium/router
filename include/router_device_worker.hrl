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
    data
}).

-record(join_cache, {
    rssi :: float(),
    reply :: binary(),
    packet_selected :: {blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom()},
    packet_time :: pos_integer(),
    packets = [] :: [{blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom()}],
    device :: router_device:device(),
    pid :: pid()
}).

-record(frame_cache, {
    rssi :: float(),
    count = 1 :: pos_integer(),
    packet :: blockchain_helium_packet_v1:packet(),
    packet_time :: pos_integer(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    frame :: #frame{},
    pid :: pid(),
    region :: atom()
}).

-record(adr_cache, {
    hotspot :: libp2p_crypto:pubkey_bin(),
    rssi :: float() | undefined,
    snr :: float() | undefined,
    packet_size :: integer(),
    packet_hash :: binary()
}).

-record(downlink, {
    confirmed :: boolean(),
    port :: non_neg_integer(),
    payload :: binary(),
    channel :: router_channel:channel()
}).
