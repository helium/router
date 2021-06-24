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

-record(join_accept_args, {
    region :: atom(),
    app_nonce :: binary(),
    dev_addr :: binary(),
    app_key :: binary()
}).

-record(join_cache, {
    uuid :: router_utils:uuid_v4(),
    rssi :: float(),
    join_accept_args :: #join_accept_args{},
    packet_selected ::
        {blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom(),
            non_neg_integer()},
    packets = [] :: [
        {blockchain_helium_packet_v1:packet(), libp2p_crypto:pubkey_bin(), atom(),
            non_neg_integer()}
    ],
    device :: router_device:device(),
    pid :: pid()
}).

-record(frame_cache, {
    uuid :: router_utils:uuid_v4(),
    rssi :: float(),
    count = 1 :: pos_integer(),
    packet :: blockchain_helium_packet_v1:packet(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    frame :: #frame{},
    pid :: pid(),
    region :: atom(),
    pubkey_bins = [] :: [libp2p_crypto:pubkey_bin()]
}).

-record(downlink, {
    confirmed :: boolean(),
    port :: non_neg_integer(),
    payload :: binary(),
    channel :: router_channel:channel()
}).
