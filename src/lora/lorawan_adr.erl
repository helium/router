%% ------------------------------------------------------------------
%% @doc LoraWAN Adaptive DataRate engine.
%%
%% This module exposes a simple adaptive DataRate algorithm loosely
%% based on Semtech's recommended algorithm [1,2].
%%
%% === Usage ===
%%
%% This module has a minimal API and almost zero coupling to external
%% code. Because of this, you have to bring your own IO (BYOIO). It
%% will not perform any packet reception, transmission, or
%% construction. Instead, you must call this module for every uplink
%% packet received and the returned terms tell you want actions you
%% need to take in order to properly regulate the end-device's
%% DataRate and transmit-power.
%%
%% Example:
%%
%% ```
%% %% Create a new handle with the device's region. See new/2 for more control.
%% State01 = lorawan_adr:new('US915'),
%%
%% %% First track all packet offers.
%% OfferN = #adr_offer{
%%     packet_hash = RxOfferHash
%% },
%%
%% State09 = lorawan_adr:track_offer(State08, OfferN),
%%
%% %% Assume these RxPkt[X] values all come from uplink packet and
%% %% that we have already received several similar packets since State01.
%% Packet10 = #adr_packet{
%%     rssi = RxPktRssi,
%%     snr = RxPktSnr,
%%     wants_adr = RxPktAdrBit == 1,           % true
%%     wants_adr_ack = RxPktAdrAckReqBit == 1, % false
%%     datarate_config = {RxPktSpreading, RxPktBandwidth},
%%     packet_hash = RxPktHash
%% },
%%
%% {State10, {NewDataRate, NewPower}} = lorawan_adr:track_packet(
%%     State09,
%%     Packet10
%% ),
%%
%% %%
%% %% ... here you handle sending a downlink packet with the
%% %%     `LinkADRReq' MAC command.
%% %%
%%
%% %% If you receive an uplink response with the `LinkADRAns' MAC
%% %% command, inform the ADR engine so it can update its state:
%% Answer0 = #adr_answer{
%%     channel_mask_ack = true,
%%     datarate_ack = true,
%%     power_ack = true
%% },
%% State11 = lorawan_adr:track_adr_answer(State10, Answer0),
%% '''
%%
%% ==== A rant about transmit power ====
%%
%% LoRaWAN requires us to set both DataRate and transmit power when
%% sending a `LinkADRReq' MAC command. Unfortunately, LoRaWAN's
%% designers forgot to give devices a mechanism for reporting their
%% current TX power. Furthermore, DataRate and transmit power changes
%% are communicated to end devices with values, not deltas (e.g., set
%% power to 1, not reduce power by 2 steps). Unlike DataRate, which is
%% absolute and reported by the forwarding gateway, power degrades
%% over distance and is not derivable by the receiving party. Because
%% of this design oversight, we track a device's TX power by:
%%
%% <dl>
%%    <dt> Devices for which we have not yet received a `LinkADRAns': </dt>
%%    <dd> Assume the device is transmitting at TXPower index 0 as
%%         defined its region's 'TX Power Table' defined in the
%%         regional parameters document. </dd>
%%    <dt> Otherwise: </dt>
%%    <dd> Lookup values sent in last `LinkADRReq' </dd>
%% </dl>
%%
%% ==== References ====
%%
%% <ol>
%%   <li>LoRaWAN – simple rate adaptation recommended algorithm (Revision 1.0)</li>
%%   <li>[https://www.thethingsnetwork.org/docs/lorawan/adaptive-data-rate.html]</li>
%%   <li>[https://github.com/TheThingsNetwork/ttn/issues/265#issuecomment-329449935]</li>
%% </ol>
%% @end
%% ------------------------------------------------------------------

-module(lorawan_adr).

-include("lorawan_adr.hrl").

%% ==================================================================
%% Public API Exports
%% ==================================================================
-export([
    datarate_entry/2,
    max_datarate/1,
    min_datarate/1,
    new/1,
    new/2,
    track_adr_answer/2,
    track_offer/2,
    track_packet/2
]).

-export_type([
    adjustment/0,
    datarate_config/0,
    handle/0
]).

-type datarate_config() :: {lorawan_utils:spreading(), lorawan_utils:bandwidth()}
%% A tuple of `{SpreadingFactor, Bandwidth}'.
.

-type datarate_entry() :: {pos_integer(), datarate_config()}
%% A tuple of `{DataRate, {SpreadingFactor, Bandwidth}}' returned by {@link
%% datarate_entry/2}.
.

-type adjustment() :: hold | {DataRate :: pos_integer(), TxPower :: pos_integer()}
%% An adjustment to send to an end-device, or not when `hold',
%% returned by {@link track_packet/2}.
.

%% ==================================================================
%% Internal Constants
%% ==================================================================

%% The default number of seconds we keep historic offers around.
%%
%% This value can be overridden by calling {@link new/2} with option
%% `{offer_lifetime_secs, NumberOfSeconds}'.
%%
%% We could get more precise about evicting old offers, but
%% compared to using time, it doesn't buy us anything and probably makes
%% things more complicated than it needs to be.
-define(DEFAULT_OFFER_LIFETIME_S, 10).

%% The default minimum number of packets we need in history before
%% eviction.
%%
%% This value can be overridden by calling {@link new/2} with option
%% `{adr_history_len, Length}'.
-define(DEFAULT_ADR_HISTORY_LEN, 20).

%% The closest we allow historical packet SNRs to approach the
%% theoretical minimum when determining whether or not change
%% spreading factor.
%%
%% This value can be overridden by calling {@link new/2} with option
%% `{snr_headroom, Decibels}'.
-define(DEFAULT_SNR_HEADROOM_dB, 10.0).

%% Default amount to adjust uplink TXPower for every available
%% adjustment step in dBm. Note, unlike DataRate, we adjust by dBm and
%% then find the closest TXPower index value to match.
-define(DEFAULT_TXPOWER_ADJUSTMENT_DBM_STEP_SIZE, 3).

%% A map of spreading factor to minimum signal-to-noise ratio needed
%% for reliable reception.
-define(SNR_THRESHOLD_dB, #{
    7 => -7.5,
    8 => -10.0,
    9 => -12.5,
    10 => -15.0,
    11 => -17.5,
    12 => -20.0
}).

%% ==================================================================
%% Internal Types
%% ==================================================================

-record(packet, {
    %% Hash is used as a unique identifier.
    hash :: binary(),
    %% Number of gateways which heard this packet.
    gateway_diversity :: pos_integer(),
    %% Best signal-to-noise ratio for all the gateways that reported SNR.
    best_snr :: float(),
    %% Best signal strength for all the gateways that reported RSSI.
    best_rssi :: float()
}).

%% {monotonic time (seconds), hash}
-type offer() :: {integer(), binary()}.

%% Region-specific Data Rate encoding table.
%%
%% TODO: bandwidth is not currently used because we're artificially
%%       filtering the regional parameters for only 125kHz channels. Does
%%       this make sense?
%%
%% [{DataRate, {Spreading, Bandwidth}}]
-type regional_datarates() ::
    list(
        {DataRate :: pos_integer(), datarate_config()}
    ).

-record(device, {
    %% The region who's rules this device is operating under. Not
    %% necessarily the region the device is physically in.
    region :: atom(),
    %% History of previously received packets.
    packet_history :: list(#packet{}),
    %% History of previously received offers.
    offer_history :: list(offer()),
    %% ADR awaiting an acknowledgment from the device via a
    %% `LinkADRAns' MAC command.
    pending_adjustments :: list(adjustment()),
    %% ADR adjustments acknowledged by the device via a `LinkADRAns'
    %% MAC command.
    accepted_adjustments :: list(adjustment()),
    %% Table of region-specific DataRate parameters.
    datarates :: regional_datarates(),
    %% Table of region-specific uplink power.
    txpowers :: lora_plan:tx_power_table(),
    %% Slowest DataRate available in this device's `datarates'.
    %%
    %% The word DataRate, as used by the regional parameters document,
    %% is essentially an index into a table. It is probably safe to
    %% remove this and assume 0, but let's track it for completeness
    %% sake for the time being.
    min_datarate :: pos_integer(),
    %% Spreading factor for corresponding `min_datarate'.
    %%
    %% Q: Why would a `max_spreading' correspond to `min_datarate'?
    %% A: Because DataRate, aka throughput, decreases as spreading
    %%    increases.
    %%
    %% TODO: maybe it's fine to always lookup this value in
    %%       `datarates' when needed.
    max_spreading :: pos_integer(),
    %% Fastest DataRate available in this device's `datarates'.
    max_datarate :: pos_integer(),
    %% Spreading factor for corresponding `max_datarate'.
    %%
    %% Q: Why would a `min_spreading' correspond to `max_datarate'?
    %% A: Because DataRate, aka throughput, increases as spreading
    %%    factor decreases.
    %%
    %% TODO: maybe it's fine to always lookup this value in
    %%       `datarates' when needed.
    min_spreading :: pos_integer(),
    %% Index of strongest transmit power in regional parameters table.
    %%
    %% TODO: power _decreases_ as the index increases, so
    %% `max_txpower_idx' is almost certainly index 0.
    max_txpower_idx :: pos_integer(),
    %% Value, in dBm, of transmit power at index `max_txpower_idx' in
    %% the regional parameters document.
    max_txpower_dbm :: number(),
    %% Index of weakest transmit power in the regional parameters
    %% document.
    min_txpower_idx :: pos_integer(),
    %% Value, in dBm, of transmit power at index `min_txpower_idx' in
    %% the regional parameters document.
    min_txpower_dbm :: number(),
    %% --------------------------------------------------------------
    %% Options
    %% --------------------------------------------------------------
    option_adr_history_len = ?DEFAULT_ADR_HISTORY_LEN :: pos_integer(),
    option_offer_lifetime_sec = ?DEFAULT_OFFER_LIFETIME_S :: number(),
    option_snr_headroom = ?DEFAULT_SNR_HEADROOM_dB :: float(),
    option_txpower_adjustment_dbm_step_size = ?DEFAULT_TXPOWER_ADJUSTMENT_DBM_STEP_SIZE :: number()
}).

-opaque handle() :: #device{}
%% Obtain a `handle()' by calling {@link new/1} or {@link new/2}.
%%
%% `handle()' are the state object used for all ADR API calls.
.

%% ==================================================================
%% Public API
%% ==================================================================

%% ------------------------------------------------------------------
%% @doc Returns a new ADR handle with sane defaults suitable for use
%%      in the specified region.
%%
%% Use {@link new/2} instead for more granular control of ADR
%% behavior.
%% @end
%% ------------------------------------------------------------------
-spec new(Region :: atom()) -> handle().
new(Region) ->
    %% Filter gotthardp's table down to only 125kHz uplink DataRates.
    FilterMapFn = fun
        ({_, _, down}) ->
            false;
        ({DataRate, {Spreading, 125 = Bandwidth}, _Direction}) ->
            {true, {DataRate, {Spreading, Bandwidth}}};
        (_) ->
            false
    end,
    Datarates = lists:filtermap(FilterMapFn, lorawan_mac_region:datars(Region)),
    %% min-max refer to #device.min_datarate docs
    [{MinDataRate, {MaxSpreading, _}} | _] = Datarates,
    {MaxDataRate, {MinSpreading, _}} = lists:last(Datarates),
    TxPowers = lorawan_mac_region:uplink_power_table(Region),
    [{MaxTxPowerIdx, MaxTxPowerDBm} | _] = TxPowers,
    {MinTxPowerIdx, MinTxPowerDBm} = lists:last(TxPowers),
    #device{
        region = Region,
        offer_history = [],
        packet_history = [],
        pending_adjustments = [],
        accepted_adjustments = [],
        datarates = Datarates,
        txpowers = TxPowers,
        min_datarate = MinDataRate,
        max_spreading = MaxSpreading,
        max_datarate = MaxDataRate,
        min_spreading = MinSpreading,
        max_txpower_idx = MaxTxPowerIdx,
        max_txpower_dbm = MaxTxPowerDBm,
        min_txpower_idx = MinTxPowerIdx,
        min_txpower_dbm = MinTxPowerDBm
    }.

%% ------------------------------------------------------------------
%% @doc Returns a new ADR handle for the specified region.
%%
%% <h4>Options:</h4>
%% <dl>
%%   <dt>{@type {offer_lifetime_secs, pos_integer()@}}</dt>
%%   <dd>The maximum allowable age an offer can be for consideration
%%       in gateway diversity calculations.</dd>
%%
%%   <dt>{@type {adr_history_len, pos_integer()@}}</dt>
%%   <dd>The minimum number of packets we need in history before
%%       {@link track_packet/2} will return DataRate adjustments.</dd>
%%
%%   <dt>{@type {snr_headroom, number()@}}</dt>
%%   <dd>The closest we allow historical packet SNRs to approach the
%%       theoretical minimum when determining whether or not change
%%       DataRate.</dd>
%%
%%   <dt>{@type {txpower_adjustment_dbm_step_size, number()@}}</dt>
%%   <dd>After maxing out DataRate, adjust uplink transmit power by
%%       these many dBm for each remaining step. The adjustment is
%%       added to TxPower when remaining steps is negative, otherwise
%%       it's subtracted. Read ADR reference algorithm
%%       for definition of "step".</dd>
%% </dl>
%% @end
%% ------------------------------------------------------------------
-spec new(Region :: term(), Options :: proplists:proplist()) -> handle().
new(Region, Options) ->
    OptionParserFn = fun
        ({offer_lifetime_secs, Value}, Device) when Value > 0 ->
            Device#device{option_offer_lifetime_sec = Value};
        ({adr_history_len, Value}, Device) when Value > 0 ->
            Device#device{option_adr_history_len = Value};
        ({snr_headroom, Value}, Device) when Value > 0.0 ->
            Device#device{option_snr_headroom = Value};
        ({txpower_adjustment_dbm_step_size, Value}, Device) when is_number(Value) ->
            Device#device{option_txpower_adjustment_dbm_step_size = Value}
    end,
    lists:foldl(OptionParserFn, new(Region), Options).

%% ------------------------------------------------------------------
%% @doc Consider this new offer in future ADR calculations.
%%
%% Because we have not bought the packet yet, and can't see its
%% header, we do not yet know if this packet has its ADR bit
%% set. So we will hold onto it until:
%%
%% <ol>
%%   <li>We purchase the packet. </li>
%%   <li>The offer is older than `offer_lifetime_secs' seconds.</li>
%% </ol>
%% @end
%% ------------------------------------------------------------------
-spec track_offer(
    Device :: handle(),
    Offer :: #adr_offer{}
) -> handle().
track_offer(
    Device,
    Offer
) ->
    #device{offer_history = Offers} = Device,
    %% See note for OFFER_LIFETIME_S for an explanation of why we're
    %% using time and not length.
    Now = erlang:monotonic_time(seconds),
    TrimFn = fun({TimeStamp, _}) -> TimeStamp + Device#device.option_offer_lifetime_sec > Now end,
    Trimmed = lists:takewhile(TrimFn, Offers),
    Device#device{offer_history = [{Now, Offer#adr_offer.packet_hash} | Trimmed]}.

%% ------------------------------------------------------------------
%% @doc Remember this packet and (possibly) return an ADR DataRate
%%      adjustment.
%%
%% <h4> Returns </h4>
%% <dl>
%%   <dt>`hold'</dt>
%%   <dd> Returned when either:
%%     <ul>
%%       <li>Have not collected enough historic packets to make an ADR
%%           adjustment.</li>
%%       <li>DataRate can not be improved (likely too low historic
%%           SNR).</li>
%%     </ul>
%%   </dd>
%%
%%   <dt>{@type {NewDataRate, NewTxPower@}}</dt>
%%   <dd>Returned when either:
%%     <ul>
%%       <li>Returned when current DataRate is not optimal based on
%%           SNRs we've seen in historic packets.</li>
%%       <li>`ADRAckreqbitset' is set, regardless if we've collected
%%            enough packets yet.</li>
%%     </ul>
%%   </dd>
%% </dl>
%% @end
%% ------------------------------------------------------------------
-spec track_packet(
    handle(),
    #adr_packet{}
) -> {handle(), adjustment()}.
track_packet(
    Device0,
    Pkt
) when Pkt#adr_packet.wants_adr == true ->
    #device{
        offer_history = Offers0,
        packet_history = History0,
        pending_adjustments = PendingAdjustments0,
        accepted_adjustments = AcceptedAdjustments0,
        txpowers = TxPowerTable,
        max_txpower_idx = MaxTxPowerIdx,
        min_datarate = MinDataRate,
        max_datarate = MaxDataRate,
        option_adr_history_len = ConfiguredAdrHistoryLen,
        option_snr_headroom = ConfiguredSNRHeadroom,
        option_txpower_adjustment_dbm_step_size = TxPowerAdjustmentDBmStepSize
    } = Device0,
    #adr_packet{
        wants_adr_ack = WantsADRAck,
        rssi = PktRssi,
        snr = PktSnr,
        datarate_config = DataRateConfig,
        packet_hash = PktHash
    } = Pkt,
    {OfferGatewayDiversity, Offers1} = count_and_prune_offers_for_hash(PktHash, Offers0),
    TrimmedHistory = lists:sublist(History0, ConfiguredAdrHistoryLen - 1),
    History1 =
        case TrimmedHistory of
            [H | T] when H#packet.hash == PktHash ->
                %% Previous diversity count + this packet + offer count
                %%
                %% Offer count is unlikely to be > 0 considering we've
                %% already accepted a different gateway's packet with
                %% this hash
                CumulativeDiversity = 1 + OfferGatewayDiversity + H#packet.gateway_diversity,
                BestSnr = erlang:max(H#packet.best_snr, PktSnr),
                [H#packet{gateway_diversity = CumulativeDiversity, best_snr = BestSnr} | T];
            _ ->
                NewHistoryHead = #packet{
                    hash = PktHash,
                    gateway_diversity = OfferGatewayDiversity + 1,
                    best_snr = PktSnr,
                    best_rssi = PktRssi
                },
                [NewHistoryHead | TrimmedHistory]
        end,
    {CurrentDataRate, {CurrentSpreading, _CurrentBandwidth}} =
        case datarate_entry(Device0, DataRateConfig) of
            %% TODO: what is the best strategy when a device sends a
            %%       packet at a `{Spreading, Bandwidth}' not in our
            %%       regional parameters table? Sort term is to just
            %%       lie to the DataRate adjuster that the device is
            %%       at the minimum DataRate.
            undefined -> datarate_entry(Device0, MinDataRate);
            DataRateEntry -> DataRateEntry
        end,
    %% We don't (and can't!) know with great confidence what transmit
    %% power the device is using. We can however guess based on the
    %% most recently acknowledged ADR adjustment if we have any. If we
    %% haven't received any acknowledgments yet, we assume the device
    %% is using its region's maximum transmit power.
    {LastAcceptedDataRate, LastAcceptedTxPowerIdx} =
        case AcceptedAdjustments0 of
            [] -> {CurrentDataRate, MaxTxPowerIdx};
            [Accepted | _] -> Accepted
        end,
    AcceptedAdjustments1 =
        case CurrentDataRate == LastAcceptedDataRate of
            true ->
                AcceptedAdjustments0;
            false ->
                lager:warning("expected data rate ~p, got ~p", [
                    LastAcceptedDataRate,
                    CurrentDataRate
                ]),
                []
        end,

    Adjustment = adjust_uplink_params(
        CurrentDataRate,
        CurrentSpreading,
        MaxDataRate,
        History1,
        WantsADRAck,
        ConfiguredAdrHistoryLen,
        ConfiguredSNRHeadroom,
        TxPowerTable,
        TxPowerAdjustmentDBmStepSize,
        LastAcceptedTxPowerIdx
    ),
    %% We only want to put actual adjustments in
    %% `pending_adjustments', `hold' is not really an
    %% adjustment. Perhaps the `adjustment()' type should be
    %% refactored to indicate that.
    PendingAdjustments1 =
        case Adjustment of
            hold -> PendingAdjustments0;
            _ -> [Adjustment | PendingAdjustments0]
        end,
    Device1 = Device0#device{
        offer_history = Offers1,
        packet_history = History1,
        pending_adjustments = PendingAdjustments1,
        accepted_adjustments = AcceptedAdjustments1
    },
    lager:info(
        "~p, ADR ~p, ADRAck ~p, SNR ~p, RSSI ~p, diversity ~p," ++
            " pend adj len ~p, history len ~p, adjustment ~p",
        [
            datarate_entry(Device0, DataRateConfig),
            true,
            WantsADRAck,
            PktSnr,
            PktRssi,
            OfferGatewayDiversity,
            length(PendingAdjustments1),
            length(History1),
            Adjustment
        ]
    ),
    {Device1, Adjustment};
%% We clear all state when device doesn't want ADR control.
track_packet(
    Device,
    _Pkt
) ->
    case Device#device.packet_history of
        [] -> ok;
        _ -> lager:info("device turned off ADR, clearing history")
    end,
    {
        Device#device{
            packet_history = [],
            offer_history = [],
            pending_adjustments = [],
            accepted_adjustments = []
        },
        hold
    }.

%% ------------------------------------------------------------------
%% @doc Returns this device's minimum (slowest) DataRate index[1].
%%
%% 1: what regional parameters spec calls DataRate.
%% @end
%% ------------------------------------------------------------------
-spec min_datarate(handle()) -> pos_integer().
min_datarate(Device) ->
    Device#device.min_datarate.

%% ------------------------------------------------------------------
%% @doc Returns this device's maximum (fastest) DataRate index[1].
%%
%% 1: what regional parameters spec calls DataRate.
%% @end
%% ------------------------------------------------------------------
-spec max_datarate(handle()) -> pos_integer().
max_datarate(Device) ->
    Device#device.max_datarate.

%% ------------------------------------------------------------------
%% @doc Returns the {@link datarate_entry()} for the given
%%      DataRate-index[1] or {@link datarate_config()}.
%%
%% Returns `undefined' when DataRate is not in the device's
%% table. This function always returns the full DataRate table
%% entry. One of the values in the outer tuple is redundant and will
%% be the same as the Index or Config you pass in.
%%
%% 1: what regional parameters spec calls DataRate.
%% @end
%% ------------------------------------------------------------------
-spec datarate_entry(
    Device :: handle(),
    DataRate :: pos_integer() | datarate_config()
) -> datarate_entry() | undefined.
datarate_entry(Device, Config) when is_tuple(Config) ->
    case lists:keyfind(Config, 2, Device#device.datarates) of
        false ->
            undefined;
        Entry ->
            Entry
    end;
datarate_entry(
    Device,
    DataRate
) when is_integer(DataRate) ->
    case lists:keyfind(DataRate, 1, Device#device.datarates) of
        false -> undefined;
        Entry -> Entry
    end.

%% ------------------------------------------------------------------
%% @doc Must be called when a device uplinks a `LinkADRAns' MAC
%%      command.
%%
%% Failure to call this function for every `LinkADRAns' will result in
%% growing memory consumption and non-standards-compliant ADR
%% behavior.
%% @end
%% ------------------------------------------------------------------
-spec track_adr_answer(Device :: handle(), Answer :: #adr_answer{}) -> handle().
track_adr_answer(#device{pending_adjustments = []} = Device, _Answer) ->
    lager:warning(
        "Device firmware bug or DoS attempt: received an ADR answer" ++
            " with no outstanding ADR requests"
    ),
    Device;
track_adr_answer(Device0, Answer) ->
    #device{
        %% TODO: how to handle the case where `PendingTail =/= []'?
        pending_adjustments = [{AcceptedDataRate, AcceptedTXPower} = PendingHead | PendingTail],
        accepted_adjustments = AcceptedAdjustments0
    } = Device0,
    #adr_answer{
        channel_mask_ack = ChannelMaskAck,
        datarate_ack = DataRateAck,
        power_ack = PowerAck
    } = Answer,
    Acceptance = fun(Ack) ->
        case Ack of
            true -> accepted;
            false -> rejected
        end
    end,
    %% NOTE: channel mask is handled outside of this module. All we
    %%       know is if it was accepted.
    lager:info(
        "device ~s DataRate ~p, ~s TxPower ~p, and ~s ChannelMask" ++
            " with ~p previously unanswered adjustments",
        [
            Acceptance(DataRateAck),
            AcceptedDataRate,
            Acceptance(PowerAck),
            AcceptedTXPower,
            Acceptance(ChannelMaskAck),
            length(PendingTail)
        ]
    ),
    case {ChannelMaskAck, DataRateAck, PowerAck} of
        {_, true, true} ->
            Device0#device{
                pending_adjustments = [],
                accepted_adjustments = [PendingHead | AcceptedAdjustments0]
            };
        _ ->
            Device0#device{pending_adjustments = []}
    end.

%% ==================================================================
%% Private API
%% ==================================================================

-spec snr_threshold(lorawan_utils:spreading()) -> number().
snr_threshold(Spreading) ->
    maps:get(Spreading, ?SNR_THRESHOLD_dB).

%% Returns highest SNR from uplink history.
-spec best_snr(nonempty_list(#packet{})) -> number().
best_snr([H | T]) ->
    lists:foldl(
        fun(Packet, Winner) -> erlang:max(Packet#packet.best_snr, Winner) end,
        H#packet.best_snr,
        T
    ).

-spec adjust_uplink_params(
    AdjSteps :: integer(),
    DataRate :: pos_integer(),
    MaxDataRate :: pos_integer(),
    TxPowerAdjustmentDBmStepSize :: number(),
    TxPowerDBm :: number(),
    MinTxPowerDBm :: number(),
    MaxTxPowerDBm :: number()
) -> {DataRate :: pos_integer(), TxPowerDBm :: number()}.
adjust_uplink_params(
    AdjSteps,
    DataRate,
    MaxDataRate,
    TxPowerAdjustmentDBmStepSize,
    TxPowerDBm,
    MinTxPowerDBm,
    MaxTxPowerDBm
) when (AdjSteps > 0), (DataRate < MaxDataRate) ->
    %% -------------------------------------------
    %% Begin increasing DataRate.
    %% -------------------------------------------
    Take = erlang:min(MaxDataRate - DataRate, AdjSteps),
    adjust_uplink_params(
        AdjSteps - Take,
        DataRate + Take,
        MaxDataRate,
        TxPowerAdjustmentDBmStepSize,
        TxPowerDBm,
        MinTxPowerDBm,
        MaxTxPowerDBm
    );
adjust_uplink_params(
    AdjSteps,
    DataRate,
    MaxDataRate,
    TxPowerAdjustmentDBmStepSize,
    TxPowerDBm,
    MinTxPowerDBm,
    MaxTxPowerDBm
) when (AdjSteps > 0), (TxPowerDBm > MinTxPowerDBm) ->
    %% -------------------------------------------
    %% DataRate is maxed out; reduce uplink power.
    %% -------------------------------------------
    adjust_uplink_params(
        AdjSteps - 1,
        DataRate,
        MaxDataRate,
        TxPowerAdjustmentDBmStepSize,
        max(TxPowerDBm - TxPowerAdjustmentDBmStepSize, MinTxPowerDBm),
        MinTxPowerDBm,
        MaxTxPowerDBm
    );
adjust_uplink_params(
    AdjSteps,
    DataRate,
    MaxDataRate,
    TxPowerAdjustmentDBmStepSize,
    TxPowerDBm,
    MinTxPowerDBm,
    MaxTxPowerDBm
) when (AdjSteps < 0), (TxPowerDBm < MaxTxPowerDBm) ->
    %% -------------------------------------------
    %% Negative SNR headroom, so we increase power.
    %%
    %% NOTE: Decreasing DataRate is not allowed.
    %% -------------------------------------------
    adjust_uplink_params(
        AdjSteps + 1,
        DataRate,
        MaxDataRate,
        TxPowerAdjustmentDBmStepSize,
        min(TxPowerDBm + TxPowerAdjustmentDBmStepSize, MaxTxPowerDBm),
        MinTxPowerDBm,
        MaxTxPowerDBm
    );
adjust_uplink_params(_, DataRate, _, _, TxPowerDBm, _, _) ->
    %% -------------------------------------------
    %% We have either:
    %% - Run out of adjustment steps.
    %% - Maxed data rate and/or pegged TxPowerDBm
    %%   to either [Max,Min]TxPowerDBm.
    %% -------------------------------------------
    {DataRate, TxPowerDBm}.

-spec adjust_uplink_params(
    CurrentDataRate :: pos_integer(),
    CurrentSpreading :: lorawan_utils:spreading(),
    MaxDataRate :: pos_integer(),
    History :: nonempty_list(#packet{}),
    WantsADRAck :: boolean(),
    ConfiguredAdrHistoryLen :: pos_integer(),
    ConfiguredSNRHeadroom :: number(),
    TxPowerTable :: lora_plan:tx_power_table(),
    TxPowerAdjustmentDBmStepSize :: number(),
    CurrentTxPowerIdx :: number()
) -> adjustment().
adjust_uplink_params(
    CurrentDataRate,
    CurrentSpreading,
    MaxDataRate,
    History,
    WantsADRAck,
    ConfiguredAdrHistoryLen,
    ConfiguredSNRHeadroom,
    TxPowerTable,
    TxPowerAdjustmentDBmStepSize,
    CurrentTxPowerIdx
) when (length(History) >= ConfiguredAdrHistoryLen) or (WantsADRAck == true) ->
    SNR_threshold = snr_threshold(CurrentSpreading),
    SNR_max = best_snr(History),
    %% TODO: add a bunch of extra headroom (e.g., perform more
    %%       conservative adjustments, or maybe no adjustments) when
    %%       we do not have enough history but WantsADRAck is true
    SNR_margin = SNR_max - SNR_threshold - ConfiguredSNRHeadroom,
    AdjSteps = trunc(SNR_margin / 3),
    {CurrentTxPowerIdx, CurrentTxPowerDBm} = lists:keyfind(
        CurrentTxPowerIdx,
        1,
        TxPowerTable
    ),
    [{_MaxTxPowerIdx, MaxTxPowerDBm} | _] = TxPowerTable,
    {_MinTxPowerIdx, MinTxPowerDBm} = lists:last(TxPowerTable),
    {AdjustedDataRate, AdjustedTxPowerDBm} = adjust_uplink_params(
        AdjSteps,
        CurrentDataRate,
        MaxDataRate,
        TxPowerAdjustmentDBmStepSize,
        CurrentTxPowerDBm,
        MinTxPowerDBm,
        MaxTxPowerDBm
    ),
    %% This part is tricky. Most places deal with
    %% indices that are absolute, but for TX power, the
    %% adjustment algorithm deals in dBm. So we need to
    %% search through the transmit power table and find
    %% the TxPowerIdx with a dBm closest to the value
    %% calculated by the adjustment algorithm.
    TxPowerPredFn = fun({_, DBm}) ->
        DBm >= AdjustedTxPowerDBm
    end,
    {AdjustedTxPowerIdx, _ActualTxPowerDBm} = lists:last(
        lists:takewhile(TxPowerPredFn, TxPowerTable)
    ),
    case
        WantsADRAck or
            (AdjustedDataRate /= CurrentDataRate) or
            (AdjustedTxPowerIdx /= CurrentTxPowerIdx)
    of
        true -> {AdjustedDataRate, AdjustedTxPowerIdx};
        false -> hold
    end;
adjust_uplink_params(
    _CurrentDataRate,
    _CurrentSpreading,
    _MaxDataRate,
    _History,
    _WantsADRAck,
    _ConfiguredAdrHistoryLen,
    _ConfiguredSNRHeadroom,
    _TxPowerTable,
    _TxPowerAdjustmentDBmStepSize,
    _CurrentTxPowerIdx
) ->
    hold.

%% Removes all offers from the offer list with hashes matching
%% `PktHash'.
%%
%% Returns the the leftover offers and count of how many offers were
%% pruned. This count is needed to calculate gateway diversity (total
%% number of gateways who a saw packet).
-spec count_and_prune_offers_for_hash(
    PktHash :: binary(),
    Offers0 :: list(offer())
) -> {integer(), list(offer())}.
count_and_prune_offers_for_hash(
    PktHash,
    Offers0
) ->
    %% Remove offers for this hash so they are not counted again.
    OfferFilterFn = fun({_Timestamp, OfferHash}) ->
        OfferHash == PktHash
    end,
    {Removed, Offers1} = lists:partition(OfferFilterFn, Offers0),
    {length(Removed), Offers1}.

%% ==================================================================
%% Tests
%% ==================================================================
-ifdef(EUNIT).

-include_lib("eunit/include/eunit.hrl").

device_history(#device{packet_history = History}) ->
    History.

device_history_len(#device{packet_history = History}) ->
    length(History).

device_offers_len(Device) ->
    length(Device#device.offer_history).

spread_and_bandwidth(State, DataRate) ->
    {DataRate, {Spread, Bandwidth}} = lorawan_adr:datarate_entry(
        State,
        DataRate
    ),
    {Spread, Bandwidth}.

gen_adr_packet(DRConfig, Snr, Rssi) ->
    RandNum = rand:uniform(4294967296),
    Packet0 = #adr_packet{
        packet_hash = <<RandNum>>,
        wants_adr = true,
        wants_adr_ack = false,
        datarate_config = DRConfig,
        snr = Snr,
        rssi = Rssi
    },
    Packet0.

gen_adr_ack(DRConfig, Snr, Rssi) ->
    RandNum = rand:uniform(4294967296),
    Packet0 = #adr_packet{
        packet_hash = <<RandNum>>,
        wants_adr = true,
        wants_adr_ack = true,
        datarate_config = DRConfig,
        snr = Snr,
        rssi = Rssi
    },
    Packet0.

post_packet_track(State, DRIdx, Snr, Rssi) ->
    DRConfig = spread_and_bandwidth(State, DRIdx),
    Packet0 = gen_adr_packet(DRConfig, Snr, Rssi),
    {State1, _} = track_packet(State, Packet0),
    State1.

get_packet_adr(State, DRIdx, Snr, Rssi) ->
    DRConfig = spread_and_bandwidth(State, DRIdx),
    Packet0 = gen_adr_ack(DRConfig, Snr, Rssi),
    {_State1, {AdjDataRate, AdjPower}} = track_packet(State, Packet0),
    {AdjDataRate, AdjPower}.

adr_jitter(Range) ->
    Range * rand:uniform().

exercise_packet_track(State, _DRIdx, Count, _Snr, _Rssi) when Count == 0 ->
    State;
exercise_packet_track(State, DRIdx, Count, Snr0, Rssi0) ->
    Snr = Snr0 - adr_jitter(0.1),
    Rssi = Rssi0 - adr_jitter(0.1),
    State1 = post_packet_track(State, DRIdx, Snr, Rssi),
    exercise_packet_track(State1, DRIdx, Count - 1, Snr, Rssi).

% valid_exercise(DR, AdjustedDR, AdjustedPower) ->
%     ?assert(AdjustedDR >= DR),
%     ?assert(AdjustedPower >= 0),
%     fin.

exercise_adr_state(State0, DRIdx, Count, Snr, Rssi) ->
    % io:format("exercise_adr_state count=~w snr=~w, rssi=~w~n", [Count, Snr, Rssi]),
    State1 = exercise_packet_track(State0, DRIdx, Count, Snr, Rssi),
    %% ?assertEqual(Count, device_history_len(State1)),
    ?assert(device_history_len(State1) < 21),
    {AdjDR, AdjPower} = get_packet_adr(State1, DRIdx, Snr, Rssi),
    ?assert(AdjDR >= 0),
    ?assert(AdjPower >= 0),
    % io:format("DR = ~w Power = ~w~n", [AdjDR, AdjPower]),
    {AdjDR, AdjPower}.

valid_exercise(State0, DRIdx, Count, Snr, Rssi, ExpectedDR, ExpectedPower) ->
    {DR, Power} = exercise_adr_state(State0, DRIdx, Count, Snr, Rssi),
    ?assertEqual(ExpectedDR, DR),
    ?assertEqual(ExpectedPower, Power).

% gen_range(Start, Step, Length) when is_number(Length) ->
%     [Start + (Step * X) || X <- lists:seq(0, Length)].

gen_startend_range(Start, Step, End) ->
    Length = round((End - Start) / Step),
    [Start + (Step * X) || X <- lists:seq(0, Length)].

adr_harness_test_() ->
    DataRate0 = 0,
    State0 = new('US915'),
    [
        ?_test(begin
            valid_exercise(State0, DataRate0, 22, 7.0, X, 3, 1)
        end)
     || X <- gen_startend_range(-120.0, 0.1, 0.0)
    ].

adr_exercise_test_() ->
    %% DataRate 0 in US915 regional parameters.
    DataRate0 = 0,
    % Spreading0 = 10,
    % Bandwidth0 = 125,
    %% Snr ranges from 10 to -20
    Snr = 10.0,
    %% Rssi ranges from 0 to -120
    Rssi = 0.0,
    % DRConfig0 = {Spreading0, Bandwidth0},

    State0 = new('US915'),
    ?assertEqual(0, device_offers_len(State0)),
    ?assertEqual(0, device_history_len(State0)),

    State1 = post_packet_track(State0, DataRate0, Snr, Rssi),
    State2 = post_packet_track(State1, DataRate0, Snr, Rssi),
    ?assertEqual(2, device_history_len(State2)),
    {_AdjDataRate2, _AdjPower2} = get_packet_adr(State2, DataRate0, Snr, Rssi),
    %% io:format("NewSpreading2 ~8.16.0B~n", [NewSpreading2]),
    % io:format("AdjDataRate2 ~w~n", [AdjDataRate2]),
    % io:format("AdjPower2 ~w~n", [AdjPower2]),

    PacketLimit = 19,
    State3 = exercise_packet_track(State0, DataRate0, PacketLimit, Snr, Rssi),
    % ?assertEqual(19, device_history_len(State3)),
    ?assert(device_history_len(State3) < 21),
    {_AdjDataRate3, _AdjPower3} = get_packet_adr(State3, DataRate0, Snr, Rssi),
    % io:format("AdjDataRate3 ~w~n", [AdjDataRate3]),
    % io:format("AdjPower3 ~w~n", [AdjPower3]),

    TestList = [
        ?_test(begin
            valid_exercise(State0, DataRate0, 1, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 3, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 7, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 17, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 19, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 20, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 21, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 22, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 100, Snr, Rssi, 3, 3)
        end),
        ?_test(begin
            valid_exercise(State0, DataRate0, 200, Snr, Rssi, 3, 3)
        end),

        ?_test(begin
            valid_exercise(State0, 0, 22, -20.0, -120.0, 0, 0)
        end),
        ?_test(begin
            valid_exercise(State0, 1, 22, -20.0, -120.0, 1, 0)
        end),
        ?_test(begin
            valid_exercise(State0, 2, 22, -20.0, -120.0, 2, 0)
        end),
        ?_test(begin
            valid_exercise(State0, 3, 22, -20.0, -120.0, 3, 0)
        end),

        [
            ?_test(begin
                valid_exercise(StateX, 0, 22, -20.0, -120.0, 0, 0)
            end)
         || StateX <- [new('US915'), new('EU868'), new('CN470'), new('AS923'), new('AU915')]
        ],
        [
            ?_test(begin
                valid_exercise(State0, 0, X, -20.0, -120.0, 0, 0)
            end)
         || X <- lists:seq(1, 200)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 0, 0)
            end)
         || X <- gen_startend_range(-20.0, 0.1, -2.5)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 1, 0)
            end)
         || X <- gen_startend_range(-1.0, 0.1, 0.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 2, 0)
            end)
         || X <- gen_startend_range(1.0, 0.1, 3.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 3, 0)
            end)
         || X <- gen_startend_range(4.0, 0.1, 6.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 3, 1)
            end)
         || X <- gen_startend_range(7.0, 0.1, 9.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 3, 3)
            end)
         || X <- gen_startend_range(10.0, 0.1, 12.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 3, 4)
            end)
         || X <- gen_startend_range(13.0, 0.1, 15.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 3, 6)
            end)
         || X <- gen_startend_range(16.0, 0.1, 18.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 3, 7)
            end)
         || X <- gen_startend_range(19.0, 0.1, 21.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, X, -120.0, 3, 9)
            end)
         || X <- gen_startend_range(22.0, 0.1, 24.9)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, 6.9, X, 3, 0)
            end)
         || X <- gen_startend_range(-120.0, 0.1, 0.0)
        ],
        [
            ?_test(begin
                valid_exercise(State0, DataRate0, 22, 7.0, X, 3, 1)
            end)
         || X <- gen_startend_range(-120.0, 0.1, 0.0)
        ]
    ],

    TestList.

adr_history_test() ->
    State0 = new('US915'),
    ?assertEqual(0, device_offers_len(State0)),
    ?assertEqual(0, device_history_len(State0)),

    DataRateConfig = {10, 125},
    Offer0 = #adr_offer{
        packet_hash = <<0>>
    },
    Packet0WeakSNR = #adr_packet{
        packet_hash = <<0>>,
        wants_adr = true,
        wants_adr_ack = false,
        datarate_config = DataRateConfig,
        snr = 0.0,
        rssi = 0.0
    },
    Packet0StrongSNR = Packet0WeakSNR#adr_packet{snr = 10},
    Offer1 = #adr_offer{
        packet_hash = <<1>>
    },
    Packet1 = Packet0StrongSNR#adr_packet{packet_hash = <<1>>},

    %% Make sure offers are stored
    State1 = track_offer(State0, Offer0),
    ?assertEqual(1, device_offers_len(State1)),
    State2 = track_offer(State1, Offer0),
    ?assertEqual(2, device_offers_len(State2)),
    State3 = track_offer(State2, Offer1),
    ?assertEqual(3, device_offers_len(State3)),

    %% Tracking a packet should clear offers with matching hashes from
    %% the offer cache.
    %%
    %% NOTE: the third offer above has a different hash and will
    %%       remain in the offer cache.
    {State4, hold} = track_packet(State3, Packet0WeakSNR),
    ?assertEqual(1, device_offers_len(State4)),
    ?assertEqual(1, device_history_len(State4)),
    [HistoryHead0 | _] = device_history(State4),
    ?assertEqual(Packet0WeakSNR#adr_packet.snr, HistoryHead0#packet.best_snr),
    ?assertEqual(3, HistoryHead0#packet.gateway_diversity),

    %% Tracking the same packet but with a stronger SNR should be
    %% reflected in history and increase gateway diversity.
    {State5, hold} = track_packet(State4, Packet0StrongSNR),
    ?assertEqual(1, device_history_len(State5)),
    [HistoryHead1 | _] = State5#device.packet_history,
    ?assertEqual(Packet0StrongSNR#adr_packet.snr, HistoryHead1#packet.best_snr),
    ?assertEqual(4, HistoryHead1#packet.gateway_diversity),

    %% An interleaved offer to packet sequence, however
    %% unlikely, should work.
    {State6, hold} = track_packet(State5, Packet1),
    ?assertEqual(2, device_history_len(State6)),
    [HistoryHead2 | _] = State6#device.packet_history,
    ?assertEqual(Packet1#adr_packet.snr, HistoryHead2#packet.best_snr),
    ?assertEqual(2, HistoryHead2#packet.gateway_diversity),
    ?assertEqual(0, device_offers_len(State6)),

    %% We clear history when the device clears the ADR bit.
    {State7, hold} = track_packet(State6, Packet1#adr_packet{wants_adr = false}),
    ?assertEqual(0, device_offers_len(State7)),
    ?assertEqual(0, device_history_len(State7)),

    fin.

adr_happy_path(State0, DRConfig) ->
    Packet0 = #adr_packet{
        rssi = 0,
        snr = 10,
        datarate_config = DRConfig,
        wants_adr = true,
        wants_adr_ack = false,
        packet_hash = <<0>>
    },
    %% Up to MIN_HISTORY_LEN - 1 packets, track_packet should still
    %% return 'hold'.
    {State1, {AdjustedDataRate, AdjustedPowerIdx}} = lists:foldl(
        fun
            (N, {ADRn, _Action}) ->
                %% ?assertEqual(hold, Action),
                lorawan_adr:track_packet(ADRn, Packet0#adr_packet{
                    packet_hash = <<N>>
                });
            (N, State2) ->
                io:format("State0 ~w~n", [N]),
                lorawan_adr:track_packet(State2, Packet0#adr_packet{
                    packet_hash = <<N>>
                })
        end,
        State0,
        lists:seq(1, ?DEFAULT_ADR_HISTORY_LEN)
    ),
    {State1, {AdjustedDataRate, AdjustedPowerIdx}}.

valid_happy_path(State0, DRConfig) ->
    {Spreading0, Bandwidth0} = DRConfig,
    {State1, {AdjustedDataRate, AdjustedPowerIdx}} = adr_happy_path(State0, DRConfig),
    {AdjustedSpread, AdjustedBandwidth} = spread_and_bandwidth(State1, AdjustedDataRate),
    ?assert(AdjustedDataRate >= 0),
    ?assert(AdjustedSpread =< Spreading0),
    ?assertEqual(AdjustedBandwidth, Bandwidth0),
    ?assertEqual(0, State1#device.max_txpower_idx),
    ?assert(AdjustedPowerIdx >= State1#device.max_txpower_idx),
    ?assert(AdjustedPowerIdx =< State1#device.min_txpower_idx).
% io:format("AdjustedDataRate ~w~n", [AdjustedDataRate]),
% io:format("AdjustedSpreading ~w~n", [AdjustedSpread]),
% io:format("AdjustedBandwidth ~w~n", [AdjustedBandwidth]),
% io:format("AdjustedPowerIdx ~w~n", [AdjustedPowerIdx]),
% io:format("Min PowerIdx ~w~n", [State1#device.min_txpower_idx]),

adr_happy_path_test_() ->
    [
        ?_test(begin
            valid_happy_path(lorawan_adr:new('US915'), {10, 125})
        end),
        ?_test(begin
            valid_happy_path(lorawan_adr:new('US915'), {9, 125})
        end),
        ?_test(begin
            valid_happy_path(lorawan_adr:new('US915'), {8, 125})
        end),
        ?_test(begin
            valid_happy_path(lorawan_adr:new('US915'), {7, 125})
        end),

        ?_test(begin
            valid_happy_path(lorawan_adr:new('EU868'), {12, 125})
        end),
        ?_test(begin
            valid_happy_path(lorawan_adr:new('EU868'), {11, 125})
        end),
        ?_test(begin
            valid_happy_path(lorawan_adr:new('EU868'), {10, 125})
        end),
        ?_test(begin
            valid_happy_path(lorawan_adr:new('EU868'), {9, 125})
        end),
        ?_test(begin
            valid_happy_path(lorawan_adr:new('EU868'), {8, 125})
        end),
        ?_test(begin
            valid_happy_path(lorawan_adr:new('EU868'), {7, 125})
        end)
    ].

adr_ack_req_test() ->
    Packet0 = #adr_packet{
        rssi = 0,
        snr = 0,
        wants_adr = true,
        wants_adr_ack = true,
        datarate_config = {7, 125},
        packet_hash = <<0>>
    },
    State0 = lorawan_adr:new('US915'),
    %% We must always respond with new uplink parameters when a device
    %% requests ADR acknowledgement, even on first packet.
    {State1, {_AdjustedDataRate, _AdjustedPowerIdx}} = lorawan_adr:track_packet(
        State0,
        Packet0
    ),
    ?assertEqual(1, device_history_len(State1)),

    fin.

%% TODO: parameterize and test over a range packet SNRs.
adr_does_adr_test() ->
    %% DataRate 0 in US915 regional parameters.
    DataRate0 = 0,
    Spreading0 = 10,
    Bandwidth0 = 125,
    DataRateConfig0 = {Spreading0, Bandwidth0},
    Packet0 = #adr_packet{
        rssi = 0,
        snr = 6,
        datarate_config = DataRateConfig0,
        wants_adr = true,
        wants_adr_ack = false,
        packet_hash = <<0>>
    },
    %% Up to MIN_HISTORY_LEN - 1 packets, track_packet should still
    %% return 'hold'.
    {State1, {AdjustedDataRate, AdjustedPowerIdx}} = lists:foldl(
        fun
            (N, {ADRn, Action}) ->
                ?assertEqual(hold, Action),
                lorawan_adr:track_packet(ADRn, Packet0#adr_packet{
                    packet_hash = <<N>>
                });
            (N, State0) ->
                lorawan_adr:track_packet(State0, Packet0#adr_packet{
                    packet_hash = <<N>>
                })
        end,
        lorawan_adr:new('US915'),
        lists:seq(1, ?DEFAULT_ADR_HISTORY_LEN)
    ),
    {AdjustedDataRate, {AdjustedSpreading, AdjustedBandwidth}} = lorawan_adr:datarate_entry(
        State1,
        AdjustedDataRate
    ),
    ?assertEqual(?DEFAULT_ADR_HISTORY_LEN, device_history_len(State1)),
    ?assert(AdjustedDataRate > DataRate0),
    ?assert(AdjustedSpreading < Spreading0),
    ?assertEqual(AdjustedBandwidth, Bandwidth0),
    ?assert(AdjustedPowerIdx >= State1#device.max_txpower_idx),
    ?assert(AdjustedPowerIdx =< State1#device.min_txpower_idx),

    %% Check that tracking a fake ADR answer from the device doesn't
    %% cause a crash.
    Answer0 = #adr_answer{
        channel_mask_ack = true,
        datarate_ack = true,
        power_ack = true
    },
    State2 = lorawan_adr:track_adr_answer(State1, Answer0),
    ?assertEqual([], State2#device.pending_adjustments),

    Answer1 = #adr_answer{
        channel_mask_ack = false,
        datarate_ack = true,
        power_ack = true
    },
    State3 = lorawan_adr:track_adr_answer(State1, Answer1),
    ?assertEqual([], State3#device.pending_adjustments),

    State4 = lorawan_adr:track_adr_answer(State2, Answer1),
    ?assertEqual([], State4#device.pending_adjustments),

    fin.

adr_new_test() ->
    State0 = lorawan_adr:new('US915'),

    %% See regional parameters document for the reference values
    %% asserted against below.

    MinDataRate = lorawan_adr:min_datarate(State0),
    MinDataRateEntryFromIndex = lorawan_adr:datarate_entry(State0, MinDataRate),
    ?assertEqual({0, {10, 125}}, MinDataRateEntryFromIndex),
    MinDataRateEntryFromConfig = lorawan_adr:datarate_entry(State0, {10, 125}),
    ?assertEqual({0, {10, 125}}, MinDataRateEntryFromConfig),

    MaxDataRate = lorawan_adr:max_datarate(State0),
    MaxDataRateEntryFromIndex = lorawan_adr:datarate_entry(State0, MaxDataRate),
    ?assertEqual({3, {7, 125}}, MaxDataRateEntryFromIndex),
    MaxDataRateEntryFromConfig = lorawan_adr:datarate_entry(State0, {7, 125}),
    ?assertEqual({3, {7, 125}}, MaxDataRateEntryFromConfig),

    InvalidDataRateConfig = lorawan_adr:datarate_entry(State0, MaxDataRate + 1),
    ?assertEqual(undefined, InvalidDataRateConfig),

    fin.

adr_resists_denial_of_service_test() ->
    State0 = lorawan_adr:new('US915'),
    Answer0 = #adr_answer{
        channel_mask_ack = true,
        datarate_ack = true,
        power_ack = true
    },
    %% This brand new state doesn't have any pending ADR
    %% requests. It should gracefully handle receiving a bogus ADR
    %% answer without crashing.
    State1 = lorawan_adr:track_adr_answer(State0, Answer0),
    ?assertEqual([], State1#device.accepted_adjustments),

    fin.

-endif.
