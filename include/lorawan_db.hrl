%
% Copyright (c) 2016-2019 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%

-type eui() :: <<_:64>>.
-type seckey() :: <<_:128>>.
-type devaddr() :: <<_:32>>.
-type frid() :: <<_:64>>.
-type intervals() :: [{integer(), integer()}].
-type adr_config() :: {integer(), integer(), intervals()}.
-type rxwin_config() :: {
    'undefined' | integer(),
    'undefined' | integer(),
    'undefined' | number()
}.

-record(rxq, {
    freq :: number() | float(),
    datr :: binary() | integer(),
    codr :: binary(),
    time :: calendar:datetime(),
    tmms :: integer(),
    %% for future use
    reserved :: any(),
    rssi :: number(),
    lsnr :: number()
}).

-record(txq, {
    freq :: number() | float(),
    datr :: binary() | integer(),
    codr :: binary(),
    time :: integer() | 'immediately' | calendar:datetime(),
    powe :: 'undefined' | integer()
}).

-record(area, {
    name :: nonempty_string(),
    region :: atom(),
    admins :: [nonempty_string()],
    slack_channel :: 'undefined' | string(),
    log_ignored :: boolean()
}).

-record(gateway, {
    mac :: binary(),
    area :: 'undefined' | nonempty_string(),
    % rf chain for downlinks
    tx_rfch :: integer(),
    % antenna gain
    ant_gain :: integer(),
    desc :: 'undefined' | string(),
    % {latitude, longitude}
    gpspos :: {number(), number()},
    % altitude
    gpsalt :: 'undefined' | number(),
    ip_address :: {inet:ip_address(), inet:port_number(), integer()},
    last_alive :: 'undefined' | calendar:datetime(),
    last_gps :: 'undefined' | calendar:datetime(),
    last_report :: 'undefined' | calendar:datetime(),
    % {frequency, duration, hoursum}
    dwell :: [{calendar:datetime(), {number(), number(), number()}}],
    % {min, avg, max}
    delays :: [{calendar:datetime(), {integer(), integer(), integer()}}],
    health_alerts :: [atom()],
    health_decay :: integer(),
    health_reported :: integer(),
    health_next :: 'undefined' | calendar:datetime()
}).

-record(multicast_channel, {
    % multicast address
    devaddr :: devaddr(),
    profiles :: [nonempty_string()],
    nwkskey :: seckey(),
    appskey :: seckey(),
    % last downlink fcnt
    fcntdown :: integer()
}).

-record(network, {
    name :: nonempty_string(),
    % network id
    netid :: binary(),
    region :: atom(),
    tx_codr :: binary(),
    join1_delay :: integer(),
    join2_delay :: integer(),
    rx1_delay :: integer(),
    rx2_delay :: integer(),
    gw_power :: integer(),
    max_eirp :: integer(),
    max_power :: integer(),
    min_power :: integer(),
    max_datr :: number(),
    dcycle_init :: integer(),
    rxwin_init :: rxwin_config(),
    init_chans :: intervals(),
    cflist :: 'undefined' | [{number(), integer(), integer()}]
}).

-record(group, {
    name :: nonempty_string(),
    network :: nonempty_string(),
    % sub-network id
    subid :: 'undefined' | bitstring(),
    admins :: [nonempty_string()],
    slack_channel :: 'undefined' | string(),
    can_join :: boolean()
}).

-record(profile, {
    name :: nonempty_string(),
    group :: nonempty_string(),
    app :: binary(),
    appid :: any(),
    join :: 0..2,
    fcnt_check :: integer(),
    txwin :: integer(),
    % server requests
    adr_mode :: 0..2,
    % requested after join
    adr_set :: adr_config(),
    max_datr :: 'undefined' | number(),
    dcycle_set :: undefined | integer(),
    % requested
    rxwin_set :: rxwin_config(),
    request_devstat :: boolean()
}).

-record(device, {
    deveui :: eui(),
    profile :: nonempty_string(),
    % application arguments
    appargs :: any(),
    appeui :: eui(),
    appkey :: seckey(),
    desc :: 'undefined' | string(),
    last_joins :: [{calendar:datetime(), binary()}],
    node :: devaddr()
}).

-type devstat() :: {calendar:datetime(), integer(), integer(), integer()}.

-record(node, {
    devaddr :: devaddr(),
    profile :: nonempty_string(),
    % application arguments
    appargs :: any(),
    nwkskey :: seckey(),
    appskey :: seckey(),
    desc :: 'undefined' | string(),
    location :: 'undefined' | string(),
    % last uplink fcnt
    fcntup :: 'undefined' | integer(),
    % last downlink fcnt
    fcntdown :: integer(),
    first_reset :: calendar:datetime(),
    last_reset :: calendar:datetime(),
    % number of resets/joins
    reset_count :: integer(),
    last_rx :: 'undefined' | calendar:datetime(),
    % last seen gateways
    gateways :: [{binary(), #rxq{}}],
    % device supports
    adr_flag :: 0..1,
    % auto-calculated
    adr_set :: 'undefined' | adr_config(),
    % used
    adr_use :: adr_config(),
    % last request failed
    adr_failed = [] :: [binary()],
    dcycle_use :: undefined | integer(),
    % used
    rxwin_use :: rxwin_config(),
    % last request failed
    rxwin_failed = [] :: [binary()],
    % list of {RSSI, SNR} tuples
    last_qs :: [{integer(), integer()}],
    % average RSSI and SNR
    average_qs :: 'undefined' | {number(), number()},
    devstat_time :: 'undefined' | calendar:datetime(),
    devstat_fcnt :: 'undefined' | integer(),
    % {time, battery, margin, max_snr}
    devstat :: [devstat()],
    health_alerts :: [atom()],
    health_decay :: integer(),
    health_reported :: integer(),
    health_next :: 'undefined' | calendar:datetime()
}).

-record(ignored_node, {
    devaddr :: devaddr(),
    mask :: devaddr()
}).

-record(connector, {
    connid :: binary(),
    app :: binary(),
    format :: binary(),
    uri :: binary(),
    publish_qos :: 0 | 1 | 2,
    publish_uplinks :: 'undefined' | binary(),
    publish_events :: 'undefined' | binary(),
    subscribe_qos :: 0 | 1 | 2,
    subscribe :: 'undefined' | binary(),
    received :: 'undefined' | binary(),
    enabled :: boolean(),
    failed = [] :: [binary()],
    client_id :: 'undefined' | binary(),
    auth :: binary(),
    name :: 'undefined' | binary(),
    pass :: 'undefined' | binary(),
    certfile :: 'undefined' | binary(),
    keyfile :: 'undefined' | binary(),
    health_alerts :: [atom()],
    health_decay :: integer(),
    health_reported :: integer(),
    health_next :: 'undefined' | calendar:datetime()
}).

-define(EMPTY_PATTERN, {<<>>, []}).

-record(handler, {
    app :: binary(),
    uplink_fields :: [binary()],
    payload :: 'undefined' | binary(),
    parse_uplink :: 'undefined' | {binary(), fun()},
    event_fields :: [binary()],
    parse_event :: 'undefined' | {binary, fun()},
    build :: 'undefined' | {binary(), fun()},
    downlink_expires :: binary()
}).

-record(txdata, {
    confirmed = false :: boolean(),
    port :: 'undefined' | integer(),
    data :: 'undefined' | binary(),
    pending :: 'undefined' | boolean(),
    receipt :: any()
}).

-record(queued, {
    % unique identifier
    frid :: frid(),
    datetime :: calendar:datetime(),
    devaddr :: devaddr(),
    txdata :: #txdata{}
}).

-record(pending, {
    devaddr :: devaddr(),
    confirmed :: boolean(),
    phypayload :: binary(),
    sent_count :: integer(),
    receipt :: any()
}).

-record(rxframe, {
    % unique identifier
    frid :: frid(),
    dir :: binary(),
    network :: nonempty_string(),
    app :: binary(),
    devaddr :: devaddr(),
    location :: any(),
    % singnal quality at each gateway
    gateways :: [{binary(), #rxq{}}],
    % average RSSI and SNR
    average_qs :: 'undefined' | {number(), number()},
    powe :: integer(),
    fcnt :: integer(),
    confirm :: boolean(),
    port :: integer(),
    data :: binary(),
    datetime :: calendar:datetime()
}).

% end of file
