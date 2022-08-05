%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Aug 2022 12:35 PM
%%%-------------------------------------------------------------------
-module(router_gwmp_server_SUITE).
-author("jonathanruttenberg").

-include_lib("common_test/include/ct.hrl").
-include_lib("router_utils/include/semtech_udp.hrl").

-export([
  all/0,
  init_per_testcase/2,
  end_per_testcase/2
]).

%% API
-export([
  receive_push_data/1,
  receive_pull_data/1,
  receive_tx_ack/1,
  send_pull_resp/1
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
  [
    receive_push_data,
    receive_pull_data,
    receive_tx_ack,
    send_pull_resp
  ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config0) ->
  application:ensure_all_started(lager),

  gwmp_gateway_connections:init_ets(),

  {ok, SenderSocket} = gen_udp:open(0),
  {ok, GWMPServerPid} = gen_server:start({local, gwmp_server}, gwmp_server, [], []),
  NewConfig = [
    {sender_socket, SenderSocket},
    {gwmp_server_pid, GWMPServerPid},
    {server_host, "127.0.0.1"},
    {server_port, 1700}
    ],

  Config0 ++ NewConfig.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
  SenderSocket = proplists:get_value(sender_socket, Config),
  ok = gen_udp:close(SenderSocket),

  GWMPServerPid = proplists:get_value(gwmp_server_pid, Config),
  ok = gen_server:stop(GWMPServerPid),

  ok = gwmp_gateway_connections:delete_ets(),

  ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

receive_push_data(Config) ->
  ServerHost = proplists:get_value(server_host, Config),
  ServerPort = proplists:get_value(server_port, Config),
  SenderSocket = proplists:get_value(sender_socket, Config),

  ok = gen_udp:send(SenderSocket, ServerHost, ServerPort,  create_push_data()).

receive_pull_data(Config) ->
  ServerHost = proplists:get_value(server_host, Config),
  ServerPort = proplists:get_value(server_port, Config),
  SenderSocket = proplists:get_value(sender_socket, Config),

  {PullData, _MAC} = create_pull_data(),
  ok = gen_udp:send(SenderSocket, ServerHost, ServerPort, PullData).

receive_tx_ack(Config) ->
  ServerHost = proplists:get_value(server_host, Config),
  ServerPort = proplists:get_value(server_port, Config),
  SenderSocket = proplists:get_value(sender_socket, Config),

  ok = gen_udp:send(SenderSocket, ServerHost, ServerPort,  create_tx_ack_data()).

send_pull_resp(Config) ->
  ServerHost = proplists:get_value(server_host, Config),
  ServerPort = proplists:get_value(server_port, Config),
  SenderSocket = proplists:get_value(sender_socket, Config),

%%  send pull_data to create active gateway
  {PullData, MAC} = create_pull_data(),
  ok = gen_udp:send(SenderSocket, ServerHost, ServerPort, PullData),

%%  give gwmp server time to register the gateway
  timer:sleep(500),

%%  send pull_resp to gateway
  ok = gwmp_server:send_pull_resp(MAC, dummy_pull_response_map()),

%%  try to use some other MAC to send to a gateway
  BadPubKeyBin = <<"999999999999">>,
  BadMAC = udp_worker_utils:pubkeybin_to_mac(BadPubKeyBin),
  gateway_not_found = gwmp_server:send_pull_resp(BadMAC, dummy_pull_response_map()),

  ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

create_push_data() ->
  PubKeyBin = <<"12345678">>,
  MAC = udp_worker_utils:pubkeybin_to_mac(PubKeyBin),
  Token = semtech_udp:token(),
  Data = semtech_udp:push_data(Token, MAC,
    #{freq => 92.123456},
    #{dummy => <<"dummy push data">>}
  ),
  Data.

create_pull_data() ->
  PubKeyBin = <<"12345678">>,
  MAC = udp_worker_utils:pubkeybin_to_mac(PubKeyBin),
  Token = semtech_udp:token(),
  Data = semtech_udp:pull_data(Token, MAC),
  {Data, MAC}.

create_tx_ack_data() ->
%%  create dummy pull response
  PullResponseToken = semtech_udp:token(),
  Map = dummy_pull_response_map(),
  PullResponse = semtech_udp:pull_resp(PullResponseToken, Map),

%%  make Token from PullResponse
  Token = semtech_udp:token(PullResponse),

  PubKeyBin = <<"12345678">>,
  Data = semtech_udp:tx_ack(Token, udp_worker_utils:pubkeybin_to_mac(PubKeyBin)),
  Data.

dummy_pull_response_map() ->
  DownlinkPayload = <<"downlink_payload">>,
  DownlinkTimestamp = erlang:system_time(millisecond),
  DownlinkFreq = 915.0,
  DownlinkDatr = <<"SF11BW125">>,
  Map =
    #{
      data => DownlinkPayload,
      tmst => DownlinkTimestamp,
      freq => DownlinkFreq,
      datr => DownlinkDatr,
      powe => 27
    },
  Map.