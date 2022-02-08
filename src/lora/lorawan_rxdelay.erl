%%%-------------------------------------------------------------------
%% @doc
%% == Router LoRaWAN RxDelay ==
%% See LoRaWAN Link Layer spec v1.0.4
%% sections:
%% - 3.3 Receive Windows
%% - 4.2.1 Frame types (FType bit field), for Join Accept
%% - 5.7 Setting Delay between TX and RX (RXTimingSetupReq, RXTimingSetupAns)
%% - 6.2.6 Join-Accept frame, which includes RXDelay
%% @end
%%%-------------------------------------------------------------------
-module(lorawan_rxdelay).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    get/1,
    get/2,
    bootstrap/1,
    maybe_update/2,
    adjust_on_join/1,
    adjust/3
]).

-define(RX_DELAY_ESTABLISHED, rx_delay_established).
-define(RX_DELAY_CHANGE, rx_delay_change).
-define(RX_DELAY_REQUESTED, rx_delay_requested).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec get(Metadata :: map()) -> RxDelay :: non_neg_integer().
get(Metadata) ->
    ?MODULE:get(Metadata, 0).

-spec get(Metadata :: map(), Default :: term()) -> RxDelay :: non_neg_integer() | term().
get(Metadata, Default) ->
    maps:get(rx_delay_actual, Metadata, Default).

-spec bootstrap(Metadata0 :: map()) -> Metadata :: map().
bootstrap(Metadata) ->
    %% The key `rx_delay' comes from Console/API for changing to that
    %% value.  `rx_delay_actual' represents the value set in LoRaWAN
    %% header during device Join and must go through request/answer
    %% negotiation to be changed.
    case maps:get(rx_delay, Metadata, 0) of
        0 ->
            %% Console always sends rx_delay via API, so default arm rarely gets used.
            Metadata#{rx_delay_state => ?RX_DELAY_ESTABLISHED};
        Del when Del =< 15 ->
            Metadata#{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay_actual => Del}
    end.

-spec maybe_update(
    APIDevice :: router_device:device(),
    Device :: router_device:device()
) -> Metadata :: map().
maybe_update(APIDevice, Device) ->
    %% Run after the value for `rx_delay` gets changed via Console.
    %% Accommodate net-nil changes via Console as no-op; e.g., A -> B -> A.
    Metadata = router_device:metadata(Device),
    Actual = maps:get(rx_delay_actual, Metadata, 0),
    Requested = maps:get(rx_delay, router_device:metadata(APIDevice), Actual),
    case Requested == Actual of
        true ->
            maps:put(rx_delay_state, ?RX_DELAY_ESTABLISHED, Metadata);
        false when Requested =< 15 ->
            %% Track requested value for new `rx_delay` without actually changing to it.
            maps:put(rx_delay_state, ?RX_DELAY_CHANGE, Metadata)
    end.

-spec adjust_on_join(Device :: router_device:device()) -> Metadata :: map().
adjust_on_join(Device) ->
    %% LoRaWAN Join-Accept implies `rx_timing_setup_ans` because
    %% `RXDelay` was in the Join-Accept.  A subsequent uplink implies
    %% that the device acknowledged the Join-Accept and thus, RXDelay.
    {_, Metadata, _} = adjust(Device, [rx_timing_setup_ans], []),
    Metadata.

-spec adjust(Device :: router_device:device(), UplinkFOpts :: list(), FOpts0 :: list()) ->
    {RxDelay :: non_neg_integer(), Metadata1 :: map(), FOpts1 :: list()}.
adjust(Device, UplinkFOpts, FOpts0) ->
    Metadata0 = router_device:metadata(Device),
    %% When state is undefined, it's probably a test that omits device_update()
    %% or didn't wait long enough for the async/cast to complete.
    State = maps:get(rx_delay_state, Metadata0, unknown_state),
    Actual = maps:get(rx_delay_actual, Metadata0, 0),
    Answered = lists:member(rx_timing_setup_ans, UplinkFOpts),
    %% Handle sequential changes to rx_delay; e.g, a previous change
    %% was ack'd, and now there's potentially another new RxDelay value.
    {RxDelay, Metadata1, FOpts1} =
        case {State, Answered} of
            %% Entering `RX_DELAY_CHANGE' state occurs in maybe_update().
            {?RX_DELAY_ESTABLISHED, _} ->
                {Actual, Metadata0, FOpts0};
            {?RX_DELAY_CHANGE, _} ->
                %% Console changed `rx_delay' value.
                Requested = maps:get(rx_delay, Metadata0),
                FOpts = [{rx_timing_setup_req, Requested} | FOpts0],
                Metadata = maps:put(rx_delay_state, ?RX_DELAY_REQUESTED, Metadata0),
                {Actual, Metadata, FOpts};
            {?RX_DELAY_REQUESTED, false} ->
                %% Router sent downlink request, Device has yet to ACK.
                Requested = maps:get(rx_delay, Metadata0),
                FOpts = [{rx_timing_setup_req, Requested} | FOpts0],
                {Actual, Metadata0, FOpts};
            {?RX_DELAY_REQUESTED, true} ->
                %% Device responded with ACK, so Router can apply the requested rx_delay.
                Requested = maps:get(rx_delay, Metadata0),
                Map = #{rx_delay_actual => Requested, rx_delay_state => ?RX_DELAY_ESTABLISHED},
                {Requested, maps:merge(Metadata0, Map), FOpts0};
            {unknown_state, _} ->
                lager:error("rx_delay state=unknown device-id=~p", [router_device:id(Device)]),
                {Actual, Metadata0, FOpts0}
        end,
    {RxDelay, Metadata1, FOpts1}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

rx_delay_state_test() ->
    ?assertEqual(default, get(#{foo => bar}, default)),
    ?assertEqual(default, get(#{rx_delay => 15}, default)),
    ?assertEqual(15, get(#{rx_delay_actual => 15}, default)),

    %% Ensure only LoRaWAN-approved values used
    Device = router_device:new(<<"foo">>),
    ApiSettingsDelTooBig = maps:merge(router_device:metadata(Device), #{rx_delay => 99}),
    ?assertError({case_clause, 99}, bootstrap(ApiSettingsDelTooBig)),

    %% Bootstrapping state
    ?assertEqual(
        #{rx_delay_state => ?RX_DELAY_ESTABLISHED},
        bootstrap(router_device:metadata(Device))
    ),
    ApiSettings = router_device:metadata(#{rx_delay => 5}, Device),
    ?assertEqual(
        #{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay_actual => 5, rx_delay => 5},
        bootstrap(router_device:metadata(ApiSettings))
    ),

    %% No net change yet, as LoRaWAN's RxDelay default is 0
    ApiSettings0 = router_device:metadata(#{rx_delay => 0}, Device),
    ?assertEqual(
        #{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay => 0},
        bootstrap(router_device:metadata(ApiSettings0))
    ),
    Device0 = router_device:metadata(
        #{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay => 0},
        Device
    ),
    ?assertEqual(
        #{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay => 0},
        adjust_on_join(Device0)
    ),
    ?assertEqual(
        #{rx_delay_state => ?RX_DELAY_ESTABLISHED},
        maybe_update(ApiSettings0, Device)
    ),

    %% No net change when using non-default value for RxDelay.
    Device1 = router_device:metadata(
        #{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay_actual => 1},
        Device
    ),
    ApiSettings1 = router_device:metadata(#{rx_delay => 1}, Device),
    ?assertEqual(
        #{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay_actual => 1},
        maybe_update(ApiSettings1, Device1)
    ),

    %% Exercise default case to recover state
    ?assertEqual({0, #{}, []}, adjust(Device, [], [])),
    ?assertEqual(
        {1, #{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay_actual => 1}, []},
        adjust(Device1, [], [])
    ),
    %% No net change from a redundant ACK from device:
    ?assertEqual(
        {1, #{rx_delay_state => ?RX_DELAY_ESTABLISHED, rx_delay_actual => 1}, []},
        adjust(Device1, [rx_timing_setup_ans], [])
    ),

    %% Change delay value

    ApiSettings2 = router_device:metadata(#{rx_delay => 2}, Device1),
    ?assertEqual(
        #{rx_delay_state => ?RX_DELAY_CHANGE, rx_delay_actual => 1},
        maybe_update(ApiSettings2, Device1)
    ),

    Device2 = router_device:metadata(
        #{
            rx_delay_state => ?RX_DELAY_CHANGE,
            rx_delay_actual => 2,
            rx_delay => 3
        },
        Device
    ),
    Metadata2 = #{
        rx_delay_state => ?RX_DELAY_REQUESTED,
        rx_delay_actual => 2,
        rx_delay => 3
    },
    ?assertEqual(
        {2, Metadata2, [{rx_timing_setup_req, 3}]},
        adjust(Device2, [], [])
    ),
    Device3 = router_device:metadata(Metadata2, Device),
    Metadata3 = #{
        rx_delay_state => ?RX_DELAY_ESTABLISHED,
        rx_delay_actual => 3,
        rx_delay => 3
    },
    ?assertEqual(
        {3, Metadata3, []},
        adjust(Device3, [rx_timing_setup_ans], [])
    ),
    ok.

-endif.
