%% For every packet offer, call `lorawan_adr:track_offer/2` with this
%% record.
%%
%% Packet offers contain limited information, but we will attempt to
%% glean what we can from them (which is gateway diversity).
-record(adr_offer, {
    hotspot :: libp2p_crypto:pubkey_bin(),
    packet_hash :: binary()
}).

%% For every uplink, call `lorawan_adr:track_packet/2` with this
%% record.
%%
%% ## From the LoRaWAN Specification section 4.3.1.1:
%%
%% -------------------------------------------------------------------
%% ### wants_adr
%% -------------------------------------------------------------------
%%
%% If the uplink ADR bit is set, the network will control the data
%% rate and Tx power of the end-device through the appropriate MAC
%% commands. If the ADR bit is not set, the network will not attempt
%% to control the data rate nor the transmit power of the end-device
%% regardless of the received signal quality. The network MAY still
%% send commands to change the Channel mask or the frame repetition
%% parameters.
%%
%%
%% -------------------------------------------------------------------
%% ### wants_adr_ack
%% -------------------------------------------------------------------
%%
%% If an end-device’s data rate is optimized by the network to use a
%% data rate higher than its default data rate, or a TXPower lower
%% than its default TXPower, it periodically needs to validate that
%% the network still receives the uplink frames. Each time the uplink
%% frame counter is incremented (for each new uplink, repeated
%% transmissions do not increase the counter), the device increments
%% an ADR_ACK_CNT counter. After ADR_ACK_LIMIT uplinks (ADR_ACK_CNT >=
%% ADR_ACK_LIMIT) without any downlink response, it sets the ADR
%% acknowledgment request bit (ADRACKReq). The network is required to
%% respond with a downlink frame within the next ADR_ACK_DELAY frames,
%% any received downlink frame following an uplink frame resets the
%% ADR_ACK_CNT counter. The downlink ACK bit does not need to be set
%% as any response during the receive slot of the end-device indicates
%% that the gateway has still received the uplinks from this
%% device. If no reply is received within the next ADR_ACK_DELAY
%% uplinks (i.e., after a total of ADR_ACK_LIMIT + ADR_ACK_DELAY), the
%% end-device MUST try to regain connectivity by first stepping up the
%% transmit power to default power if possible then switching to the
%% next lower data rate that provides a longer radio range. The
%% end-device MUST further lower its data rate step by step every time
%% ADR_ACK_DELAY is reached. Once the device has reached the lowest
%% data rate, it MUST re-enable all default uplink frequency channels.
%%
%%
%% -------------------------------------------------------------------
%% ### TX Power (derived)
%% -------------------------------------------------------------------
%%
%% Default Tx Power is the maximum transmission power allowed for the
%% device considering device capabilities and regional regulatory
%% constraints. Device shall use this power level, until the network
%% asks for less, through the LinkADRReq MAC command.
-record(adr_packet, {
    packet_hash :: binary(),
    wants_adr :: boolean(),
    wants_adr_ack :: boolean(),
    datarate_config :: {lorawan_utils:spreading(), lorawan_utils:bandwidth()},
    snr :: float(),
    rssi :: float(),
    hotspot :: libp2p_crypto:pubkey_bin()
}).

%% All data here is derived from an uplinked `LinkADRAns' MAC command.
-record(adr_answer, {
    %% Not used by ADR. However, devices complying the LoRaWan spec
    %% _should not_ make any adjustments if it rejects any of these
    %% settings.
    channel_mask_ack :: boolean(),
    datarate_ack :: boolean(),
    power_ack :: boolean()
}).
