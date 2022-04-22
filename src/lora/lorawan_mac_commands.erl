%%%-------------------------------------------------------------------
%% @doc
%% Copyright (c) 2016-2019 Petr Gotthard &lt;petr.gotthard@@centrum.cz&gt;
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%% @end
%%%-------------------------------------------------------------------
-module(lorawan_mac_commands).

-export([
    handle_fopts/4,
    build_fopts/2,
    merge_rxwin/2,
    parse_fopts/1,
    parse_fdownopts/1,
    encode_fopts/1,
    encode_fupopts/1,
    set_channels/3
]).

-export([mk_join_accept_cf_list/1]).

-include("lorawan_db.hrl").

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

-spec set_channels(atom(), tuple(), list()) -> list().
set_channels(Region, Tuple, FOptsOut) ->
    TopLevelRegion = top_level_region(Region),
    set_channels_(TopLevelRegion, Tuple, FOptsOut).

%% link_adr_req command

set_channels_(Region, {0, <<"NoChange">>, Chans}, FOptsOut) when
    Region == 'US915'; Region == 'AU915'
->
    case all_bit({0, 63}, Chans) of
        true ->
            [
                {link_adr_req, 16#F, 16#F, build_chmask(Chans, {64, 71}), 6, 0}
                | FOptsOut
            ];
        false ->
            [
                {link_adr_req, 16#F, 16#F, build_chmask(Chans, {64, 71}), 7, 0}
                | append_mask(Region, 3, {0, <<"NoChange">>, Chans}, FOptsOut)
            ]
    end;
set_channels_(Region, {TXPower, DataRate, Chans}, FOptsOut) when
    Region == 'US915'; Region == 'AU915'
->
    case all_bit({0, 63}, Chans) of
        true ->
            [
                {link_adr_req, lorawan_mac_region:datar_to_dr(Region, DataRate), TXPower,
                    build_chmask(Chans, {64, 71}), 6, 0}
                | FOptsOut
            ];
        false ->
            [
                {link_adr_req, lorawan_mac_region:datar_to_dr(Region, DataRate), TXPower,
                    build_chmask(Chans, {64, 71}), 7, 0}
                | append_mask(Region, 3, {TXPower, DataRate, Chans}, FOptsOut)
            ]
    end;
set_channels_(Region, {TXPower, DataRate, Chans}, FOptsOut) when Region == 'CN470' ->
    case all_bit({0, 95}, Chans) of
        true ->
            [
                {link_adr_req, lorawan_mac_region:datar_to_dr(Region, DataRate), TXPower, 0, 6, 0}
                | FOptsOut
            ];
        false ->
            append_mask(Region, 5, {TXPower, DataRate, Chans}, FOptsOut)
    end;
set_channels_(Region, {TXPower, DataRate, Chans}, FOptsOut) ->
    [
        {link_adr_req, lorawan_mac_region:datar_to_dr(Region, DataRate), TXPower,
            build_chmask(Chans, {0, 15}), 0, 0}
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
append_mask(Region, Idx, {0, <<"NoChange">>, Chans}, FOptsOut) ->
    append_mask(
        Region,
        Idx - 1,
        {0, <<"NoChange">>, Chans},
        case build_chmask(Chans, {16 * Idx, 16 * (Idx + 1) - 1}) of
            0 ->
                FOptsOut;
            ChMask ->
                [{link_adr_req, 16#F, 16#F, ChMask, Idx, 0} | FOptsOut]
        end
    );
append_mask(Region, Idx, {TXPower, DataRate, Chans}, FOptsOut) ->
    append_mask(
        Region,
        Idx - 1,
        {TXPower, DataRate, Chans},
        case build_chmask(Chans, {16 * Idx, 16 * (Idx + 1) - 1}) of
            0 ->
                FOptsOut;
            ChMask ->
                [
                    {link_adr_req, lorawan_mac_region:datar_to_dr(Region, DataRate), TXPower,
                        ChMask, Idx, 0}
                    | FOptsOut
                ]
        end
    ).

handle_fopts({Network, Profile, Node}, Gateways, ADR, FOpts) ->
    FOptsIn = parse_fopts(FOpts),
    case FOptsIn of
        [] -> ok;
        List1 -> lager:debug("~s -> ~w", [lorawan_utils:binary_to_hex(Node#node.devaddr), List1])
    end,
    % process incoming responses
    {atomic, {MacConfirm, Node2}} =
        mnesia:transaction(
            fun() ->
                [N0] = mnesia:read(node, Node#node.devaddr, write),
                {MC, N2} = handle_fopts0(
                    {Network, Profile, store_actual_adr(Gateways, ADR, Network, N0)},
                    Gateways,
                    FOptsIn
                ),
                %   ok = lorawan_admin:write(N2),
                {MC, N2}
            end
        ),
    % process requests
    FOptsOut =
        lists:foldl(
            fun
                (link_check_req, Acc) -> [send_link_check(Gateways) | Acc];
                (device_time_req, Acc) -> [send_device_time(Gateways) | Acc];
                (_Else, Acc) -> Acc
            end,
            [],
            FOptsIn
        ),
    % check for new requests
    {ok, MacConfirm, Node2, build_fopts({Network, Profile, Node2}, FOptsOut)}.

handle_fopts0({Network, Profile, Node0}, Gateways, FOptsIn) ->
    {MacConfirm, Node1} = handle_rxwin(
        FOptsIn,
        Network,
        Profile,
        handle_adr(
            FOptsIn,
            handle_dcycle(
                FOptsIn,
                Profile,
                handle_status(FOptsIn, Network, Node0)
            )
        )
    ),
    {ok, FramesRequired} = application:get_env(lorawan_server, frames_before_adr),
    % maintain quality statistics
    {_, RxQ} = hd(Gateways),
    {LastQs, AverageQs} = append_qs(
        {RxQ#rxq.rssi, RxQ#rxq.lsnr},
        Node1#node.last_qs,
        FramesRequired
    ),
    Node2 = auto_adr(Network, Profile, Node1#node{last_qs = LastQs, average_qs = AverageQs}),
    {MacConfirm, Node2#node{last_rx = calendar:universal_time(), gateways = Gateways}}.

append_qs(SNR, LastQs, Required) when length(LastQs) < Required ->
    {[SNR | LastQs], undefined};
append_qs(SNR, LastQs, Required) ->
    LastQs2 = lists:sublist([SNR | LastQs], Required),
    AverageQs = average_qs(lists:unzip(LastQs2)),
    {LastQs2, AverageQs}.

average_qs({List1, List2}) ->
    {average_qs0(List1), average_qs0(List2)}.

average_qs0(List) ->
    Avg = lists:sum(List) / length(List),
    Sigma = math:sqrt(lists:sum([(N - Avg) * (N - Avg) || N <- List]) / length(List)),
    Avg - Sigma.

build_fopts({Network, Profile, Node}, FOptsOut0) ->
    FOptsOut = send_adr(
        Network,
        Node,
        set_dcycle(
            Profile,
            Node,
            set_rxwin(
                Profile,
                Node,
                request_status(Profile, Node, FOptsOut0)
            )
        )
    ),
    case FOptsOut of
        [] -> ok;
        List2 -> lager:debug("~s <- ~w", [lorawan_utils:binary_to_hex(Node#node.devaddr), List2])
    end,
    encode_fopts(FOptsOut).

parse_fopts(<<16#02, Rest/binary>>) ->
    [link_check_req | parse_fopts(Rest)];
parse_fopts(<<16#03, _RFU:5, PowerACK:1, DataRateACK:1, ChannelMaskACK:1, Rest/binary>>) ->
    [{link_adr_ans, PowerACK, DataRateACK, ChannelMaskACK} | parse_fopts(Rest)];
parse_fopts(<<16#04, Rest/binary>>) ->
    [duty_cycle_ans | parse_fopts(Rest)];
parse_fopts(<<16#05, _RFU:5, RX1DROffsetACK:1, RX2DataRateACK:1, ChannelACK:1, Rest/binary>>) ->
    [{rx_param_setup_ans, RX1DROffsetACK, RX2DataRateACK, ChannelACK} | parse_fopts(Rest)];
parse_fopts(<<16#06, Battery:8, _RFU:2, Margin:6/signed, Rest/binary>>) ->
    [{dev_status_ans, Battery, Margin} | parse_fopts(Rest)];
parse_fopts(<<16#07, _RFU:6, DataRateRangeOK:1, ChannelFreqOK:1, Rest/binary>>) ->
    [{new_channel_ans, DataRateRangeOK, ChannelFreqOK} | parse_fopts(Rest)];
parse_fopts(<<16#08, Rest/binary>>) ->
    [rx_timing_setup_ans | parse_fopts(Rest)];
parse_fopts(<<16#09, Rest/binary>>) ->
    [tx_param_setup_ans | parse_fopts(Rest)];
parse_fopts(<<16#0A, _RFU:6, UplinkFreqExists:1, ChannelFreqOK:1, Rest/binary>>) ->
    [{di_channel_ans, UplinkFreqExists, ChannelFreqOK} | parse_fopts(Rest)];
parse_fopts(<<16#0D, Rest/binary>>) ->
    [device_time_req | parse_fopts(Rest)];
parse_fopts(<<>>) ->
    [];
parse_fopts(Unknown) ->
    lager:warning("Unknown command ~p", [lorawan_utils:binary_to_hex(Unknown)]),
    [].

parse_fdownopts(
    <<16#03, DataRate:4, TXPower:4, ChMask:16/little-unsigned-integer, 0:1, ChMaskCntl:3, NbTrans:4,
        Rest/binary>>
) ->
    [{link_adr_req, DataRate, TXPower, ChMask, ChMaskCntl, NbTrans} | parse_fdownopts(Rest)];
parse_fdownopts(<<16#02, Margin, GwCnt, Rest/binary>>) ->
    [{link_check_ans, Margin, GwCnt} | parse_fdownopts(Rest)];
parse_fdownopts(<<16#04, _RFU:4, MaxDCycle:4, Rest/binary>>) ->
    [{duty_cycle_req, MaxDCycle} | parse_fdownopts(Rest)];
parse_fdownopts(
    <<16#05, _RFU:1, RX1DRoffset:3, RX2DataRate:4, Freq:24/little-unsigned-integer, Rest/binary>>
) ->
    [{rx_param_setup_req, RX1DRoffset, RX2DataRate, Freq} | parse_fdownopts(Rest)];
parse_fdownopts(<<16#06, Rest/binary>>) ->
    [dev_status_req | parse_fdownopts(Rest)];
parse_fdownopts(
    <<16#07, ChIndex:8, Freq:24/little-unsigned-integer, MaxDr:4, MinDr:4, Rest/binary>>
) ->
    [{new_channel_req, ChIndex, Freq, MaxDr, MinDr} | parse_fdownopts(Rest)];
parse_fdownopts(<<16#08, _RFU:4, Delay:4, Rest/binary>>) ->
    [{rx_timing_setup_req, Delay} | parse_fdownopts(Rest)];
parse_fdownopts(<<16#09, _RFU:2, DownlinkDwellTime:1, UplinkDwellTime:1, MaxEIRP:4, Rest/binary>>) ->
    [{tx_param_setup_req, DownlinkDwellTime, UplinkDwellTime, MaxEIRP} | parse_fdownopts(Rest)];
parse_fdownopts(
    <<16#0A, ChIndex:8, Freq:24/little-unsigned-integer, MaxDr:4, MinDr:4, Rest/binary>>
) ->
    [{dl_channel_req, ChIndex, Freq, MaxDr, MinDr} | parse_fdownopts(Rest)];
parse_fdownopts(<<16#0D, A:32/little-unsigned-integer, B:8/little-unsigned-integer, Rest/binary>>) ->
    [{device_time_ans, A, B} | parse_fdownopts(Rest)];
parse_fdownopts(<<>>) ->
    [];
parse_fdownopts(Unknown) ->
    lager:warning("Unknown downlink command ~p", [lorawan_utils:binary_to_hex(Unknown)]),
    [].

encode_fopts([{link_check_ans, Margin, GwCnt} | Rest]) ->
    <<16#02, Margin, GwCnt, (encode_fopts(Rest))/binary>>;
encode_fopts([{link_adr_req, DataRate, TXPower, ChMask, ChMaskCntl, NbRep} | Rest]) ->
    <<16#03, DataRate:4, TXPower:4, ChMask:16/little-unsigned-integer, 0:1, ChMaskCntl:3, NbRep:4,
        (encode_fopts(Rest))/binary>>;
encode_fopts([{duty_cycle_req, MaxDCycle} | Rest]) ->
    <<16#04, 0:4, MaxDCycle:4, (encode_fopts(Rest))/binary>>;
encode_fopts([{rx_param_setup_req, RX1DROffset, RX2DataRate, Frequency} | Rest]) ->
    <<16#05, 0:1, RX1DROffset:3, RX2DataRate:4, Frequency:24/little-unsigned-integer,
        (encode_fopts(Rest))/binary>>;
encode_fopts([dev_status_req | Rest]) ->
    <<16#06, (encode_fopts(Rest))/binary>>;
encode_fopts([{new_channel_req, ChIndex, Freq, MaxDR, MinDR} | Rest]) ->
    <<16#07, ChIndex, Freq:24/little-unsigned-integer, MaxDR:4, MinDR:4,
        (encode_fopts(Rest))/binary>>;
encode_fopts([{rx_timing_setup_req, Delay} | Rest]) ->
    <<16#08, 0:4, Delay:4, (encode_fopts(Rest))/binary>>;
encode_fopts([{tx_param_setup_req, DownDwell, UplinkDwell, MaxEIRP} | Rest]) ->
    <<16#09, 0:2, DownDwell:1, UplinkDwell:1, MaxEIRP:4, (encode_fopts(Rest))/binary>>;
encode_fopts([{di_channel_req, ChIndex, Freq} | Rest]) ->
    <<16#0A, ChIndex, Freq:24/little-unsigned-integer, (encode_fopts(Rest))/binary>>;
encode_fopts([{device_time_ans, MsSinceEpoch} | Rest]) ->
    % 0.5^8
    Ms = trunc((MsSinceEpoch rem 1000) / 3.90625),
    <<16#0D, (MsSinceEpoch div 1000):32/little-unsigned-integer, Ms, (encode_fopts(Rest))/binary>>;
encode_fopts([]) ->
    <<>>.

encode_fupopts([link_check_req | Rest]) ->
    <<16#02, (encode_fupopts(Rest))/binary>>;
encode_fupopts([{link_adr_ans, PowerACK, DataRateACK, ChannelMaskACK} | Rest]) ->
    <<16#03, 0:5, PowerACK:1, DataRateACK:1, ChannelMaskACK:1, (encode_fupopts(Rest))/binary>>;
encode_fupopts([duty_cycle_ans | Rest]) ->
    <<16#04, (encode_fupopts(Rest))/binary>>;
encode_fupopts([{rx_param_setup_ans, RX1DROffsetACK, RX2DataRateACK, ChannelACK} | Rest]) ->
    <<16#05, 0:5, RX1DROffsetACK:1, RX2DataRateACK:1, ChannelACK:1, (encode_fupopts(Rest))/binary>>;
encode_fupopts([{dev_status_ans, Battery, Margin} | Rest]) ->
    <<16#06, Battery:8, 0:2, Margin:6, (encode_fupopts(Rest))/binary>>;
encode_fupopts([{new_channel_ans, DataRateRangeOK, ChannelFreqOK} | Rest]) ->
    <<16#07, 0:6, DataRateRangeOK:1, ChannelFreqOK:1, (encode_fupopts(Rest))/binary>>;
encode_fupopts([rx_timing_setup_ans | Rest]) ->
    <<16#08, (encode_fupopts(Rest))/binary>>;
encode_fupopts([tx_param_setup_ans | Rest]) ->
    <<16#09, (encode_fupopts(Rest))/binary>>;
encode_fupopts([{di_channel_ans, UplinkFreqExists, ChannelFreqOK} | Rest]) ->
    <<16#0A, 0:6, UplinkFreqExists:1, ChannelFreqOK:1, (encode_fupopts(Rest))/binary>>;
encode_fupopts([device_time_req | Rest]) ->
    <<16#0D, (encode_fupopts(Rest))/binary>>;
encode_fupopts([_ | Rest]) ->
    <<(encode_fupopts(Rest))/binary>>;
encode_fupopts([]) ->
    <<>>.

store_actual_adr(
    [{_MAC, RxQ} | _],
    ADR,
    #network{region = Region, init_chans = InitChans, max_power = MaxPower},
    Node
) ->
    % store parameters
    Plan = lora_plan:region_to_plan(Region),
    DataRateAtom = lora_plan:datarate_to_atom(RxQ#rxq.datr),
    DataRate = lora_plan:datarate_to_index(Plan, DataRateAtom),
    case Node#node.adr_use of
        {TXPower, DataRate, Chans} when
            is_number(TXPower), is_list(Chans), Node#node.adr_flag == ADR
        ->
            % device didn't change any settings
            Node;
        {TXPower, DataRate, Chans} when is_number(TXPower), is_list(Chans) ->
            lager:debug("ADR indicator set to ~w", [ADR]),
            Node#node{adr_flag = ADR, devstat_fcnt = undefined, last_qs = []};
        {TXPower, _OldDataRate, Chans} when is_number(TXPower), is_list(Chans) ->
            lager:debug("DataRate ~s switched to dr ~w", [
                lorawan_utils:binary_to_hex(Node#node.devaddr),
                DataRate
            ]),
            Node#node{
                adr_flag = ADR,
                adr_use = {TXPower, DataRate, Chans},
                devstat_fcnt = undefined,
                last_qs = []
            };
        _Else ->
            % this should not happen
            lager:warning("DataRate ~s initialized to dr ~w", [
                lorawan_utils:binary_to_hex(Node#node.devaddr),
                DataRate
            ]),
            Node#node{
                adr_flag = ADR,
                adr_use = {MaxPower, DataRate, InitChans},
                devstat_fcnt = undefined,
                last_qs = []
            }
    end.

handle_adr(FOptsIn, Node) ->
    case find_adr(FOptsIn) of
        {1, 1, 1} ->
            case merge_adr(Node#node.adr_set, Node#node.adr_use) of
                Unchanged when Unchanged == Node#node.adr_use ->
                    lager:debug(
                        "LinkADRReq ~s succeeded (enforcement only)",
                        [lorawan_utils:binary_to_hex(Node#node.devaddr)]
                    ),
                    % the desired ADR is already used
                    Node#node{adr_set = undefined, adr_failed = []};
                NodeSet ->
                    lager:debug(
                        "LinkADRReq ~s succeeded",
                        [lorawan_utils:binary_to_hex(Node#node.devaddr)]
                    ),
                    Node#node{
                        adr_set = undefined,
                        adr_use = NodeSet,
                        adr_failed = [],
                        devstat_fcnt = undefined,
                        last_qs = []
                    }
            end;
        {PowerACK, DataRateACK, ChannelMaskACK} ->
            lorawan_utils:throw_warning(
                {node, Node#node.devaddr},
                {adr_req_failed, {PowerACK, DataRateACK, ChannelMaskACK}}
            ),
            % indicate the settings that failed
            Node#node{
                adr_failed = add_when_zero(
                    <<"power">>,
                    PowerACK,
                    add_when_zero(
                        <<"data_rate">>,
                        DataRateACK,
                        add_when_zero(<<"channel_mask">>, ChannelMaskACK, [])
                    )
                )
            };
        undefined ->
            Node
    end.

find_adr(FOptsIn) ->
    lists:foldr(
        fun
            ({link_adr_ans, Power, DataRate, ChannelMask}, undefined) ->
                {Power, DataRate, ChannelMask};
            (
                {link_adr_ans, _Power, _DataRate, ChannelMask},
                {LastPower, LastDataRate, LastChannelMask}
            ) ->
                % all ChannelMasks must be accepted
                % the device processes the DataRate, TXPower and NbTrans from the last message only
                {LastPower, LastDataRate, ChannelMask band LastChannelMask};
            (_Else, Last) ->
                Last
        end,
        undefined,
        FOptsIn
    ).

handle_dcycle(FOptsIn, Profile, Node) ->
    case lists:member(duty_cycle_ans, FOptsIn) of
        true ->
            lager:debug("DutyCycleAns ~s", [lorawan_utils:binary_to_hex(Node#node.devaddr)]),
            Node#node{dcycle_use = Profile#profile.dcycle_set};
        false ->
            Node
    end.

handle_rxwin(FOptsIn, _Network, Profile, Node) ->
    case find_rxwin(FOptsIn) of
        {1, 1, 1} ->
            case merge_rxwin(Profile#profile.rxwin_set, Node#node.rxwin_use) of
                Unchanged when Unchanged == Node#node.rxwin_use ->
                    lager:debug("RXParamSetupAns ~s succeeded (enforcement only)", [
                        lorawan_utils:binary_to_hex(Node#node.devaddr)
                    ]),
                    {true, Node#node{rxwin_failed = []}};
                NodeSet ->
                    lager:debug("RXParamSetupAns ~s succeeded", [
                        lorawan_utils:binary_to_hex(Node#node.devaddr)
                    ]),
                    {true, Node#node{rxwin_use = NodeSet, rxwin_failed = []}}
            end;
        {RX1DROffsetACK, RX2DataRateACK, ChannelACK} ->
            lorawan_utils:throw_warning(
                {node, Node#node.devaddr},
                {rxwin_setup_failed, {RX1DROffsetACK, RX2DataRateACK, ChannelACK}}
            ),
            % indicate the settings that failed
            {true, Node#node{
                rxwin_failed = add_when_zero(
                    <<"dr_offset">>,
                    RX1DROffsetACK,
                    add_when_zero(
                        <<"rx2_data_rate">>,
                        RX2DataRateACK,
                        add_when_zero(<<"channel">>, ChannelACK, [])
                    )
                )
            }};
        undefined ->
            {false, Node}
    end.

find_rxwin(FOptsIn) ->
    lists:foldl(
        fun
            ({rx_param_setup_ans, RX1DROffsetACK, RX2DataRateACK, ChannelACK}, _Prev) ->
                {RX1DROffsetACK, RX2DataRateACK, ChannelACK};
            (_Else, Last) ->
                Last
        end,
        undefined,
        FOptsIn
    ).

handle_status(FOptsIn, #network{region = Region}, Node) ->
    case find_status(FOptsIn) of
        {Battery, Margin} ->
            % compute a maximal D/L SNR
            {_, DataRate, _} = Node#node.adr_use,
            {OffUse, _, _} = Node#node.rxwin_use,
            MaxSNR = lorawan_mac_region:max_downlink_snr(Region, DataRate, OffUse),
            lager:debug("DevStatus: battery ~B, margin: ~B (max ~.1f)", [Battery, Margin, MaxSNR]),
            Node#node{
                devstat_time = calendar:universal_time(),
                devstat_fcnt = Node#node.fcntup,
                devstat = append_status(
                    {calendar:universal_time(), Battery, Margin, MaxSNR},
                    Node#node.devstat
                )
            };
        undefined ->
            Node
    end.

append_status(Status, List) ->
    lists:sublist([Status | List], 50).

find_status(FOptsIn) ->
    lists:foldl(
        fun
            ({dev_status_ans, Battery, Margin}, _Prev) -> {Battery, Margin};
            (_Else, Last) -> Last
        end,
        undefined,
        FOptsIn
    ).

send_link_check([{_MAC, RxQ} | _] = Gateways) ->
    #rxq{datr = DataRate, lsnr = SNR} = RxQ,
    Margin = trunc(SNR - lora_plan:max_uplink_snr(lora_plan:datarate_to_atom(DataRate))),
    lager:debug("LinkCheckAns: margin: ~B, gateways: ~B", [Margin, length(Gateways)]),
    {link_check_ans, Margin, length(Gateways)}.

%% Not possible for times to be undefined per definition
% send_device_time([{_MAC, #rxq{time = undefined}} | _]) ->
%     MsSinceEpoch = lorawan_utils:time_to_gps(),
%     lager:debug("DeviceTimeAns: time: ~B (from local)", [MsSinceEpoch]),
%     % no time provided by the gateway, we do our best
%     {device_time_ans, MsSinceEpoch};
% send_device_time([{_MAC, #rxq{time = Time, tmms = undefined}} | _]) ->
%     MsSinceEpoch = lorawan_utils:time_to_gps(Time),
%     lager:debug("DeviceTimeAns: time: ~B (from gateway)", [MsSinceEpoch]),
%     % we got GPS time, but not milliseconds
%     {device_time_ans, MsSinceEpoch};
send_device_time([{_MAC, #rxq{tmms = MsSinceEpoch}} | _]) ->
    lager:debug("DeviceTimeAns: time: ~B", [MsSinceEpoch]),
    % this is the easiest
    {device_time_ans, MsSinceEpoch}.

auto_adr(
    Network,
    #profile{adr_mode = 1} = Profile,
    #node{adr_flag = 1, adr_failed = Failed} = Node
) when Failed == undefined; Failed == [] ->
    case merge_adr(Node#node.adr_set, Node#node.adr_use) of
        Unchanged when Unchanged == Node#node.adr_use, is_tuple(Node#node.average_qs) ->
            % have enough data and no other change was requested
            calculate_adr(Network, Profile, Node);
        _Else ->
            Node
    end;
auto_adr(
    _Network,
    #profile{adr_mode = 2} = Profile,
    #node{adr_flag = 1, adr_failed = Failed} = Node
) when Failed == undefined; Failed == [] ->
    case merge_adr(Profile#profile.adr_set, Node#node.adr_use) of
        Unchanged when Unchanged == Node#node.adr_use ->
            % no change to profile settings
            Node;
        _Else ->
            % use the profile-defined value
            Node#node{adr_set = Profile#profile.adr_set}
    end;
auto_adr(_Network, _Profile, Node) ->
    % ADR is Disabled (or undefined)
    Node.

calculate_adr(
    #network{
        region = _Region,
        max_datr = NwkMaxDR1,
        max_power = MaxPower,
        min_power = MinPower,
        cflist = CFList
    },
    #profile{max_datr = MaxDRLimit},
    #node{average_qs = {AvgRSSI, AvgSNR}, adr_use = {TxPower, DataRate, Chans}} = Node
) ->
    % maximum DR supported by some channel
    NwkMaxDR2 =
        lists:foldl(
            fun
                ({_, _, Max}, Acc) when is_integer(Max) -> max(Max, Acc);
                (_, Acc) -> Acc
            end,
            NwkMaxDR1,
            if
                is_list(CFList) -> CFList;
                true -> []
            end
        ),
    % apply device limit for maximum DR
    MaxDR =
        if
            MaxDRLimit == undefined -> NwkMaxDR2;
            true -> min(NwkMaxDR2, MaxDRLimit)
        end,
    % how many SF steps (per Table 13) are between current SNR and current sensitivity?
    % there is 2.5 dB between the DR, so divide by 3 to get more margin
    DataRateAtom = lora_plan:datarate_to_atom(DataRate),
    MaxSNR = lora_plan:max_uplink_snr(DataRateAtom) + 10,
    StepsDR = trunc((AvgSNR - MaxSNR) / 3),
    DataRate2 =
        if
            StepsDR > 0, DataRate < MaxDR ->
                lager:debug(
                    "DataRate ~s: average snr ~w ~w = ~w, dr ~w -> step ~w",
                    [
                        lorawan_utils:binary_to_hex(Node#node.devaddr),
                        round(AvgSNR),
                        MaxSNR,
                        round(AvgSNR - MaxSNR),
                        DataRate,
                        StepsDR
                    ]
                ),
                min(DataRate + StepsDR, MaxDR);
            true ->
                DataRate
        end,
    % receiver sensitivity for maximal DR in all regions is -120 dBm, we try to stay at -100 dBm
    TxPower2 =
        if
            AvgRSSI > -96, TxPower < MinPower ->
                % there are 2 dB between levels, go slower
                PwrStepUp = trunc((AvgRSSI + 100) / 4),
                lager:debug(
                    "Power ~s: average rssi ~w, power ~w -> up by ~w",
                    [
                        lorawan_utils:binary_to_hex(Node#node.devaddr),
                        round(AvgRSSI),
                        TxPower,
                        PwrStepUp
                    ]
                ),
                min(MinPower, TxPower + PwrStepUp);
            AvgRSSI < -102, TxPower > MaxPower ->
                % go faster
                PwrStepDown = trunc((AvgRSSI + 98) / 2),
                lager:debug(
                    "Power ~s: average rssi ~w, power ~w -> down by ~w",
                    [
                        lorawan_utils:binary_to_hex(Node#node.devaddr),
                        round(AvgRSSI),
                        TxPower,
                        PwrStepDown
                    ]
                ),
                % steps are negative
                max(MaxPower, TxPower + PwrStepDown);
            true ->
                TxPower
        end,
    % verify if something has changed
    case {TxPower2, DataRate2, Chans} of
        {TxPower, DataRate, Chans} ->
            Node;
        Set ->
            % request ADR command
            Node#node{adr_set = Set}
    end.

send_adr(
    #network{region = Region},
    #node{adr_flag = 1, adr_set = {TxPower, DataRate, Chans}, adr_failed = Failed} = Node,
    FOptsOut
) when
    (is_integer(TxPower) or is_integer(DataRate) or is_list(Chans)),
    (Failed == undefined orelse Failed == [])
->
    Set = merge_adr(Node#node.adr_set, Node#node.adr_use),
    lager:debug("LinkADRReq ~w", [Set]),
    set_channels(Region, Set, FOptsOut);
send_adr(_Network, _Node, FOptsOut) ->
    % the device has disabled ADR
    FOptsOut.

merge_adr({A1, B1, C1}, {A2, B2, C2}) ->
    {
        if
            is_integer(A1) -> A1;
            true -> A2
        end,
        if
            is_integer(B1) -> B1;
            true -> B2
        end,
        if
            is_list(C1), length(C1) > 0 -> C1;
            true -> C2
        end
    };
merge_adr(_Else, ABC) ->
    ABC.

set_dcycle(#profile{dcycle_set = Used}, #node{dcycle_use = Used}, FOptsOut) ->
    % no change requested
    FOptsOut;
set_dcycle(#profile{dcycle_set = 0}, #node{dcycle_use = undefined}, FOptsOut) ->
    FOptsOut;
set_dcycle(#profile{dcycle_set = undefined}, _Node, FOptsOut) ->
    FOptsOut;
set_dcycle(#profile{dcycle_set = Set}, _Node, FOptsOut) ->
    lager:debug("DutyCycleReq ~w", [Set]),
    [{duty_cycle_req, Set} | FOptsOut].

set_rxwin(Profile, #node{adr_flag = 1, rxwin_failed = Failed} = Node, FOptsOut) when
    Failed == undefined; Failed == []
->
    case merge_rxwin(Profile#profile.rxwin_set, Node#node.rxwin_use) of
        Unchanged when Unchanged == Node#node.rxwin_use ->
            FOptsOut;
        {OffSet, RX2DataRate, Frequency} ->
            lager:debug("RXParamSetupReq ~w ~w ~w", [OffSet, RX2DataRate, Frequency]),
            [{rx_param_setup_req, OffSet, RX2DataRate, trunc(10000 * Frequency)} | FOptsOut]
    end;
set_rxwin(_Profile, _Node, FOptsOut) ->
    FOptsOut.

merge_rxwin({A1, B1, C1}, {A2, B2, C2}) ->
    {
        if
            is_integer(A1) -> A1;
            true -> A2
        end,
        if
            is_integer(B1) -> B1;
            true -> B2
        end,
        if
            is_number(C1) -> C1;
            true -> C2
        end
    };
merge_rxwin(_Else, ABC) ->
    ABC.

request_status(#profile{request_devstat = false}, _Node, FOptsOut) ->
    FOptsOut;
request_status(_Profile, #node{devstat_time = LastDate, devstat_fcnt = LastFCnt}, FOptsOut) when
    LastDate == undefined; LastFCnt == undefined
->
    [dev_status_req | FOptsOut];
request_status(
    _Profile,
    #node{devstat = Stats, devstat_time = LastDate, devstat_fcnt = LastFCnt} = Node,
    FOptsOut
) ->
    {ok, {MaxTime, MaxFCnt}} = application:get_env(lorawan_server, devstat_gap),
    TimeDiff =
        calendar:datetime_to_gregorian_seconds(calendar:universal_time()) -
            calendar:datetime_to_gregorian_seconds(LastDate),
    Divider =
        case Stats of
            [{_Time, Battery, _Margin, _MaxSNR} | _] when Battery < 100 ->
                2;
            _Else ->
                1
        end,
    if
        TimeDiff > MaxTime / Divider; Node#node.fcntup - LastFCnt > MaxFCnt / Divider ->
            [dev_status_req | FOptsOut];
        true ->
            FOptsOut
    end.

add_when_zero(Error, 0, List) -> [Error | List];
add_when_zero(_Error, 1, List) -> List.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

expand_intervals([{A, B} | Rest]) ->
    lists:seq(A, B) ++ expand_intervals(Rest);
expand_intervals([]) ->
    [].

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

-endif.
%% end of file
