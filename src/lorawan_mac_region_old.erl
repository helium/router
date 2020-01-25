                                                %
                                                % Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
                                                % All rights reserved.
                                                % Distributed under the terms of the MIT License. See the LICENSE file.
                                                %
-module(lorawan_mac_region_old).

-export([join1_window/2, join2_window/2, rx1_window/3, rx2_window/2, rx2_rf/2]).
-export([default_adr/1, default_rxwin/1, max_adr/1, eirp_limits/1]).
-export([dr_to_tuple/2, datar_to_dr/2, freq_range/1, datar_to_tuple/1, powe_to_num/2, regional_config/2]).

join1_window(Region, RxQ) ->
    tx_time(join1_delay, maps:get(<<"tmst">>, RxQ), rx1_rf(Region, RxQ, 0)).

join2_window(Region, RxQ) ->
    tx_time(join2_delay, maps:get(<<"tmst">>, RxQ), rx2_rf(Region, RxQ)).

rx1_window(Region, Offset, RxQ) ->
    tx_time(rx1_delay, maps:get(<<"tmst">>, RxQ), rx1_rf(Region, RxQ, Offset)).

rx2_window(Region, RxQ) ->
    tx_time(rx2_delay, maps:get(<<"tmst">>, RxQ), rx2_rf(Region, RxQ)).

                                                % we calculate in fixed-point numbers
rx1_rf(Region, RxQ, Offset)
  when Region == <<"EU863-870">>; Region == <<"CN779-787">>; Region == <<"EU433">>; Region == <<"KR920-923">> ->
    rf_same(Region, RxQ, maps:get(<<"freq">>, RxQ), Offset);
rx1_rf(<<"US902-928">> = Region, RxQ, Offset) ->
    RxCh = f2ch(maps:get(<<"freq">>, RxQ), {9023, 2}, {9030, 16}),
    rf_same(Region, RxQ, ch2f(Region, RxCh rem 8), Offset);
rx1_rf(<<"US902-928-PR">> = Region, RxQ, Offset) ->
    RxCh = f2ch(maps:get(<<"freq">>, RxQ), {9023, 2}, {9030, 16}),
    rf_same(Region, RxQ, ch2f(Region, RxCh div 8), Offset);
rx1_rf(<<"AU915-928">> = Region, RxQ, Offset) ->
    RxCh = f2ch(maps:get(<<"freq">>, RxQ), {9152, 2}, {9159, 16}),
    rf_same(Region, RxQ, ch2f(Region, RxCh rem 8), Offset);
rx1_rf(<<"CN470-510">> = Region, RxQ, Offset) ->
    RxCh = f2ch(maps:get(<<"freq">>, RxQ), {4703, 2}),
    rf_same(Region, RxQ, ch2f(Region, RxCh rem 48), Offset).

rx2_rf(<<"US902-928-PR">> = Region, RxQ) ->
    RxCh = f2ch(maps:get(<<"freq">>, RxQ), {9023, 2}, {9030, 16}),
    rf_same(Region, RxQ, ch2f(Region, RxCh div 8), 0);
rx2_rf(Region, RxQ) ->
    rf_fixed(Region, RxQ).

f2ch(Freq, {Start, Inc}) -> round(10*Freq-Start) div Inc.

                                                % the channels are overlapping, return the integer value
f2ch(Freq, {Start1, Inc1}, _) when round(10*Freq-Start1) rem Inc1 == 0 ->
    round(10*Freq-Start1) div Inc1;
f2ch(Freq, _, {Start2, Inc2}) when round(10*Freq-Start2) rem Inc2 == 0 ->
    64 + round(10*Freq-Start2) div Inc2.

ch2f(<<"EU863-870">>, Ch) ->
    if
        Ch >= 0, Ch =< 2 ->
            ch2fi(Ch, {8681, 2});
        Ch >= 3, Ch =< 7 ->
            ch2fi(Ch, {8671, 2});
        Ch == 8 ->
            868.8
    end;
ch2f(<<"CN779-787">>, Ch) ->
    ch2fi(Ch, {7795, 2});
ch2f(<<"EU433">>, Ch) ->
    ch2fi(Ch, {4331.75, 2});
ch2f(Region, Ch)
  when Region == <<"US902-928">>; Region == <<"US902-928-PR">>; Region == <<"AU915-928">> ->
    ch2fi(Ch, {9233, 6});
ch2f(<<"CN470-510">>, Ch) ->
    ch2fi(Ch, {5003, 2}).

ch2fi(Ch, {Start, Inc}) -> (Ch*Inc + Start)/10.

rf_fixed(Region, RxQ) ->
    {Freq, DataRate} = regional_config(rx2_rf, Region),
    #{region => Region, freq => Freq, datr => DataRate, codr => maps:get(<<"codr">>, RxQ)}.

rf_same(Region, RxQ, Freq, Offset) ->
    DataRate = datar_to_down(Region, maps:get(<<"datr">>, RxQ), Offset),
    #{region => Region, freq => Freq, datr => DataRate, codr => maps:get(<<"codr">>, RxQ)}.

                                                %rf_group(Group) ->
                                                %#{region => Group#multicast_group.region,
                                                %freq => ch2f(Group#multicast_group.region, Group#multicast_group.chan),
                                                %datr => dr_to_datar(Group#multicast_group.region, Group#multicast_group.datr),
                                                %codr => Group#multicast_group.datr}.

get_window(join1_delay) -> 5000000;
get_window(join2_delay) -> 6000000;
get_window(rx1_delay) -> 1000000;
get_window(rx2_delay) -> 2000000.

tx_time(Window, Stamp, TxQ) ->
    Delay = get_window(Window),
    maps:put(tmst, Stamp+Delay, TxQ).

datar_to_down(Region, DataRate, Offset) ->
    Down = dr_to_down(Region, datar_to_dr(Region, DataRate)),
    dr_to_datar(Region, lists:nth(Offset+1, Down)).

dr_to_down(Region, DR)
  when Region == <<"EU863-870">>; Region == <<"CN779-787">>; Region == <<"EU433">>;
       Region == <<"CN470-510">>; Region == <<"KR920-923">> ->
    case DR of
        0 -> [0, 0, 0, 0, 0, 0];
        1 -> [1, 0, 0, 0, 0, 0];
        2 -> [2, 1, 0, 0, 0, 0];
        3 -> [3, 2, 1, 0, 0, 0];
        4 -> [4, 3, 2, 1, 0, 0];
        5 -> [5, 4, 3, 2, 1, 0];
        6 -> [6, 5, 4, 3, 2, 1];
        7 -> [7, 6, 5, 4, 3, 2]
    end;
dr_to_down(Region, DR)
  when Region == <<"US902-928">>; Region == <<"US902-928-PR">>; Region == <<"AU915-928">> ->
    case DR of
        0 -> [10, 9,  8,  8];
        1 -> [11, 10, 9,  8];
        2 -> [12, 11, 10, 9];
        3 -> [13, 12, 11, 10];
        4 -> [13, 13, 12, 11]
    end.

                                                % data rate conversions

datars(Region)
  when Region == <<"EU863-870">>; Region == <<"CN779-787">>; Region == <<"EU433">>;
       Region == <<"CN470-510">>; Region == <<"KR920-923">> -> [
                                                                {0, {12, 125}},
                                                                {1, {11, 125}},
                                                                {2, {10, 125}},
                                                                {3, {9, 125}},
                                                                {4, {8, 125}},
                                                                {5, {7, 125}},
                                                                {6, {7, 250}}];
datars(Region)
  when Region == <<"US902-928">>; Region == <<"US902-928-PR">>; Region == <<"AU915-928">> -> [
                                                                                              {0,  {10, 125}},
                                                                                              {1,  {9, 125}},
                                                                                              {2,  {8, 125}},
                                                                                              {3,  {7, 125}},
                                                                                              {4,  {8, 500}},
                                                                                              {8,  {12, 500}},
                                                                                              {9,  {11, 500}},
                                                                                              {10, {10, 500}},
                                                                                              {11, {9, 500}},
                                                                                              {12, {8, 500}},
                                                                                              {13, {7, 500}}].

dr_to_tuple(Region, DR) ->
    case lists:keyfind(DR, 1, datars(Region)) of
        {_, DataRate} -> DataRate;
        false -> undefined
    end.

dr_to_datar(Region, DR) ->
    tuple_to_datar(dr_to_tuple(Region, DR)).

datar_to_dr(Region, DataRate) ->
    case lists:keyfind(datar_to_tuple(DataRate), 2, datars(Region)) of
        {DR, _} -> DR;
        false -> undefined
    end.

tuple_to_datar({SF, BW}) ->
    <<"SF", (integer_to_binary(SF))/binary, "BW", (integer_to_binary(BW))/binary>>.

datar_to_tuple(DataRate) ->
    [SF, BW] = binary:split(DataRate, [<<"SF">>, <<"BW">>], [global, trim_all]),
    {binary_to_integer(SF), binary_to_integer(BW)}.

powers(Region)
  when Region == <<"EU863-870">> -> [
                                     {0, 20},
                                     {1, 14},
                                     {2, 11},
                                     {3, 8},
                                     {4, 5},
                                     {5, 2}];
powers(Region)
  when Region == <<"US902-928">>; Region == <<"US902-928-PR">>;
       Region == <<"AU915-928">> -> [
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
                                     {10, 10}];
powers(Region)
  when Region == <<"CN779-787">>; Region == <<"EU433">> -> [
                                                            {0, 10},
                                                            {1, 7},
                                                            {2, 4},
                                                            {3, 1},
                                                            {4, -2},
                                                            {5, -5}];
powers(Region)
  when Region == <<"CN470-510">> -> [
                                     {0, 17},
                                     {1, 16},
                                     {2, 14},
                                     {3, 12},
                                     {4, 10},
                                     {5, 7},
                                     {6, 5},
                                     {7, 2}];
powers(Region)
  when Region == <<"KR920-923">> -> [
                                     {0, 20},
                                     {1, 14},
                                     {2, 10},
                                     {3, 8},
                                     {4, 5},
                                     {5, 2},
                                     {6, 0}].

powe_to_num(Region, Pow) ->
    case lists:keyfind(Pow, 1, powers(Region)) of
        {_, Power} -> Power;
        false -> undefined
    end.

regional_config(Param, Region) ->
    Regions = [
               {<<"EU863-870">>, [
                                                % default RX2 frequency (MHz) and data rate (DRx)
                                  {rx2_rf, {869.525, <<"SF12BW125">>}}
                                 ]},
               {<<"US902-928">>, [
                                  {rx2_rf, {923.3, <<"SF12BW500">>}}
                                 ]},
                                                % Multitech Private Hybrid Mode
                                                % http://www.multitech.net/developer/software/lora/introduction-to-lora
               {<<"US902-928-PR">>, [
                                     {rx2_rf, {undefined, <<"SF12BW500">>}}
                                    ]},
               {<<"CN779-787">>, [
                                  {rx2_rf, {786, <<"SF12BW125">>}}
                                 ]},
               {<<"EU433">>, [
                              {rx2_rf, {434.665, <<"SF12BW125">>}}
                             ]},
               {<<"AU915-928">>, [
                                  {rx2_rf, {923.3, <<"SF12BW500">>}}
                                 ]},
               {<<"CN470-510">>, [
                                  {rx2_rf, {505.3, <<"SF12BW125">>}}
                                 ]},
               {<<"KR920-923">>, [
                                  {rx2_rf, {921.9, <<"SF12BW125">>}}
                                 ]}
              ],
    Config = proplists:get_value(Region, Regions, []),
    proplists:get_value(Param, Config).

                                                % {TXPower, DataRate, Chans}
default_adr(<<"EU863-870">>) -> {1, 0, [{0,2}]};
default_adr(<<"US902-928">>) -> {5, 0, [{0,71}]};
default_adr(<<"US902-928-PR">>) -> {5, 0, [{0,7}]};
default_adr(<<"CN779-787">>) -> {1, 0, [{0,2}]};
default_adr(<<"EU433">>) -> {0, 0, [{0,2}]};
default_adr(<<"AU915-928">>) -> {5, 0, [{0,71}]};
default_adr(<<"CN470-510">>) -> {2, 0, [{0, 95}]};
default_adr(<<"KR920-923">>) -> {1, 0, [{0, 2}]}.

                                                % {RX1DROffset, RX2DataRate, Frequency}
default_rxwin(Region) ->
    {Freq, DataRate} = regional_config(rx2_rf, Region),
    {0, datar_to_dr(Region, DataRate), Freq}.

                                                % {TXPower, DataRate}
max_adr(<<"EU863-870">>) -> {5, 6};
max_adr(<<"US902-928">>) -> {10, 4};
max_adr(<<"US902-928-PR">>) -> {10, 4};
max_adr(<<"CN779-787">>) -> {5, 6};
max_adr(<<"EU433">>) -> {5, 6};
max_adr(<<"AU915-928">>) -> {10, 4};
max_adr(<<"CN470-510">>) -> {7, 6};
max_adr(<<"KR920-923">>) -> {6, 5}.

                                                % {default, maximal} power for downlinks (dBm)
eirp_limits(<<"EU863-870">>) -> {14, 20};
eirp_limits(<<"US902-928">>) -> {20, 26};
eirp_limits(<<"US902-928-PR">>) -> {20, 26};
eirp_limits(<<"CN779-787">>) -> {10, 10};
eirp_limits(<<"EU433">>) -> {10, 10};
eirp_limits(<<"AU915-928">>) -> {20, 26};
eirp_limits(<<"CN470-510">>) -> {14, 17};
eirp_limits(<<"KR920-923">>) -> {14, 23}.

                                                % {Min, Max}
freq_range(<<"EU863-870">>) -> {863, 870};
freq_range(<<"US902-928">>) -> {902, 928};
freq_range(<<"US902-928-PR">>) -> {902, 928};
freq_range(<<"CN779-787">>) -> {779, 787};
freq_range(<<"EU433">>) -> {433, 435};
freq_range(<<"AU915-928">>) -> {915, 928};
freq_range(<<"CN470-510">>) -> {470, 510};
freq_range(<<"KR920-923">>) -> {920, 923}.

-include_lib("eunit/include/eunit.hrl").

region_test_()-> [
                  ?_assertEqual(dr_to_datar(<<"EU863-870">>, 0), <<"SF12BW125">>),
                  ?_assertEqual(dr_to_datar(<<"US902-928">>, 8), <<"SF12BW500">>),
                  ?_assertEqual(datar_to_dr(<<"EU863-870">>, <<"SF9BW125">>), 3),
                  ?_assertEqual(datar_to_dr(<<"US902-928">>, <<"SF7BW500">>), 13),
                  ?_assertEqual(<<"SF10BW500">>, datar_to_down(<<"US902-928">>, <<"SF10BW125">>, 0))].

                                                % end of file
