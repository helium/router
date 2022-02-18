%%%-------------------------------------------------------------------
%% @doc
%% Copyright (c) 2016-2019 Petr &lt;Gotthard petr.gotthard@@centrum.cz&gt;
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%% @end
%%%-------------------------------------------------------------------
-module(lorawan_mac_region).

%% Functions that map Region -> Top Level Region
-export([
    join1_window/3,
    join2_window/2,
    rx1_window/4,
    rx2_window/3,
    rx1_or_rx2_window/4,
    set_channels/3,
    max_uplink_snr/2,
    max_downlink_snr/3,
    datars/1,
    datar_to_dr/2,
    dr_to_datar/2,
    max_payload_size/2,
    uplink_power_table/1
]).

-export([freq/1, net_freqs/1]).
-export([max_uplink_snr/1]).
-export([tx_time/2, tx_time/3]).

-export([downlink_signal_strength/2]).
-export([dr_to_down/3]).
-export([window2_dr/1, top_level_region/1, freq_to_chan/2]).
-export([mk_join_accept_cf_list/1]).

-include("lorawan_db.hrl").

-define(DEFAULT_DOWNLINK_TX_POWER, 27).

-define(US915_MAX_DOWNLINK_SIZE, 242).
-define(CN470_MAX_DOWNLINK_SIZE, 242).
-define(AS923_MAX_DOWNLINK_SIZE, 250).
-define(AU915_MAX_DOWNLINK_SIZE, 250).
-define(EU868_MAX_DOWNLINK_SIZE, 222).

-define(AS923_PAYLOAD_SIZE_MAP, #{
    0 => 59,
    1 => 59,
    2 => 59,
    3 => 123,
    4 => 250,
    5 => 250,
    6 => 250,
    7 => 250
}).

-define(CN470_PAYLOAD_SIZE_MAP, #{
    0 => 51,
    1 => 51,
    2 => 51,
    3 => 115,
    4 => 242,
    5 => 242
}).

-define(US915_PAYLOAD_SIZE_MAP, #{
    0 => 11,
    1 => 53,
    2 => 125,
    3 => 242,
    4 => 242,
    %% 5 => rfu,
    %% 6 => rfu,
    %% 7 => rfu,
    8 => 53,
    9 => 129,
    10 => 242,
    11 => 242,
    12 => 242,
    13 => 242
}).

-define(AU915_PAYLOAD_SIZE_MAP, #{
    0 => 59,
    1 => 59,
    2 => 59,
    3 => 123,
    4 => 250,
    5 => 250,
    6 => 250,
    %% 7 => undefined,
    8 => 61,
    9 => 137,
    10 => 250,
    11 => 250,
    12 => 250,
    13 => 250
    %% 14 => undefined,
    %% 15 => undefined,
}).

-define(EU868_PAYLOAD_SIZE_MAP, #{
    0 => 51,
    1 => 51,
    2 => 51,
    3 => 115,
    4 => 222,
    5 => 222,
    6 => 222,
    7 => 222
    %% 8..15 => undefined
}).

%% ------------------------------------------------------------------
%% @doc === Types and Terms ===
%%
%% dr        -> Datarate Index
%% datar     -> ```<<"SFxxBWxx">>'''
%% datarate  -> Datarate Tuple {spreading, bandwidth}
%%
%% Frequency -> A Frequency
%%              - whole number 4097 (representing 409.7)
%%              - float 409.7
%% Channel   -> Index of a frequency in a regions range
%% Region    -> Atom representing a region
%%
%% @end
%% ------------------------------------------------------------------

%%        <<"SFxxBWxxx">> | FSK
-type datar() :: string() | binary() | non_neg_integer().
-type dr() :: non_neg_integer().
-type datarate() :: {Spreading :: non_neg_integer(), Bandwidth :: non_neg_integer()}.
-type freq_float() :: float().
-type freq_whole() :: non_neg_integer().
-type channel() :: non_neg_integer().

-define(JOIN1_WINDOW, join1_window).
-define(JOIN2_WINDOW, join2_window).
-define(RX1_WINDOW, rx1_window).
-define(RX2_WINDOW, rx2_window).

-type window() :: ?JOIN1_WINDOW | ?JOIN2_WINDOW | ?RX1_WINDOW | ?RX2_WINDOW.

%% ------------------------------------------------------------------
%% Region Wrapped Receive Window Functions
%% ------------------------------------------------------------------

-spec join1_window(atom(), integer(), #rxq{}) -> #txq{}.
join1_window(Region, DelaySeconds, RxQ) ->
    TopLevelRegion = top_level_region(Region),
    TxQ = rx1_rf(TopLevelRegion, RxQ, 0),
    tx_window(?JOIN1_WINDOW, RxQ, TxQ, DelaySeconds).

-spec join2_window(atom(), #rxq{}) -> #txq{}.
join2_window(Region, RxQ) ->
    TopLevelRegion = top_level_region(Region),
    TxQ = rx2_rf(TopLevelRegion, RxQ),
    tx_window(?JOIN2_WINDOW, RxQ, TxQ).

-spec rx1_window(atom(), number(), number(), #rxq{}) -> #txq{}.
rx1_window(Region, DelaySeconds, Offset, RxQ) ->
    TopLevelRegion = top_level_region(Region),
    TxQ = rx1_rf(TopLevelRegion, RxQ, Offset),
    tx_window(?RX1_WINDOW, RxQ, TxQ, DelaySeconds).

-spec rx2_window(atom(), number(), #rxq{}) -> #txq{}.
rx2_window(Region, DelaySeconds, RxQ) ->
    TopLevelRegion = top_level_region(Region),
    TxQ = rx2_rf(TopLevelRegion, RxQ),
    tx_window(?RX2_WINDOW, RxQ, TxQ, DelaySeconds).

-spec rx1_or_rx2_window(atom(), number(), number(), #rxq{}) -> #txq{}.
rx1_or_rx2_window(Region, Delay, Offset, RxQ) ->
    TopLevelRegion = top_level_region(Region),
    case TopLevelRegion of
        'EU868' ->
            if
                % In Europe the RX Windows uses different frequencies, TX power rules and Duty cycle rules.
                % If the signal is poor then prefer window 2 where TX power is higher.  See - https://github.com/helium/router/issues/423
                RxQ#rxq.rssi < -80 -> rx2_window(Region, Delay, RxQ);
                true -> rx1_window(Region, Delay, Offset, RxQ)
            end;
        _ ->
            rx1_window(Region, Delay, Offset, RxQ)
    end.

%% ------------------------------------------------------------------
%% Region Wrapped Helper Functions
%% ------------------------------------------------------------------

-spec datar_to_dr(atom(), datar()) -> dr().
datar_to_dr(Region, DataRate) ->
    TopLevelRegion = top_level_region(Region),
    datar_to_dr_(TopLevelRegion, DataRate).

-spec dr_to_datar(atom(), dr()) -> datar().
dr_to_datar(Region, DR) ->
    TopLevelRegion = top_level_region(Region),
    dr_to_datar_(TopLevelRegion, DR).

-spec max_uplink_snr(atom(), dr()) -> number().
max_uplink_snr(Region, DR) ->
    TopLevelRegion = top_level_region(Region),
    max_uplink_snr_(TopLevelRegion, DR).

-spec max_downlink_snr(atom(), dr(), number()) -> number().
max_downlink_snr(Region, DR, Offset) ->
    TopLevelRegion = top_level_region(Region),
    max_downlink_snr_(TopLevelRegion, DR, Offset).

-spec set_channels(atom(), tuple(), list()) -> list().
set_channels(Region, Tuple, FOptsOut) ->
    TopLevelRegion = top_level_region(Region),
    set_channels_(TopLevelRegion, Tuple, FOptsOut).

-spec datars(atom()) -> list({dr(), datarate(), up | down | updown}).
datars(Region) ->
    TopLevelRegion = top_level_region(Region),
    datars_(TopLevelRegion).

-spec uplink_power_table(Region :: atom()) -> tx_power_table().
uplink_power_table(Region) ->
    TopLevelRegion = top_level_region(Region),
    uplink_power_table_(TopLevelRegion).

-spec max_payload_size(atom(), dr()) -> integer().
max_payload_size(Region, DR) ->
    TopLevelRegion = top_level_region(Region),
    case TopLevelRegion of
        'AS923' -> maps:get(DR, ?AS923_PAYLOAD_SIZE_MAP, ?AS923_MAX_DOWNLINK_SIZE);
        'CN470' -> maps:get(DR, ?CN470_PAYLOAD_SIZE_MAP, ?CN470_MAX_DOWNLINK_SIZE);
        'AU915' -> maps:get(DR, ?AU915_PAYLOAD_SIZE_MAP, ?AU915_MAX_DOWNLINK_SIZE);
        'EU868' -> maps:get(DR, ?EU868_PAYLOAD_SIZE_MAP, ?EU868_MAX_DOWNLINK_SIZE);
        _ -> maps:get(DR, ?US915_PAYLOAD_SIZE_MAP, ?US915_MAX_DOWNLINK_SIZE)
    end.

%% ------------------------------------------------------------------
%% @doc Top Level Region
%% AS923 has sub-regions. Besides for the cflist during joining,
%% they should be treated the same.
%% @end
%% ------------------------------------------------------------------
-spec top_level_region(atom()) -> atom().
top_level_region('AS923_1') -> 'AS923';
top_level_region('AS923_2') -> 'AS923';
top_level_region('AS923_3') -> 'AS923';
top_level_region('AS923_4') -> 'AS923';
top_level_region(Region) -> Region.

%% ------------------------------------------------------------------
%% Internal Functions
%% ------------------------------------------------------------------

%% See RP002-1.0.1 LoRaWAN® Regional
%% For CN470 See lorawan_regional_parameters_v1.0.3reva_0.pdf

-spec rx1_rf(atom(), #rxq{}, number()) -> #txq{}.
%% we calculate in fixed-point numbers
rx1_rf(Region, #rxq{freq = Freq} = RxQ, Offset) when Region == 'US915' ->
    RxCh = f2uch(Freq, {9023, 2}, {9030, 16}),
    DownFreq = dch2f(Region, RxCh rem 8),
    tx_offset(Region, RxQ, DownFreq, Offset);
rx1_rf(Region, #rxq{freq = Freq} = RxQ, Offset) when Region == 'AU915' ->
    RxCh = f2uch(Freq, {9152, 2}, {9159, 16}),
    DownFreq = dch2f(Region, RxCh rem 8),
    tx_offset(Region, RxQ, DownFreq, Offset);
rx1_rf(Region, #rxq{freq = Freq} = RxQ, Offset) when Region == 'CN470' ->
    RxCh = f2uch(Freq, {4703, 2}),
    DownFreq = dch2f(Region, RxCh rem 48),
    tx_offset(Region, RxQ, DownFreq, Offset);
rx1_rf(Region, #rxq{freq = Freq} = RxQ, Offset) when Region == 'AS923' ->
    tx_offset(Region, RxQ, Freq, Offset);
rx1_rf(Region, #rxq{freq = Freq} = RxQ, Offset) ->
    tx_offset(Region, RxQ, Freq, Offset).

-spec rx2_rf(atom(), #rxq{}) -> #txq{}.
%% 923.3MHz / DR8 (SF12 BW500)
rx2_rf(Region, #rxq{codr = Codr, time = Time}) when Region == 'US915' ->
    #txq{
        freq = 923.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        codr = Codr,
        time = Time
    };
%% 505.3 MHz / DR0 (SF12 / BW125)
rx2_rf(Region, #rxq{codr = Codr, time = Time}) when Region == 'CN470' ->
    #txq{
        freq = 505.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        codr = Codr,
        time = Time
    };
%% 869.525 MHz / DR0 (SF12, 125 kHz)
rx2_rf(Region, #rxq{codr = Codr, time = Time}) when Region == 'EU868' ->
    #txq{
        freq = 869.525,
        datr = dr_to_datar(Region, window2_dr(Region)),
        codr = Codr,
        time = Time
    };
%% 923.2. MHz / DR2 (SF10, 125 kHz)
rx2_rf(Region, #rxq{codr = Codr, time = Time}) when Region == 'AS923' ->
    #txq{
        freq = 923.2,
        datr = dr_to_datar(Region, window2_dr(Region)),
        codr = Codr,
        time = Time
    };
%% 923.3. MHz / DR8 (SF12, 500 kHz)
rx2_rf(Region, #rxq{codr = Codr, time = Time}) when Region == 'AU915' ->
    #txq{
        freq = 923.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        codr = Codr,
        time = Time
    }.

-spec window2_dr(atom()) -> dr().
window2_dr('US915') -> 8;
window2_dr('AU915') -> 8;
window2_dr('AS923') -> 2;
window2_dr('CN470') -> 0;
window2_dr('EU868') -> 0;
window2_dr(_Region) -> 0.

%% ------------------------------------------------------------------
%% @doc Frequency to (Up/Down) Channel
%% Map Frequency to Channel for region.
%%
%% Some regions down channels overlap with their up channels, that's
%% not always the case *cough* AU915. If we can't get a channel from
%% assuming it's an uplink frequency, try to parse as a downlink
%% frequency.
%%
%% @end
%% ------------------------------------------------------------------
-spec freq_to_chan(Region :: atom(), Freq :: freq_float()) -> channel().
freq_to_chan(Region, Freq) ->
    try
        f2uch(Region, Freq)
    catch
        error:_ ->
            f2dch(Region, Freq)
    end.

%% ------------------------------------------------------------------
%% @doc Frequency to Up Channel
%% Map Frequency to Channel for region.
%% @end
%% ------------------------------------------------------------------
-spec f2uch(Region | Freq, Freq | {Start, Inc}) -> UpChannel when
    Region :: atom(),
    Freq :: freq_float(),
    Start :: freq_whole(),
    Inc :: number(),
    UpChannel :: channel().
f2uch('US915', Freq) ->
    f2uch(Freq, {9023, 2}, {9030, 16});
f2uch('AU915', Freq) ->
    f2uch(Freq, {9152, 2}, {9159, 16});
f2uch('CN470', Freq) ->
    f2uch(Freq, {4073, 2});
f2uch('EU868', Freq) when Freq < 868 ->
    f2uch(Freq, {8671, 2}) + 3;
f2uch('EU868', Freq) when Freq > 868 ->
    f2uch(Freq, {8681, 2});
f2uch('AS923_1', Freq) ->
    case Freq of
        923.2 -> 1;
        923.4 -> 2;
        _ -> f2uch(Freq, {9236, 2}) + 2
    end;
f2uch('AS923_2', Freq) ->
    case Freq of
        921.4 -> 1;
        921.6 -> 2;
        _ -> f2uch(Freq, {9218, 2}) + 2
    end;
f2uch('AS923_3', Freq) ->
    case Freq of
        916.6 -> 1;
        916.8 -> 2;
        _ -> f2uch(Freq, {9170, 2}) + 2
    end;
f2uch('AS923_4', Freq) ->
    case Freq of
        917.3 -> 1;
        917.5 -> 2;
        _ -> f2uch(Freq, {9177, 2}) + 2
    end;
f2uch('AS923', Freq) ->
    case Freq of
        923.2 -> 1;
        923.4 -> 2;
        _ -> f2uch(Freq, {9222, 2}, {9236, 2})
    end;
f2uch(Freq, {Start, Inc}) ->
    round(10 * Freq - Start) div Inc.

%% the channels are overlapping, return the integer value
f2uch(Freq, {Start1, Inc1}, _) when round(10 * Freq - Start1) rem Inc1 == 0 ->
    round(10 * Freq - Start1) div Inc1;
f2uch(Freq, _, {Start2, Inc2}) when round(10 * Freq - Start2) rem Inc2 == 0 ->
    64 + round(10 * Freq - Start2) div Inc2.

%% ------------------------------------------------------------------
%% @doc Frequency to Down Channel
%% Map Frequency to Channel for region.
%% @end
%% ------------------------------------------------------------------
-spec f2dch(Region :: atom(), Freq :: freq_float()) -> channel().
f2dch('AU915', Freq) -> 64 + fi2ch(Freq, {9233, 6});
f2dch(Region, Freq) -> f2uch(Region, Freq).

%% ------------------------------------------------------------------
%% @doc Up Channel to Frequency
%% Map Channel to Frequency for region.
%% @end
%% ------------------------------------------------------------------
-spec uch2f(Region, Channel) -> freq_float() when
    Region :: atom(),
    Channel :: channel().
uch2f(Region, Ch) when Region == 'US915' andalso Ch < 64 ->
    ch2fi(Ch, {9023, 2});
uch2f(Region, Ch) when Region == 'US915' ->
    ch2fi(Ch - 64, {9030, 16});
uch2f('AU915', Ch) when Ch < 64 ->
    ch2fi(Ch, {9152, 2});
uch2f('AU915', Ch) ->
    ch2fi(Ch - 64, {9159, 16});
uch2f('CN470', Ch) ->
    ch2fi(Ch, {4703, 2}).

%% ------------------------------------------------------------------
%% @doc Down Channel to Frequency
%% Map Channel to Frequency for region
%% @end
%% ------------------------------------------------------------------
-spec dch2f(Region, Channel) -> Frequency when
    Region :: atom(),
    Channel :: non_neg_integer(),
    Frequency :: freq_float().
dch2f(Region, Ch) when Region == 'US915'; Region == 'AU915' ->
    ch2fi(Ch, {9233, 6});
dch2f('CN470', Ch) ->
    ch2fi(Ch, {5003, 2}).

%% ------------------------------------------------------------------
%% @doc Channel to Frequency Index
%% Given a Frequency Index = (Inc * Channel) + Start
%% (y = mx + b)
%% @end
%% ------------------------------------------------------------------
-spec ch2fi(Channel, {Start, Inc}) -> Freq when
    Channel :: channel(),
    Start :: non_neg_integer(),
    Inc :: non_neg_integer(),
    Freq :: freq_float().
ch2fi(Ch, {Start, Inc}) -> (Ch * Inc + Start) / 10.

%% ------------------------------------------------------------------
%% @doc Frequency Index to Channel
%% Given a Channel = (Frequency Index - Start) / Inc
%% x = (y-b) / m
%% @end
%% ------------------------------------------------------------------
-spec fi2ch(Freq, {Start, Inc}) -> Channel when
    Channel :: channel(),
    Start :: non_neg_integer(),
    Inc :: non_neg_integer(),
    Freq :: freq_float().
fi2ch(Freq, {Start, Inc}) -> round(10 * Freq - Start) div Inc.

tx_offset(Region, RxQ, Freq, Offset) ->
    DataRate = datar_to_down(Region, RxQ#rxq.datr, Offset),
    #txq{freq = Freq, datr = DataRate, codr = RxQ#rxq.codr, time = RxQ#rxq.time}.

%% These only specify LoRaWAN default values; see also tx_window()
-spec get_window(window()) -> number().
get_window(?JOIN1_WINDOW) -> 5000000;
get_window(?JOIN2_WINDOW) -> 6000000;
get_window(?RX1_WINDOW) -> 1000000;
get_window(?RX2_WINDOW) -> 2000000.

-spec tx_window(window(), #rxq{}, #txq{}) -> #txq{}.
tx_window(Window, #rxq{tmms = Stamp} = Rxq, TxQ) when is_integer(Stamp) ->
    tx_window(Window, Rxq, TxQ, 0).

%% LoRaWAN Link Layer v1.0.4 spec, Section 5.7 Setting Delay between TX and RX,
%% Table 45 and "RX2 always opens 1s after RX1."
-spec tx_window(atom(), #rxq{}, #txq{}, number()) -> #txq{}.
tx_window(?JOIN1_WINDOW, #rxq{tmms = Stamp}, TxQ, _RxDelaySeconds) when is_integer(Stamp) ->
    Delay = get_window(?JOIN1_WINDOW),
    TxQ#txq{time = Stamp + Delay};
tx_window(?JOIN2_WINDOW, #rxq{tmms = Stamp}, TxQ, _RxDelaySeconds) when is_integer(Stamp) ->
    Delay = get_window(?JOIN2_WINDOW),
    TxQ#txq{time = Stamp + Delay};
tx_window(Window, #rxq{tmms = Stamp}, TxQ, RxDelaySeconds) when is_integer(Stamp) ->
    %% TODO check if the time is a datetime, which would imply gps timebase
    Delay =
        case RxDelaySeconds of
            N when N < 2 ->
                get_window(Window);
            N ->
                case Window of
                    ?RX2_WINDOW ->
                        N * 1000000 + 1000000;
                    _ ->
                        N * 1000000
                end
        end,
    TxQ#txq{time = Stamp + Delay}.

%% ------------------------------------------------------------------
%% @doc Up Datarate tuple to Down Datarate tuple
%% @end
%% ------------------------------------------------------------------
-spec datar_to_down(atom(), datar(), non_neg_integer()) -> datar().
datar_to_down(Region, DataRate, Offset) ->
    DR2 = dr_to_down(Region, datar_to_dr(Region, DataRate), Offset),
    dr_to_datar(Region, DR2).

-spec dr_to_down(atom(), dr(), non_neg_integer()) -> dr().
dr_to_down(Region, DR, Offset) when Region == 'AS923' ->
    %% TODO: should be derived based on DownlinkDwellTime
    %% 2.8.7 of lorawan_regional_parameters1.0.3reva_0.pdf -- We don't send
    %% downlink dwell time the device, so we're assuming it's 0 for the time
    %% being.
    MinDR = 0,
    EffOffset =
        if
            Offset > 5 -> 5 - Offset;
            true -> Offset
        end,
    min(5, max(MinDR, DR - EffOffset));
dr_to_down(Region, DR, Offset) ->
    lists:nth(Offset + 1, drs_to_down(Region, DR)).

-spec drs_to_down(atom(), dr()) -> list(dr()).
drs_to_down(Region, DR) when Region == 'US915' ->
    case DR of
        0 -> [10, 9, 8, 8];
        1 -> [11, 10, 9, 8];
        2 -> [12, 11, 10, 9];
        3 -> [13, 12, 11, 10];
        4 -> [13, 13, 12, 11]
    end;
drs_to_down(Region, DR) when Region == 'AU915' ->
    case DR of
        0 -> [8, 8, 8, 8, 8, 8];
        1 -> [9, 8, 8, 8, 8, 8];
        2 -> [10, 9, 8, 8, 8, 8];
        3 -> [11, 10, 9, 8, 8, 8];
        4 -> [12, 11, 10, 9, 8, 8];
        5 -> [13, 12, 11, 10, 9, 8];
        6 -> [13, 13, 12, 11, 10, 9]
    end;
drs_to_down(Region, DR) when Region == 'CN470' ->
    case DR of
        0 -> [0, 0, 0, 0, 0, 0];
        1 -> [1, 0, 0, 0, 0, 0];
        2 -> [2, 1, 0, 0, 0, 0];
        3 -> [3, 2, 1, 0, 0, 0];
        4 -> [4, 3, 2, 1, 0, 0];
        5 -> [5, 4, 3, 2, 1, 0]
    end;
drs_to_down(_Region, DR) ->
    case DR of
        0 -> [0, 0, 0, 0, 0, 0];
        1 -> [1, 0, 0, 0, 0, 0];
        2 -> [2, 1, 0, 0, 0, 0];
        3 -> [3, 2, 1, 0, 0, 0];
        4 -> [4, 3, 2, 1, 0, 0];
        5 -> [5, 4, 3, 2, 1, 0];
        6 -> [6, 5, 4, 3, 2, 1];
        7 -> [7, 6, 5, 4, 3, 2]
    end.

%% data rate and end-device output power encoding
-spec datars_(atom()) -> list({dr(), datarate(), up | down | updown}).
datars_(Region) when Region == 'US915' ->
    [
        {0, {10, 125}, up},
        {1, {9, 125}, up},
        {2, {8, 125}, up},
        {3, {7, 125}, up},
        {4, {8, 500}, up}
        | us_down_datars()
    ];
datars_(Region) when Region == 'AU915' ->
    [
        {0, {12, 125}, up},
        {1, {11, 125}, up},
        {2, {10, 125}, up},
        {3, {9, 125}, up},
        {4, {8, 125}, up},
        {5, {7, 125}, up},
        {6, {8, 500}, up}
        | us_down_datars()
    ];
datars_(Region) when Region == 'CN470' ->
    [
        {0, {12, 125}, updown},
        {1, {11, 125}, updown},
        {2, {10, 125}, updown},
        {3, {9, 125}, updown},
        {4, {8, 125}, updown},
        {5, {7, 125}, updown}
    ];
datars_(Region) when Region == 'AS923' ->
    [
        {0, {12, 125}, updown},
        {1, {11, 125}, updown},
        {2, {10, 125}, updown},
        {3, {9, 125}, updown},
        {4, {8, 125}, updown},
        {5, {7, 125}, updown},
        {6, {7, 250}, updown},
        %% FSK
        {7, 50000, updown}
    ];
datars_(_Region) ->
    [
        {0, {12, 125}, updown},
        {1, {11, 125}, updown},
        {2, {10, 125}, updown},
        {3, {9, 125}, updown},
        {4, {8, 125}, updown},
        {5, {7, 125}, updown},
        {6, {7, 250}, updown},
        %% FSK
        {7, 50000, updown}
    ].

-spec us_down_datars() -> list({dr(), datarate(), down}).
us_down_datars() ->
    [
        {8, {12, 500}, down},
        {9, {11, 500}, down},
        {10, {10, 500}, down},
        {11, {9, 500}, down},
        {12, {8, 500}, down},
        {13, {7, 500}, down}
    ].

%% ------------------------------------------------------------------
%% @doc Datarate Index to Datarate Tuple
%% @end
%% ------------------------------------------------------------------
-spec dr_to_tuple(atom(), dr()) -> datarate().
dr_to_tuple(Region, DR) ->
    {_, DataRate, _} = lists:keyfind(DR, 1, datars(Region)),
    DataRate.

%% ------------------------------------------------------------------
%% @doc Datarate Index to Datarate Binary
%% @end
%% ------------------------------------------------------------------
-spec dr_to_datar_(atom(), dr()) -> datar().
dr_to_datar_(Region, DR) ->
    tuple_to_datar(dr_to_tuple(Region, DR)).

%% ------------------------------------------------------------------
%% @doc Datarate Tuple to Datarate Index
%% @end
%% ------------------------------------------------------------------
-spec datar_to_dr_(atom(), datar()) -> dr().
datar_to_dr_(Region, DataRate) ->
    {DR, _, _} = lists:keyfind(datar_to_tuple(DataRate), 2, datars(Region)),
    DR.

%% ------------------------------------------------------------------
%% @doc Datarate Tuple to Datarate Binary
%% NOTE: FSK is a special case.
%% @end
%% ------------------------------------------------------------------
-spec tuple_to_datar(datarate()) -> datar().
tuple_to_datar({SF, BW}) ->
    <<"SF", (integer_to_binary(SF))/binary, "BW", (integer_to_binary(BW))/binary>>.

%% ------------------------------------------------------------------
%% @doc Datarate Binary to Datarate Tuple
%% NOTE: FSK is a special case.
%% @end
%% ------------------------------------------------------------------
-spec datar_to_tuple(datar()) -> datarate() | non_neg_integer().

datar_to_tuple(DataRate) when is_binary(DataRate) ->
    [SF, BW] = binary:split(DataRate, [<<"SF">>, <<"BW">>], [global, trim_all]),
    {binary_to_integer(SF), binary_to_integer(BW)};
datar_to_tuple(DataRate) when is_list(DataRate) ->
    datar_to_tuple(erlang:list_to_binary(DataRate));
datar_to_tuple(DataRate) when is_integer(DataRate) ->
    %% FSK
    DataRate.

codr_to_tuple(CodingRate) ->
    [A, B] = binary:split(CodingRate, [<<"/">>], [global, trim_all]),
    {binary_to_integer(A), binary_to_integer(B)}.

-type tx_power_table_entry() :: {Index :: pos_integer(), DBm :: number()}
%% A tuple of `{TableIndex, dBm}'.
.

-type tx_power_table() :: list(tx_power_table_entry())
%% A table of available transmit powers, specific to a region.
.

-spec uplink_power_table_(Region :: atom()) -> tx_power_table().
uplink_power_table_('US915') ->
    [
        {0, 30},
        {1, 28},
        {2, 26},
        {3, 24},
        {4, 22},
        {5, 20},
        {6, 18},
        {7, 16},
        {8, 14},
        {9, 12},
        {10, 10}
    ];
uplink_power_table_('AU915') ->
    uplink_power_table_('US915');
uplink_power_table_('CN470') ->
    %% NOTE: CN470's power levels are relative to the devices max power;
    %%       they are dB, not dBm.
    [
        {0, 0},
        {1, -2},
        {2, -4},
        {3, -6},
        {4, -8},
        {5, -10},
        {6, -12},
        {7, -14}
    ];
uplink_power_table_('CN779') ->
    [
        {0, 10},
        {1, 7},
        {2, 4},
        {3, 1},
        {4, -2},
        {5, -5}
    ];
uplink_power_table_('AS923') ->
    %% NOTE: AS923's power levels are relative the device's max power;
    %%       they are dB, not dBm.
    [
        {0, 0},
        {1, -2},
        {2, -4},
        {3, -6},
        {4, -8},
        {5, -10},
        {6, -12},
        {7, -14}
    ];
uplink_power_table_('KR920') ->
    [
        {0, 20},
        {1, 14},
        {2, 10},
        {3, 8},
        {4, 5},
        {5, 2},
        {6, 0}
    ];
uplink_power_table_('EU868') ->
    [
        {0, 20},
        {1, 14},
        {2, 11},
        {3, 8},
        {4, 5},
        {5, 2}
    ].

%% ------------------------------------------------------------------
%% @doc
%% Bobcat team was testing and noticed downlink `rf_power' was too high for CN470.
%%
%% longAP team was testing and also noticed `rf_power' was too high for EU868.
%% Followup from disk91:
%% https://www.etsi.org/deliver/etsi_en/300200_300299/30022002/03.02.01_60/en_30022002v030201p.pdf (page 22)
%% MwToDb = fun(Mw) -> round(10 * math:log10(Mw)) end.
%%
%% NOTE: We may want to reduce to default tx_power
%% @end
%% ------------------------------------------------------------------
-spec downlink_signal_strength(atom(), freq_whole() | freq_float()) -> non_neg_integer().
downlink_signal_strength('CN470', _Freq) -> 16;
downlink_signal_strength('EU868', Freq) when 869.4 =< Freq andalso Freq < 869.65 -> 27;
downlink_signal_strength('EU868', _Freq) -> 14;
downlink_signal_strength(_Region, _Freq) -> ?DEFAULT_DOWNLINK_TX_POWER.

%% static channel plan parameters
freq('EU868') ->
    #{min => 863, max => 870, default => [868.10, 868.30, 868.50]};
freq('US915') ->
    #{min => 902, max => 928};
freq('CN7797') ->
    #{min => 779.5, max => 786.5, default => [779.5, 779.7, 779.9]};
freq('EU433') ->
    #{min => 433.175, max => 434.665, default => [433.175, 433.375, 433.575]};
freq('AU915') ->
    #{min => 915, max => 928};
freq('CN470') ->
    #{min => 470, max => 510};
freq('AS923') ->
    #{min => 915, max => 928, default => [923.20, 923.40]};
freq('KR920') ->
    #{min => 920.9, max => 923.3, default => [922.1, 922.3, 922.5]};
freq('IN865') ->
    #{min => 865, max => 867, default => [865.0625, 865.4025, 865.985]};
freq('RU868') ->
    #{min => 864, max => 870, default => [868.9, 869.1]}.

net_freqs(#network{region = Region, init_chans = Chans}) when
    Region == 'US915'; Region == 'AU915'; Region == 'CN470'
->
    %% convert enabled channels to frequencies
    lists:map(
        fun(Ch) -> uch2f(Region, Ch) end,
        expand_intervals(Chans)
    );
net_freqs(#network{name = Name, region = Region, init_chans = Chans, cflist = CFList}) ->
    #{default := Freqs0} = freq(Region),
    {Freqs1, _, _} = lists:unzip3(CFList),
    Freqs = Freqs0 ++ Freqs1,
    %% list the enabled frequencies
    lists:filtermap(
        fun
            (Ch) when Ch < length(Freqs) ->
                {true, lists:nth(Ch + 1, Freqs)};
            (TooLarge) ->
                lager:error("network '~s' channel frequency ~B not defined", [Name, TooLarge]),
                false
        end,
        expand_intervals(Chans)
    ).

max_uplink_snr(DataRate) ->
    {SF, _} = datar_to_tuple(DataRate),
    max_snr(SF).

max_uplink_snr_(Region, DataRate) ->
    {SF, _} = dr_to_tuple(Region, DataRate),
    max_snr(SF).

max_downlink_snr_(Region, DataRate, Offset) ->
    {SF, _} = dr_to_tuple(Region, dr_to_down(Region, DataRate, Offset)),
    max_snr(SF).

%% from SX1272 DataSheet, Table 13
max_snr(SF) ->
    %% dB
    -5 - 2.5 * (SF - 6).

%% -------------------------------------------------------------------
%% CFList functions
%% -------------------------------------------------------------------

-spec mk_join_accept_cf_list(atom()) -> binary().
mk_join_accept_cf_list('US915') ->
    %% https://lora-alliance.org/wp-content/uploads/2021/05/RP-2-1.0.3.pdf
    %% Page 33
    Chans = [{8, 15}],
    ChMaskTable = [
        {2, mask, build_chmask(Chans, {0, 15})},
        {2, mask, build_chmask(Chans, {16, 31})},
        {2, mask, build_chmask(Chans, {32, 47})},
        {2, mask, build_chmask(Chans, {48, 63})},
        {2, mask, build_chmask(Chans, {64, 71})},
        {2, rfu, 0},
        {3, rfu, 0},
        {1, cf_list_type, 1}
    ],
    cf_list_for_channel_mask_table(ChMaskTable);
mk_join_accept_cf_list('EU868') ->
    %% In this case the CFList is a list of five channel frequencies for the channels
    %% three to seven whereby each frequency is encoded as a 24 bits unsigned integer
    %% (three octets). All these channels are usable for DR0 to DR5 125kHz LoRa
    %% modulation. The list of frequencies is followed by a single CFListType octet
    %% for a total of 16 octets. The CFListType SHALL be equal to zero (0) to indicate
    %% that the CFList contains a list of frequencies.
    %%
    %% The actual channel frequency in Hz is 100 x frequency whereby values representing
    %% frequencies below 100 MHz are reserved for future use.
    cflist_for_frequencies([8671000, 8673000, 8675000, 8677000, 8679000]);
mk_join_accept_cf_list('AS923_1') ->
    cflist_for_frequencies([9236000, 9238000, 9240000, 9242000, 9244000]);
mk_join_accept_cf_list('AS923_2') ->
    cflist_for_frequencies([9218000, 9220000, 9222000, 9224000, 9226000]);
mk_join_accept_cf_list('AS923_3') ->
    cflist_for_frequencies([9170000, 9172000, 9174000, 9176000, 9178000]);
mk_join_accept_cf_list('AS923_4') ->
    cflist_for_frequencies([9177000, 9179000, 9181000, 9183000, 9185000]);
mk_join_accept_cf_list(_Region) ->
    <<>>.

-spec cflist_for_frequencies(list(non_neg_integer())) -> binary().
cflist_for_frequencies(Frequencies) ->
    Channels = <<
        <<X:24/integer-unsigned-little>>
        || X <- Frequencies
    >>,
    <<Channels/binary, 0:8/integer>>.

-spec cf_list_for_channel_mask_table([
    {ByteSize :: pos_integer(), Type :: atom(), Value :: non_neg_integer()}
]) -> binary().
cf_list_for_channel_mask_table(ChMaskTable) ->
    <<<<Val:Size/little-unit:8>> || {Size, _, Val} <- ChMaskTable>>.

%% link_adr_req command

set_channels_(Region, {TXPower, DataRate, Chans}, FOptsOut) when
    Region == 'US915'; Region == 'AU915'
->
    case all_bit({0, 63}, Chans) of
        true ->
            [
                {link_adr_req, datar_to_dr(Region, DataRate), TXPower,
                    build_chmask(Chans, {64, 71}), 6, 0}
                | FOptsOut
            ];
        false ->
            [
                {link_adr_req, datar_to_dr(Region, DataRate), TXPower,
                    build_chmask(Chans, {64, 71}), 7, 0}
                | append_mask(Region, 3, {TXPower, DataRate, Chans}, FOptsOut)
            ]
    end;
set_channels_(Region, {TXPower, DataRate, Chans}, FOptsOut) when Region == 'CN470' ->
    case all_bit({0, 95}, Chans) of
        true ->
            [{link_adr_req, datar_to_dr(Region, DataRate), TXPower, 0, 6, 0} | FOptsOut];
        false ->
            append_mask(Region, 5, {TXPower, DataRate, Chans}, FOptsOut)
    end;
set_channels_(Region, {TXPower, DataRate, Chans}, FOptsOut) ->
    [
        {link_adr_req, datar_to_dr(Region, DataRate), TXPower, build_chmask(Chans, {0, 15}), 0, 0}
        | FOptsOut
    ].

all_bit(MinMax, Chans) ->
    lists:any(
        fun(Tuple) -> match_whole(MinMax, Tuple) end,
        Chans
    ).

match_whole(MinMax, {A, B}) when B < A ->
    match_whole(MinMax, {B, A});
match_whole({Min, Max}, {A, B}) ->
    (A =< Min) and (B >= Max).

expand_intervals([{A, B} | Rest]) ->
    lists:seq(A, B) ++ expand_intervals(Rest);
expand_intervals([]) ->
    [].

-spec build_chmask(
    list({non_neg_integer(), non_neg_integer()}),
    {non_neg_integer(), non_neg_integer()}
) -> non_neg_integer().
build_chmask(Chans, {Min, Max}) ->
    Bits = Max - Min + 1,
    lists:foldl(
        fun(Tuple, Acc) ->
            <<Num:Bits>> = build_chmask0({Min, Max}, Tuple),
            Num bor Acc
        end,
        0,
        Chans
    ).

build_chmask0(MinMax, {A, B}) when B < A ->
    build_chmask0(MinMax, {B, A});
build_chmask0({Min, Max}, {A, B}) when B < Min; Max < A ->
    %% out of range
    <<0:(Max - Min + 1)>>;
build_chmask0({Min, Max}, {A, B}) ->
    C = max(Min, A),
    D = min(Max, B),
    Bits = Max - Min + 1,
    %% construct the binary
    Bin = <<-1:(D - C + 1), 0:(C - Min)>>,
    case bit_size(Bin) rem Bits of
        0 -> Bin;
        N -> <<0:(Bits - N), Bin/bits>>
    end.

append_mask(_Region, Idx, _, FOptsOut) when Idx < 0 ->
    FOptsOut;
append_mask(Region, Idx, {TXPower, DataRate, Chans}, FOptsOut) ->
    append_mask(
        Region,
        Idx - 1,
        {TXPower, DataRate, Chans},
        case build_chmask(Chans, {16 * Idx, 16 * (Idx + 1) - 1}) of
            0 ->
                FOptsOut;
            ChMask ->
                [{link_adr_req, datar_to_dr(Region, DataRate), TXPower, ChMask, Idx, 0} | FOptsOut]
        end
    ).

%% transmission time estimation

tx_time(FOpts, FRMPayloadSize, TxQ) ->
    tx_time(phy_payload_size(FOpts, FRMPayloadSize), TxQ).

phy_payload_size(FOpts, FRMPayloadSize) ->
    1 + 7 + byte_size(FOpts) + 1 + FRMPayloadSize + 4.

tx_time(PhyPayloadSize, #txq{datr = DataRate, codr = CodingRate}) ->
    {SF, BW} = datar_to_tuple(DataRate),
    {4, CR} = codr_to_tuple(CodingRate),
    tx_time(PhyPayloadSize, SF, CR, BW * 1000).

%% see http://www.semtech.com/images/datasheet/LoraDesignGuide_STD.pdf
tx_time(PL, SF, CR, 125000) when SF == 11; SF == 12 ->
    %% Optimization is mandated with spreading factors of 11 and 12 at 125 kHz bandwidth
    tx_time(PL, SF, CR, 125000, 1);
tx_time(PL, SF, CR, 250000) when SF == 12 ->
    %% The firmware uses also optimization for SF 12 at 250 kHz bandwidth
    tx_time(PL, SF, CR, 250000, 1);
tx_time(PL, SF, CR, BW) ->
    tx_time(PL, SF, CR, BW, 0).

tx_time(PL, SF, CR, BW, DE) ->
    TSym = math:pow(2, SF) / BW,
    %% lorawan uses an explicit header
    PayloadSymbNb = 8 + max(ceiling((8 * PL - 4 * SF + 28 + 16) / (4 * (SF - 2 * DE))) * CR, 0),
    %% lorawan uses 8 symbols preamble
    %% the last +1 is a correction based on practical experiments
    1000 * ((8 + 4.25) + PayloadSymbNb + 1) * TSym.

ceiling(X) ->
    T = erlang:trunc(X),
    case (X - T) of
        Neg when Neg < 0 -> T;
        Pos when Pos > 0 -> T + 1;
        _ -> T
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

us_window_1_test() ->
    Now = os:timestamp(),

    RxQ = #rxq{
        freq = 923.3,
        datr = <<"SF10BW125">>,
        codr = <<"4/5">>,
        time = calendar:now_to_datetime(Now),
        tmms = 0,
        rssi = 42.2,
        lsnr = 10.1
    },

    TxQ = rx1_window('US915', 0, 0, RxQ),
    DR = datar_to_dr('US915', TxQ#txq.datr),
    ?assertEqual(500, element(2, dr_to_tuple('US915', DR))),

    ?assert(datar_to_dr('US915', TxQ#txq.datr) >= 8),
    ?assert(datar_to_dr('US915', TxQ#txq.datr) =< 13),
    ok.

us_window_2_test() ->
    Now = os:timestamp(),

    RxQ = #rxq{
        freq = 923.3,
        datr = <<"SF10BW125">>,
        codr = <<"4/5">>,
        time = calendar:now_to_datetime(Now),
        tmms = 0,
        rssi = 42.2,
        lsnr = 10.1
    },

    lists:foreach(
        fun(TxQ) ->
            ?assertEqual(datar_to_dr('US915', TxQ#txq.datr), 8),
            ?assertEqual(TxQ#txq.freq, 923.3)
        end,
        [rx2_window('US915', 0, RxQ), join2_window('US915', RxQ)]
    ),

    ok.

cn470_window_1_test() ->
    Now = os:timestamp(),
    %% 96 up + 48 down = 144 total
    Channel = 95,

    RxQ = #rxq{
        freq = uch2f('CN470', Channel),
        datr = <<"SF12BW125">>,
        codr = <<"4/5">>,
        time = calendar:now_to_datetime(Now),
        tmms = 0,
        rssi = 42.2,
        lsnr = 10.1
    },

    Step = 0.2,
    MinDownlinkFreq = 500.3,
    MaxDownlinkFreq = MinDownlinkFreq + (Step * 48),

    lists:foreach(
        fun({Window, TxQ}) ->
            %% Within Downlink window
            ?assert(MinDownlinkFreq < TxQ#txq.freq),
            ?assert(TxQ#txq.freq < MaxDownlinkFreq),

            ?assertEqual(TxQ#txq.freq, dch2f('CN470', Channel rem 48)),
            ?assertEqual(TxQ#txq.datr, RxQ#rxq.datr, "Datarate is the same"),
            ?assertEqual(TxQ#txq.codr, RxQ#rxq.codr, "Coderate is the same"),
            ?assertEqual(TxQ#txq.time, RxQ#rxq.tmms + get_window(Window))
        end,
        [
            {join1_window, join1_window('CN470', 0, RxQ)},
            {rx1_window, rx1_window('CN470', 0, 0, RxQ)}
        ]
    ),
    ok.

cn470_window_2_test() ->
    Now = os:timestamp(),
    %% 96 up + 48 down = 144 total
    Channel = 95,

    RxQ = #rxq{
        freq = uch2f('CN470', Channel),
        datr = <<"SF12BW125">>,
        codr = <<"4/5">>,
        time = calendar:now_to_datetime(Now),
        tmms = 0,
        rssi = 42.2,
        lsnr = 10.1
    },

    lists:foreach(
        fun({Window, TxQ}) ->
            ?assertEqual(TxQ#txq.freq, 505.3, "Frequency is hardcoded"),
            ?assertEqual(TxQ#txq.datr, <<"SF12BW125">>, "Datarate is hardcoded"),
            ?assertEqual(TxQ#txq.codr, RxQ#rxq.codr, "Coderate is the same"),
            ?assertEqual(TxQ#txq.time, RxQ#rxq.tmms + get_window(Window))
        end,
        [
            {join2_window, join2_window('CN470', RxQ)},
            {rx2_window, rx2_window('CN470', 0, RxQ)}
        ]
    ),
    ok.

as923_window_1_test() ->
    Now = os:timestamp(),

    RxQ = #rxq{
        freq = 9232000,
        datr = dr_to_datar('AS923', 0),
        codr = <<"4/5">>,
        time = calendar:now_to_datetime(Now),
        tmms = 0,
        rssi = 42.2,
        lsnr = 10.1
    },

    lists:foreach(
        fun({Window, TxQ}) ->
            ?assertEqual(TxQ#txq.freq, RxQ#rxq.freq, "Frequency is same as uplink"),
            ?assertEqual(TxQ#txq.codr, RxQ#rxq.codr, "Coderate is the same"),
            ?assertEqual(TxQ#txq.time, RxQ#rxq.tmms + get_window(Window))
        end,
        [
            {join1_window, join1_window('AS923', 0, RxQ)},
            {rx1_window, rx1_window('AS923', 0, 0, RxQ)}
        ]
    ),

    %% FIXME: How does the DR actually change?
    %%        Put this test back when we fix the TODO in `dr_to_down/3'
    %% lists:foreach(
    %%     fun({TxQ, {expected_dr, Expected}}) ->
    %%         ?assertEqual(datar_to_dr('AS923_AS1', TxQ#txq.datr), Expected),
    %%         ?assertEqual(TxQ#txq.datr, dr_to_datar('AS923_AS1', Expected))
    %%     end,
    %%     [
    %%         {rx1_window('AS923_AS1', _Delay = 0, _Offset0 = 0, RxQ), {expected_dr, 0}},
    %%         {rx1_window('AS923_AS1', _Delay = 0, _Offset1 = 1, RxQ), {expected_dr, 1}},
    %%         {rx1_window('AS923_AS1', _Delay = 0, _Offset2 = 2, RxQ), {expected_dr, 2}},
    %%         {rx1_window('AS923_AS1', _Delay = 0, _Offset3 = 3, RxQ), {expected_dr, 3}},
    %%         {rx1_window('AS923_AS1', _Delay = 0, _Offset4 = 4, RxQ), {expected_dr, 4}},
    %%         {rx1_window('AS923_AS1', _Delay = 0, _Offset5 = 5, RxQ), {expected_dr, 5}},
    %%         {rx1_window('AS923_AS1', _Delay = 0, _Offset6 = 6, RxQ), {expected_dr, 5}},
    %%         {rx1_window('AS923_AS1', _Delay = 0, _Offset7 = 7, RxQ), {expected_dr, 5}}
    %%     ]
    %% ),
    ok.

as923_window_2_test() ->
    Now = os:timestamp(),

    RxQ = #rxq{
        freq = 100.0,
        datr = <<"SF7BW250">>,
        codr = <<"4/5">>,
        time = calendar:now_to_datetime(Now),
        tmms = 0,
        rssi = 42.2,
        lsnr = 10.1
    },

    lists:foreach(
        fun({Window, TxQ}) ->
            ?assertEqual(TxQ#txq.freq, 923.2, "Frequency is hardcoded"),
            ?assertEqual(TxQ#txq.datr, <<"SF10BW125">>, "Datarate is hardcoded DR2"),
            ?assertEqual(TxQ#txq.codr, RxQ#rxq.codr, "Coderate is the same"),
            ?assertEqual(TxQ#txq.time, RxQ#rxq.tmms + get_window(Window))
        end,
        [
            {join2_window, join2_window('AS923', RxQ)},
            {rx2_window, rx2_window('AS923', 0, RxQ)}
        ]
    ),
    ok.

region_test_() ->
    [
        ?_assertEqual({12, 125}, datar_to_tuple(<<"SF12BW125">>)),
        ?_assertEqual({4, 6}, codr_to_tuple(<<"4/6">>)),
        %% values [ms] verified using the LoRa Calculator, +1 chirp correction based on experiments
        ?_assertEqual(1024, test_tx_time(<<"0123456789">>, <<"SF12BW125">>, <<"4/5">>)),
        ?_assertEqual(297, test_tx_time(<<"0123456789">>, <<"SF10BW125">>, <<"4/5">>)),
        ?_assertEqual(21, test_tx_time(<<"0123456789">>, <<"SF7BW250">>, <<"4/5">>)),
        ?_assertEqual(11, test_tx_time(<<"0123456789">>, <<"SF7BW500">>, <<"4/5">>)),
        ?_assertEqual(dr_to_datar('EU868', 0), <<"SF12BW125">>),
        ?_assertEqual(dr_to_datar('US915', 8), <<"SF12BW500">>),
        ?_assertEqual(datar_to_dr('EU868', <<"SF9BW125">>), 3),
        ?_assertEqual(datar_to_dr('US915', <<"SF7BW500">>), 13),
        ?_assertEqual(<<"SF10BW500">>, datar_to_down('US915', <<"SF10BW125">>, 0)),
        ?_assertEqual([0, 1, 2, 3, 4, 5, 6, 7], [
            lorawan_mac_region:freq_to_chan('EU868', F)
            || F <- [868.1, 868.3, 868.5, 867.1, 867.3, 867.5, 867.7, 867.9]
        ]),
        ?_assertEqual([0, 1, 2, 3, 4, 5, 6, 7], [
            lorawan_mac_region:freq_to_chan('US915', F)
            || F <- [902.3, 902.5, 902.7, 902.9, 903.1, 903.3, 903.5, 903.7]
        ]),
        ?_assertEqual([8, 9, 10, 11, 12, 13, 14, 15], [
            lorawan_mac_region:freq_to_chan('US915', F)
            || F <- [903.9, 904.1, 904.3, 904.5, 904.7, 904.9, 905.1, 905.3]
        ])
    ].

test_tx_time(Packet, DataRate, CodingRate) ->
    round(
        tx_time(
            byte_size(Packet),
            %% the constants are only to make Dialyzer happy
            #txq{freq = 869.525, datr = DataRate, codr = CodingRate}
        )
    ).

bits_test_() ->
    [
        ?_assertEqual([0, 1, 2, 5, 6, 7, 8, 9], expand_intervals([{0, 2}, {5, 9}])),
        ?_assertEqual(7, build_chmask([{0, 2}], {0, 15})),
        ?_assertEqual(0, build_chmask([{0, 2}], {16, 31})),
        ?_assertEqual(65535, build_chmask([{0, 71}], {0, 15})),
        ?_assertEqual(16#FF00, build_chmask([{8, 15}], {0, 15})),
        ?_assertEqual(16#F800, build_chmask([{11, 15}], {0, 15})),
        ?_assertEqual(16#F000, build_chmask([{12, 15}], {0, 15})),
        ?_assertEqual(16#0F00, build_chmask([{8, 11}], {0, 15})),
        ?_assertEqual(0, build_chmask([{8, 15}], {16, 31})),
        ?_assertEqual(0, build_chmask([{8, 15}], {32, 47})),
        ?_assertEqual(0, build_chmask([{8, 15}], {48, 63})),
        ?_assertEqual(0, build_chmask([{8, 15}], {64, 71})),
        ?_assertEqual(16#1, build_chmask([{64, 64}], {64, 71})),
        ?_assertEqual(16#2, build_chmask([{65, 65}], {64, 71})),
        ?_assertEqual(16#7, build_chmask([{64, 66}], {64, 71})),
        ?_assertEqual(true, some_bit({0, 71}, [{0, 71}])),
        ?_assertEqual(true, all_bit({0, 71}, [{0, 71}])),
        ?_assertEqual(false, none_bit({0, 71}, [{0, 71}])),
        ?_assertEqual(true, some_bit({0, 15}, [{0, 2}])),
        ?_assertEqual(false, all_bit({0, 15}, [{0, 2}])),
        ?_assertEqual(false, none_bit({0, 15}, [{0, 2}])),
        ?_assertEqual(
            [{link_adr_req, datar_to_dr('EU868', <<"SF12BW125">>), 14, 7, 0, 0}],
            set_channels('EU868', {14, <<"SF12BW125">>, [{0, 2}]}, [])
        ),
        ?_assertEqual(
            [
                {link_adr_req, datar_to_dr('US915', <<"SF12BW500">>), 20, 0, 7, 0},
                {link_adr_req, datar_to_dr('US915', <<"SF12BW500">>), 20, 255, 0, 0}
            ],
            set_channels('US915', {20, <<"SF12BW500">>, [{0, 7}]}, [])
        ),
        ?_assertEqual(
            [
                {link_adr_req, datar_to_dr('US915', <<"SF12BW500">>), 20, 2, 7, 0},
                {link_adr_req, datar_to_dr('US915', <<"SF12BW500">>), 20, 65280, 0, 0}
            ],
            set_channels('US915', {20, <<"SF12BW500">>, [{8, 15}, {65, 65}]}, [])
        )
    ].

mk_join_accept_cf_list_test_() ->
    [
        ?_assertEqual(
            %% Active Channels 8-15
            <<0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>,
            mk_join_accept_cf_list('US915')
        ),
        ?_assertEqual(
            %% Freqs 923.6, 923.8, 924.0, 924.2, 924.4
            <<32, 238, 140, 240, 245, 140, 192, 253, 140, 144, 5, 141, 96, 13, 141, 0>>,
            mk_join_accept_cf_list('AS923_1')
        ),
        ?_assertEqual(
            %% Freqs 921.8, 922.0, 922.2, 922.4, 922.6
            <<208, 167, 140, 160, 175, 140, 112, 183, 140, 64, 191, 140, 16, 199, 140, 0>>,
            mk_join_accept_cf_list('AS923_2')
        ),
        ?_assertEqual(
            %% Freqs 917.0, 917.2, 917.4, 917.6, 917.8
            <<80, 236, 139, 32, 244, 139, 240, 251, 139, 192, 3, 140, 144, 11, 140, 0>>,
            mk_join_accept_cf_list('AS923_3')
        ),
        ?_assertEqual(
            %% Freqs 917.7, 917.9, 918.1, 918.3, 918.5
            <<168, 7, 140, 120, 15, 140, 72, 23, 140, 24, 31, 140, 232, 38, 140, 0>>,
            mk_join_accept_cf_list('AS923_4')
        ),
        ?_assertEqual(
            %% Freqs 867.1, 867.3, 867.5, 867.7, 867.9
            <<24, 79, 132, 232, 86, 132, 184, 94, 132, 136, 102, 132, 88, 110, 132, 0>>,
            mk_join_accept_cf_list('EU868')
        )
    ].

%%--------------------------------------------------------------------
%% Private Utilities
%%--------------------------------------------------------------------

some_bit(MinMax, Chans) ->
    lists:any(
        fun(Tuple) -> match_part(MinMax, Tuple) end,
        Chans
    ).

none_bit(MinMax, Chans) ->
    lists:all(
        fun(Tuple) -> not match_part(MinMax, Tuple) end,
        Chans
    ).

match_part(MinMax, {A, B}) when B < A ->
    match_part(MinMax, {B, A});
match_part({Min, Max}, {A, B}) ->
    (A =< Max) and (B >= Min).

-endif.
%% end of file
