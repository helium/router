%%%-------------------------------------------------------------------
%% @doc
%% Copyright (c) 2016-2019 Petr &lt;Gotthard petr.gotthard@@centrum.cz&gt;
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%% @end
%%%-------------------------------------------------------------------
-module(lorawan_mac_region).

-dialyzer([no_return, no_unused, no_match]).

-export([freq/1, net_freqs/1, datars/1, datar_to_dr/2, dr_to_datar/2]).
-export([join1_window/2, join1_window/3, join2_window/2, rx1_window/4, rx1_window/3, rx2_window/2]).
-export([max_uplink_snr/1, max_uplink_snr/2, max_downlink_snr/3]).
-export([set_channels/3]).
-export([tx_time/2, tx_time/3]).
-export([f2uch/2]).
-export([uplink_power_table/1]).
-export([max_payload_size/2]).
-export([downlink_signal_strength/1]).
-export([dr_to_down/3]).
-export([window2_dr/1]).

-include("lorawan_db.hrl").

-define(DEFAULT_DOWNLINK_TX_POWER, 27).

-define(US915_MAX_DOWNLINK_SIZE, 242).
-define(CN470_MAX_DOWNLINK_SIZE, 242).
-define(AS923_MAX_DOWNLINK_SIZE, 250).
-define(AU915_MAX_DOWNLINK_SIZE, 250).

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

%% receive windows

-spec join1_window(atom(), integer(), #rxq{}) -> #txq{}.
join1_window(Region, _Delay, RxQ) ->
    tx_window(?FUNCTION_NAME, RxQ, rx1_rf(Region, RxQ, 0)).

%% UNUSED, we don't use #network{}
-spec join1_window(#network{}, #rxq{}) -> #txq{}.
join1_window(#network{region = Region}, RxQ) ->
    tx_window(?FUNCTION_NAME, RxQ, rx1_rf(Region, RxQ, 0)).

%% See RP002-1.0.1 LoRaWAN® Regional
%% For CN470 See lorawan_regional_parameters_v1.0.3reva_0.pdf

-spec join2_window(atom(), #rxq{}) -> #txq{}.
%% 923.3MHz / DR8 (SF12 BW500)
join2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'US915' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 923.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    };
%% 505.3 MHz / DR0 (SF12 / BW125)
join2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'CN470' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 505.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    };
%% 869.525 MHz / DR0 (SF12, 125 kHz)
join2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'EU868' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 869.525,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    };
%% 923.2. MHz / DR2 (SF10, 125 kHz)
join2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'AS923' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 923.2,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    };
join2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'AU915' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 923.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    }.

-spec rx1_window(atom(), number(), number(), #rxq{}) -> #txq{}.
rx1_window(Region, _Delay, Offset, RxQ) ->
    tx_window(?FUNCTION_NAME, RxQ, rx1_rf(Region, RxQ, Offset)).

%% UNUSED, we don't use #network{}
-spec rx1_window(#network{}, #node{}, #rxq{}) -> #txq{}.
rx1_window(#network{region = Region}, #node{rxwin_use = {Offset, _, _}}, RxQ) ->
    tx_window(?FUNCTION_NAME, RxQ, rx1_rf(Region, RxQ, Offset)).

%% See RP002-1.0.1 LoRaWAN® Regional

-spec rx2_window(atom(), #rxq{}) -> #txq{}.
%% 923.3MHz / DR8 (SF12 BW500)
rx2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'US915' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 923.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    };
%% 505.3 MHz / DR0 (SF12 / BW125)
rx2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'CN470' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 505.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    };
%% 869.525 MHz / DR0 (SF12, 125 kHz)
rx2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'EU868' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 869.525,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    };
%% 923.2. MHz / DR2 (SF10, 125 kHz)
rx2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'AS923' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 923.2,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    };
%% 923.3. MHz / DR8 (SF12, 500 kHz)
rx2_window(Region, #rxq{tmms = Stamp} = RxQ) when Region == 'AU915' ->
    Delay = get_window(?FUNCTION_NAME),
    #txq{
        freq = 923.3,
        datr = dr_to_datar(Region, window2_dr(Region)),
        time = Stamp + Delay,
        codr = RxQ#rxq.codr
    }.

-spec window2_dr(atom()) -> dr().
window2_dr('US915') -> 8;
window2_dr('AU915') -> 8;
window2_dr('AS923') -> 2;
window2_dr('CN470') -> 0;
window2_dr('EU868') -> 0;
window2_dr(_Region) -> 0.

-spec rx1_rf(atom(), #rxq{}, number()) -> #txq{}.
%% we calculate in fixed-point numbers
rx1_rf('US915' = Region, RxQ, Offset) ->
    RxCh = f2uch(RxQ#rxq.freq, {9023, 2}, {9030, 16}),
    DownFreq = dch2f(Region, RxCh rem 8),
    tx_offset(Region, RxQ, DownFreq, Offset);
rx1_rf('AU915' = Region, RxQ, Offset) ->
    RxCh = f2uch(RxQ#rxq.freq, {9152, 2}, {9159, 16}),
    DownFreq = dch2f(Region, RxCh rem 8),
    tx_offset(Region, RxQ, DownFreq, Offset);
rx1_rf('CN470' = Region, RxQ, Offset) ->
    RxCh = f2uch(RxQ#rxq.freq, {4703, 2}),
    DownFreq = dch2f(Region, RxCh rem 48),
    tx_offset(Region, RxQ, DownFreq, Offset);
rx1_rf('AS923' = Region, RxQ, Offset) ->
    tx_offset(Region, RxQ, RxQ#rxq.freq, Offset);
rx1_rf(Region, RxQ, Offset) ->
    tx_offset(Region, RxQ, RxQ#rxq.freq, Offset).
%% TODO: original file does not have rx1_rf function to handle EU868 and
%% other, is support required ?
%% rx1_rf('EU868' = Region, RxQ, Offset) ->
%%    RxCh = f2uch(RxQ#rxq.freq, {9023, 2}, {9030, 16}),
%%    tx_offset(Region, RxQ, dch2f(Region, RxCh rem 8), Offset);

%% TODO: Remove unless we want to refactor to use #network{}
%% rx2_rf(#network{region=Region, tx_codr=CodingRate}, #node{rxwin_use={_, DataRate, Freq}}) ->
%%     #txq{freq=Freq, datr=dr_to_datar(Region, DataRate), codr=CodingRate};
%% rx2_rf(#network{region=Region, tx_codr=CodingRate,
%%        rxwin_init=WinInit}, #profile{rxwin_set=WinSet}) ->
%%     {_, DataRate, Freq} = lorawan_mac_commands:merge_rxwin(WinSet, WinInit),
%%     #txq{freq=Freq, datr=dr_to_datar(Region, DataRate), codr=CodingRate}.

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

tx_offset(Region, RxQ, Freq, Offset) ->
    DataRate = datar_to_down(Region, RxQ#rxq.datr, Offset),
    #txq{freq = Freq, datr = DataRate, codr = RxQ#rxq.codr, time = RxQ#rxq.time}.

-spec get_window(atom()) -> number().
get_window(join1_window) -> 5000000;
get_window(join2_window) -> 6000000;
get_window(rx1_window) -> 1000000;
get_window(rx2_window) -> 2000000.

-spec tx_window(atom(), #rxq{}, #txq{}) -> #txq{}.
tx_window(Window, #rxq{tmms = Stamp}, TxQ) when is_integer(Stamp) ->
    %% TODO check if the time is a datetime, which would imply gps timebase
    %% TODO handle rx delay here
    Delay = get_window(Window),
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
-spec datars(atom()) -> list({dr(), datarate(), up | down | updown}).
datars(Region) when Region == 'US915' ->
    [
        {0, {10, 125}, up},
        {1, {9, 125}, up},
        {2, {8, 125}, up},
        {3, {7, 125}, up},
        {4, {8, 500}, up}
        | us_down_datars()
    ];
datars(Region) when Region == 'AU915' ->
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
datars(Region) when Region == 'CN470' ->
    [
        {0, {12, 125}, updown},
        {1, {11, 125}, updown},
        {2, {10, 125}, updown},
        {3, {9, 125}, updown},
        {4, {8, 125}, updown},
        {5, {7, 125}, updown}
    ];
datars(Region) when Region == 'AS923' ->
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
datars(_Region) ->
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
-spec dr_to_datar(atom(), dr()) -> datar().
dr_to_datar(Region, DR) ->
    tuple_to_datar(dr_to_tuple(Region, DR)).

%% ------------------------------------------------------------------
%% @doc Datarate Tuple to Datarate Index
%% @end
%% ------------------------------------------------------------------
-spec datar_to_dr(atom(), datar()) -> dr().
datar_to_dr(Region, DataRate) ->
    {DR, _, _} = lists:keyfind(datar_to_tuple(DataRate), 2, datars(Region)),
    DR.

%% ------------------------------------------------------------------
%% @doc Datarate Tuple to Datarate Binary
%% NOTE: FSK is a special case.
%% @end
%% ------------------------------------------------------------------
-spec tuple_to_datar(datarate() | non_neg_integer()) -> datar().
tuple_to_datar({SF, BW}) ->
    <<"SF", (integer_to_binary(SF))/binary, "BW", (integer_to_binary(BW))/binary>>;
tuple_to_datar(DataRate) ->
    %% FSK
    DataRate.

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

-spec uplink_power_table(Region :: atom()) -> tx_power_table().
uplink_power_table('US915') ->
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
uplink_power_table('AU915') ->
    uplink_power_table('US915');
uplink_power_table('CN470') ->
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
uplink_power_table('CN779') ->
    [
        {0, 10},
        {1, 7},
        {2, 4},
        {3, 1},
        {4, -2},
        {5, -5}
    ];
uplink_power_table('AS923') ->
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
uplink_power_table('KR920') ->
    [
        {0, 20},
        {1, 14},
        {2, 10},
        {3, 8},
        {4, 5},
        {5, 2},
        {6, 0}
    ];
uplink_power_table('EU868') ->
    [
        {0, 20},
        {1, 14},
        {2, 11},
        {3, 8},
        {4, 5},
        {5, 2}
    ].

-spec max_payload_size(atom(), dr()) -> integer().
max_payload_size(Region, DR) ->
    case Region of
        'AS923' -> maps:get(DR, ?AS923_PAYLOAD_SIZE_MAP, ?AS923_MAX_DOWNLINK_SIZE);
        'CN470' -> maps:get(DR, ?CN470_PAYLOAD_SIZE_MAP, ?CN470_MAX_DOWNLINK_SIZE);
        'AU915' -> maps:get(DR, ?AU915_PAYLOAD_SIZE_MAP, ?AU915_MAX_DOWNLINK_SIZE);
        _ -> maps:get(DR, ?US915_PAYLOAD_SIZE_MAP, ?US915_MAX_DOWNLINK_SIZE)
    end.

%% ------------------------------------------------------------------
%% @doc
%% Bobcat team was testing and noticed downlink `rf_power' was too high for CN470.
%%
%% longAP team was testing and also noticed `rf_power' was too high for EU868.
%% Max for EU868 is uplink power index 0.
%%
%% NOTE: We may want to reduce to default tx_power
%% @end
%% ------------------------------------------------------------------
-spec downlink_signal_strength(atom()) -> non_neg_integer().
downlink_signal_strength('CN470') -> 16;
downlink_signal_strength('EU868') -> 20;
downlink_signal_strength(_Region) -> ?DEFAULT_DOWNLINK_TX_POWER.

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

max_uplink_snr(Region, DataRate) ->
    {SF, _} = dr_to_tuple(Region, DataRate),
    max_snr(SF).

max_downlink_snr(Region, DataRate, Offset) ->
    {SF, _} = dr_to_tuple(Region, dr_to_down(Region, DataRate, Offset)),
    max_snr(SF).

%% from SX1272 DataSheet, Table 13
max_snr(SF) ->
    %% dB
    -5 - 2.5 * (SF - 6).

%% link_adr_req command

set_channels(Region, {TXPower, DataRate, Chans}, FOptsOut) when
    Region == 'US915'; Region == 'AU915'
->
    case all_bit({0, 63}, Chans) of
        true ->
            [
                {link_adr_req, datar_to_dr(Region, DataRate), TXPower, build_bin(Chans, {64, 71}),
                    6, 0}
                | FOptsOut
            ];
        false ->
            [
                {link_adr_req, datar_to_dr(Region, DataRate), TXPower, build_bin(Chans, {64, 71}),
                    7, 0}
                | append_mask(Region, 3, {TXPower, DataRate, Chans}, FOptsOut)
            ]
    end;
set_channels(Region, {TXPower, DataRate, Chans}, FOptsOut) when Region == 'CN470' ->
    case all_bit({0, 95}, Chans) of
        true ->
            [{link_adr_req, datar_to_dr(Region, DataRate), TXPower, 0, 6, 0} | FOptsOut];
        false ->
            append_mask(Region, 5, {TXPower, DataRate, Chans}, FOptsOut)
    end;
set_channels(Region, {TXPower, DataRate, Chans}, FOptsOut) ->
    [
        {link_adr_req, datar_to_dr(Region, DataRate), TXPower, build_bin(Chans, {0, 15}), 0, 0}
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

build_bin(Chans, {Min, Max}) ->
    Bits = Max - Min + 1,
    lists:foldl(
        fun(Tuple, Acc) ->
            <<Num:Bits>> = build_bin0({Min, Max}, Tuple),
            Num bor Acc
        end,
        0,
        Chans
    ).

build_bin0(MinMax, {A, B}) when B < A ->
    build_bin0(MinMax, {B, A});
build_bin0({Min, Max}, {A, B}) when B < Min; Max < A ->
    %% out of range
    <<0:(Max - Min + 1)>>;
build_bin0({Min, Max}, {A, B}) ->
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
        case build_bin(Chans, {16 * Idx, 16 * (Idx + 1) - 1}) of
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
        [rx2_window('US915', RxQ), join2_window('US915', RxQ)]
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
            {rx2_window, rx2_window('CN470', RxQ)}
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
            {join1_window, join1_window('AS923', _Delay = 0, RxQ)},
            {rx1_window, rx1_window('AS923', _Delay = 0, _Offset0 = 0, RxQ)}
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
            {rx2_window, rx2_window('AS923', RxQ)}
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
            lorawan_mac_region:f2uch('EU868', F)
            || F <- [868.1, 868.3, 868.5, 867.1, 867.3, 867.5, 867.7, 867.9]
        ]),
        ?_assertEqual([0, 1, 2, 3, 4, 5, 6, 7], [
            lorawan_mac_region:f2uch('US915', F)
            || F <- [902.3, 902.5, 902.7, 902.9, 903.1, 903.3, 903.5, 903.7]
        ]),
        ?_assertEqual([8, 9, 10, 11, 12, 13, 14, 15], [
            lorawan_mac_region:f2uch('US915', F)
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
        ?_assertEqual(7, build_bin([{0, 2}], {0, 15})),
        ?_assertEqual(0, build_bin([{0, 2}], {16, 31})),
        ?_assertEqual(65535, build_bin([{0, 71}], {0, 15})),
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
