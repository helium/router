-module(router_decoder_custom_sup_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    v8_recovery_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        v8_recovery_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

v8_recovery_test(Config) ->
    %% Set console to decoder channel mode
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {channel_type, decoder}),

    test_utils:join_device(Config),

    %% Waiting for reply from router to hotspot
    test_utils:wait_state_channel_message(1250),

    ValidFunction = <<"function Decoder(a,b,c) { return 42; }">>,
    ValidDecoder = router_decoder:new(
        <<"valid">>,
        custom,
        #{function => ValidFunction}
    ),
    Result = 42,
    BogusFunction = <<"function Decoder(a,b,c) { crash @ here! }">>,
    BogusDecoder = router_decoder:new(
        <<"bogus">>,
        custom,
        #{function => BogusFunction}
    ),
    Payload = erlang:binary_to_list(base64:decode(<<"H4Av/xACRU4=">>)),
    Port = 6,
    Uplink = #{},

    %% One context sends a valid function definiton and another sends
    %% bogus javascript, causing the V8 VM to be restarted.  The first
    %% context should then recover.
    {ok, Pid1} = router_decoder_custom_sup:add(ValidDecoder),
    ?assertMatch(
        {ok, Result},
        router_decoder_custom_worker:decode(Pid1, Payload, Port, Uplink)
    ),
    ?assertMatch(
        {ok, Result},
        router_decoder_custom_worker:decode(Pid1, Payload, Port, Uplink)
    ),
    ?assertMatch(
        {ok, Result},
        router_decoder_custom_worker:decode(Pid1, Payload, Port, Uplink)
    ),
    ?assert(erlang:is_process_alive(Pid1)),

    %% Even though JS was bad, we still get a Pid for less BEAM runtime overhead overall
    {ok, Pid2} = router_decoder_custom_sup:add(BogusDecoder),
    ?assertNotMatch(Pid1, Pid2),
    ?assertMatch(
        {error, ignoring_invalid_javascript},
        router_decoder_custom_worker:decode(Pid2, Payload, Port, Uplink)
    ),
    ?assertMatch(
        {error, ignoring_invalid_javascript},
        router_decoder_custom_worker:decode(Pid2, Payload, Port, Uplink)
    ),
    ?assertMatch(
        {error, ignoring_invalid_javascript},
        router_decoder_custom_worker:decode(Pid2, Payload, Port, Uplink)
    ),

    ?assert(erlang:is_process_alive(Pid1)),
    ?assertMatch(
        {ok, Result},
        router_decoder_custom_worker:decode(Pid1, Payload, Port, Uplink)
    ),
    ok.
