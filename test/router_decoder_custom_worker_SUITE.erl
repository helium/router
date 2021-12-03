-module(router_decoder_custom_worker_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    avoid_call_to_bad_js_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [avoid_call_to_bad_js_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

avoid_call_to_bad_js_test(_Config) ->
    InvalidDecoder = <<"function Decoder(a,b,c) { crash + burn; }">>,
    {ok, VM} = router_v8:start_link(#{}),
    V8VM =
        case erlang_v8:start_vm() of
            {ok, V8Pid} -> V8Pid;
            {error, {already_started, V8Pid}} -> V8Pid
        end,
    Args = #{
        id => <<"decoder_id">>,
        hash => <<"cafef00d">>,
        function => InvalidDecoder,
        vm => V8VM
    },
    {ok, Pid} = router_decoder_custom_worker:start_link(Args),

    Payload = <<"doesn't matter for this test case">>,
    Port = 6,
    Uplink = #{},
    %% First time through decode() visits init_context()
    Decoded = router_decoder_custom_worker:decode(Pid, Payload, Port, Uplink),
    ?assertMatch({js_error, <<"ReferenceError:", _/binary>>}, Decoded),

    %% While were here, confirm abbreviated message (which gets used in log entry)
    {js_error, <<"ReferenceError:", OmitFullStackTrace/binary>>} = Decoded,
    ?assertMatch(nomatch, binary:match(OmitFullStackTrace, <<"\n">>)),

    %% Subsequent trips through decode/4 should avoid calling V8
    ?assertMatch(
        {error, ignoring_invalid_javascript},
        router_decoder_custom_worker:decode(Pid, Payload, Port, Uplink)
    ),
    ?assertMatch(
        {error, ignoring_invalid_javascript},
        router_decoder_custom_worker:decode(Pid, Payload, Port, Uplink)
    ),
    ?assertMatch(
        {error, ignoring_invalid_javascript},
        router_decoder_custom_worker:decode(Pid, Payload, Port, Uplink)
    ),

    MalformedJS1 = <<"funct Decoder(a,b,c) { return 42; }">>,
    Args1 = #{
        id => <<"decoder_id1">>,
        hash => <<"badca112">>,
        function => MalformedJS1,
        vm => V8VM
    },
    %% Worker gets created regardless of an error, because it will be
    %% less overhead overall (compared to rejecting and having next
    %% packet start fresh).
    {ok, Pid1} = router_decoder_custom_worker:start_link(Args1),
    %% Now, first call to decode gets ignored
    ?assertMatch(
        {error, ignoring_invalid_javascript},
        router_decoder_custom_worker:decode(Pid1, Payload, Port, Uplink)
    ),

    %% Cleanup:
    %% skipping: gen_server:stop(Pid),
    %% skipping: gen_server:stop(Pid1),
    gen_server:stop(VM),
    gen_server:stop(V8VM),
    ok.
