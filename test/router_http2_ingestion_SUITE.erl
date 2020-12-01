-module(router_http2_ingestion_SUITE).

-define(CLIENT_REF_NAME, <<"x-client-id">>).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    join_http2_test/1,
    join_http2_negative_test/1,
    join_http2_timeout_test/1
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("chatterbox/include/http2.hrl").

-include("utils/console_test.hrl").

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
        join_http2_test,
        join_http2_negative_test,
        join_http2_timeout_test
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

join_http2_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [_Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm0, _} = test_utils:start_swarm(BaseDir, swarm0, 0),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),

    %% create a join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Packet = test_utils:join_packet(PubKeyBin0, AppKey, JoinNonce, -40),

    {ok, ConnPid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(ConnPid),

    StreamRef = gun:post(ConnPid, "/v1/router/message", [], Packet),
    case gun:await(ConnPid, StreamRef) of
        {response, fin, _Status, _Headers} ->
            ct:fail(no_response);
        {response, nofin, Status, Headers} ->
            ct:pal("Response Headers: ~p", [Headers]),
            ?assertEqual(200, Status),
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            ResponseMsg =
                try
                    blockchain_state_channel_v1_pb:decode_msg(
                        Body,
                        blockchain_state_channel_message_v1_pb
                    )
                of
                    #blockchain_state_channel_message_v1_pb{msg = {response, Resp}} ->
                        ct:pal("got state channel msg ~p", [Resp]),
                        Resp;
                    _Else ->
                        ct:fail("unexpected response msg ~p.  Error: ~p", [Body, _Else])
                catch
                    _E:_R ->
                        ct:fail(" failed to decode response msg ~p ~p", [Body, {_E, _R}])
                end,

            %% assert the response msg here...which should be record type blockchain_state_channel_response_v1_pb
            %% this test isnt really interested in the data within this record, just that we get the record response
            ?assert(is_record(ResponseMsg, blockchain_state_channel_response_v1_pb))
    end,

    ok.

join_http2_negative_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [_Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm0, _} = test_utils:start_swarm(BaseDir, swarm1, 0),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),

    JoinNonce = crypto:strong_rand_bytes(2),

    Packet = test_utils:join_packet(PubKeyBin0, AppKey, JoinNonce, -40),

    {ok, ConnPid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(ConnPid),

    %% send a request with no body, which should fail with a 400 error as cannot decode payload
    StreamRef1 = gun:post(ConnPid, "/v1/router/message", [{?CLIENT_REF_NAME, <<"req1">>}], <<>>),
    case gun:await(ConnPid, StreamRef1) of
        {response, fin, _Status1, _Headers1} ->
            ct:fail(no_response);
        {response, nofin, Status1, Headers1} ->
            ct:pal("Response Headers: ~p", [Headers1]),
            ?assertEqual(400, Status1)
    end,

    %% send a request with an invalid body which does not decode to a SC msg body, should fail with a 400 error
    StreamRef2 = gun:post(
        ConnPid,
        "/v1/router/message",
        [{?CLIENT_REF_NAME, <<"req2">>}],
        crypto:strong_rand_bytes(99)
    ),
    case gun:await(ConnPid, StreamRef2) of
        {response, fin, _Status2, _Headers2} ->
            ct:fail(no_response);
        {response, nofin, Status2, Headers2} ->
            ct:pal("Response Headers: ~p", [Headers2]),
            ?assertEqual(400, Status2)
    end,

    %% send a request with an invalid method, should fail with a 405 error
    StreamRef3 = gun:put(ConnPid, "/v1/router/message", [{?CLIENT_REF_NAME, <<"req3">>}], Packet),
    case gun:await(ConnPid, StreamRef3) of
        {response, fin, _Status3, _Headers3} ->
            ct:fail(no_response);
        {response, nofin, Status3, Headers3} ->
            ct:pal("Response Headers: ~p", [Headers3]),
            ?assertEqual(405, Status3)
    end,

    ok.

join_http2_timeout_test(Config) ->
    _AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    RouterSwarm = blockchain_swarm:swarm(),
    [_Address | _] = libp2p_swarm:listen_addrs(RouterSwarm),
    {Swarm0, _} = test_utils:start_swarm(BaseDir, swarm2, 0),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),

    JoinNonce = crypto:strong_rand_bytes(2),

    Packet = test_utils:join_packet(
        PubKeyBin0,
        <<16#00, 16#00, 16#00, 16#FE, 16#72, 16#84, 16#17, 16#78, 16#04, 16#37, 16#45, 16#E1, 16#AC,
            16#62, 16#D2, 16#22>>,
        JoinNonce,
        -40
    ),

    {ok, ConnPid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(ConnPid),

    %% send a request with an invalid app key, should timeout
    StreamRef = gun:post(ConnPid, "/v1/router/message", [{?CLIENT_REF_NAME, <<"req1">>}], Packet),
    case gun:await(ConnPid, StreamRef) of
        {response, fin, _Status, _Headers} ->
            ct:fail(no_response);
        {response, nofin, Status, Headers} ->
            ct:pal("Response Headers: ~p", [Headers]),
            ?assertEqual(408, Status)
    end,

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
