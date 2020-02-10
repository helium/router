-module(router_SUITE).

-include_lib("helium_proto/src/pb/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
         all/0,
         init_per_testcase/2,
         end_per_testcase/2
        ]).

-export([
         basic_test/1
        ]).

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).

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
     basic_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase) ++ "_data",
    ok = application:set_env(router, base_dir, BaseDir),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, staging_console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, staging_console_secret, <<"secret">>),
    {ok, Pid} = elli:start_link([{callback, console_callback}, {port, 3000}]),
    {ok, _} = application:ensure_all_started(router),
    [{elli, Pid}, {base_dir, BaseDir}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(elli, Config),
    ok = elli:stop(Pid),
    ok = application:stop(router),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

basic_test(Config) ->
    {ok, 201, _, Body0} = hackney:get(<<?CONSOLE_URL/binary, "/api/router/sessions">>, [], <<>>, [with_body]),
    ?assertEqual(#{<<"jwt">> => <<"console_callback_token">>}, ?DECODE(Body0)),

    BaseDir = proplists:get_value(base_dir, Config),
    Swarm = start_swarm(BaseDir, basic_test_swarm, 3616),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(Swarm,
                                                   Address,
                                                   router_handler_test:version(),
                                                   router_handler_test,
                                                   [self()]),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    Stream ! {send, packet(PubKeyBin)},
    timer:sleep(500),
    ?assert(false),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

start_swarm(BaseDir, Name, Port) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)},
    SwarmOpts = [
                 {base_dir, BaseDir},
                 {key, Key},
                 {libp2p_group_gossip, [{seed_nodes, []}]},
                 {libp2p_nat, [{enabled, false}]},
                 {libp2p_proxy, [{limit, 1}]}
                ],
    {ok, Swarm} = libp2p_swarm:start(Name, SwarmOpts),
    libp2p_swarm:listen(Swarm, "/ip4/0.0.0.0/tcp/" ++  erlang:integer_to_list(Port)),
    libp2p_swarm:listen(Swarm, "/ip6/::/tcp/" ++  erlang:integer_to_list(Port)),
    ct:pal("created swarm ~p @ ~p p2p address=~p", [Name, Swarm, libp2p_swarm:p2p_address(Swarm)]),
    Swarm.


packet(PubKeyBin) ->
    HeliumPacket = #packet_pb{type=lorawan,
                              oui=2,
                              payload= <<>>
                             },
    Packet = #blockchain_state_channel_packet_v1_pb{packet=HeliumPacket,
                                                    hotspot=PubKeyBin},
    Msg = #blockchain_state_channel_message_v1_pb{msg={packet, Packet}},
    blockchain_state_channel_v1_pb:encode_msg(Msg).
