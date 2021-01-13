-record(device_v5, {
    id :: binary() | undefined,
    name :: binary() | undefined,
    dev_eui :: binary() | undefined,
    app_eui :: binary() | undefined,
    %% {nwk_s_key, app_s_key}
    keys = [] :: list({binary() | undefined, binary() | undefined}),
    devaddr :: binary() | undefined,
    dev_nonces = [] :: [binary()],
    fcnt = 0 :: non_neg_integer(),
    fcntdown = 0 :: non_neg_integer(),
    offset = 0 :: non_neg_integer(),
    channel_correction = false :: boolean(),
    queue = [] :: [any()],
    ecc_compact :: map(),
    location :: libp2p_crypto:pubkey_bin() | undefined,
    metadata = #{} :: map(),
    is_active = true :: boolean()
}).

-record(device_v4, {
    id :: binary() | undefined,
    name :: binary() | undefined,
    dev_eui :: binary() | undefined,
    app_eui :: binary() | undefined,
    nwk_s_key :: binary() | undefined,
    app_s_key :: binary() | undefined,
    devaddr :: binary() | undefined,
    join_nonce = <<>> :: binary(),
    fcnt = 0 :: non_neg_integer(),
    fcntdown = 0 :: non_neg_integer(),
    offset = 0 :: non_neg_integer(),
    channel_correction = false :: boolean(),
    queue = [] :: [any()],
    keys :: map(),
    location :: libp2p_crypto:pubkey_bin() | undefined,
    metadata = #{} :: map(),
    is_active = true :: boolean()
}).

-record(device_v3, {
    id :: binary() | undefined,
    name :: binary() | undefined,
    dev_eui :: binary() | undefined,
    app_eui :: binary() | undefined,
    nwk_s_key :: binary() | undefined,
    app_s_key :: binary() | undefined,
    devaddr :: binary() | undefined,
    join_nonce = <<>> :: binary(),
    fcnt = 0 :: non_neg_integer(),
    fcntdown = 0 :: non_neg_integer(),
    offset = 0 :: non_neg_integer(),
    channel_correction = false :: boolean(),
    queue = [] :: [any()],
    keys :: map(),
    location :: libp2p_crypto:pubkey_bin() | undefined,
    metadata = #{} :: map()
}).

-record(device_v2, {
    id :: binary() | undefined,
    name :: binary() | undefined,
    dev_eui :: binary() | undefined,
    app_eui :: binary() | undefined,
    nwk_s_key :: binary() | undefined,
    app_s_key :: binary() | undefined,
    join_nonce = <<>> :: binary(),
    fcnt = 0 :: non_neg_integer(),
    fcntdown = 0 :: non_neg_integer(),
    offset = 0 :: non_neg_integer(),
    channel_correction = false :: boolean(),
    queue = [] :: [any()],
    keys :: map(),
    metadata = #{} :: map()
}).

-record(device_v1, {
    id :: binary() | undefined,
    name :: binary() | undefined,
    dev_eui :: binary() | undefined,
    app_eui :: binary() | undefined,
    nwk_s_key :: binary() | undefined,
    app_s_key :: binary() | undefined,
    join_nonce = <<>> :: binary(),
    fcnt = 0 :: non_neg_integer(),
    fcntdown = 0 :: non_neg_integer(),
    offset = 0 :: non_neg_integer(),
    channel_correction = false :: boolean(),
    queue = [] :: [any()],
    key :: map() | undefined
}).

-record(device, {
    id :: binary() | undefined,
    name :: binary() | undefined,
    dev_eui :: binary() | undefined,
    app_eui :: binary() | undefined,
    nwk_s_key :: binary() | undefined,
    app_s_key :: binary() | undefined,
    join_nonce = <<>> :: binary(),
    fcnt = 0 :: non_neg_integer(),
    fcntdown = 0 :: non_neg_integer(),
    offset = 0 :: non_neg_integer(),
    channel_correction = false :: boolean(),
    queue = [] :: [any()]
}).
