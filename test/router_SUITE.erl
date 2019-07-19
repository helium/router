-module(router_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").

-export([
         all/0,
         init_per_testcase/2,
         end_per_testcase/2
        ]).

-export([
         basic/1
        ]).

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
    [basic].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special init config for test case
%% @end
%%--------------------------------------------------------------------
init_per_testcase(_, Config) ->
    ok = application:set_env(router, simple_http_endpoint, "http://127.0.0.1:8081"),
    lager:info("STARTING ROUTER"),
    {ok, _} = application:ensure_all_started(router),
    Config.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Special end config for test case
%% @end
%%--------------------------------------------------------------------
end_per_testcase(_, _Config) ->
    lager:info("STOPPING ROUTER"),
    ok = application:stop(router),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->
    {ok, _} = elli:start_link([{callback, echo_http_test}, {ip, {127,0,0,1}}, {port, 8081}, {callback_args, self()}]),
    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    {ok, MinerSwarm} = libp2p_swarm:start(miner_swarm, SwarmOpts),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [RouterAddress|_] = libp2p_swarm:listen_addrs(RouterSwarm),

    {ok, Stream} = libp2p_swarm:dial_framed_stream(MinerSwarm,
                                                   RouterAddress,
                                                   simple_http_stream:version(),
                                                   simple_http_stream_test,
                                                   []
                                                  ),
    Packet = #helium_LongFiRxPacket_pb{crc_check = true,
                                       timestamp = 15000,
                                       rssi = -2.0,
                                       snr = 1.0,
                                       oui = 1,
                                       device_id = 1,
                                       mac = 12,
                                       spreading = 'SF7',
                                       payload = <<"some data here">>
                                      },
    Resp = #helium_LongFiResp_pb{id=0, kind={rx, Packet}},
    EncodedPacket = helium_longfi_pb:encode_msg(Resp),
    Stream ! EncodedPacket,
    ct:pal("packet ~p", [EncodedPacket]),
    receive
        {'POST', _, _, Body} ->
            ct:pal("body ~p", [Body]),
            ?assertEqual(EncodedPacket, Body);
        Data ->
            ct:pal("wrong data ~p", [Data]),
            ct:fail("wrong data")
    after 2000 ->
            ct:fail(timeout)
    end,
    ok.
