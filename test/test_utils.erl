-module(test_utils).

-export([
    init_per_testcase/2,
    end_per_testcase/2,

    join_device/1, join_device/2,

    ignore_messages/0,

    wait_for_console_event/2,
    wait_for_console_event_sub/2,
    wait_channel_data/1,
    wait_organizations_burned/1,

    tmp_dir/0, tmp_dir/1,
    wait_until/1, wait_until/3,
    wait_until_no_messages/1,
    is_jsx_encoded_map/1,
    ws_init/0
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("lorawan_vars.hrl").
-include("console_test.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

-spec init_per_testcase(atom(), list()) -> list().
init_per_testcase(TestCase, Config) ->
    %% Setup application env for Router / Chain / Lager
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(blockchain, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, testing, true),
    ok = application:set_env(router, router_console_api, [
        {endpoint, ?CONSOLE_URL},
        {downlink_endpoint, ?CONSOLE_URL},
        {ws_endpoint, ?CONSOLE_WS_URL},
        {secret, <<>>}
    ]),
    FormatStr = [
        "[",
        date,
        " ",
        time,
        "] ",
        pid,
        " [",
        severity,
        "]",
        {device_id, [" [", device_id, "]"], ""},
        " [",
        {module, ""},
        {function, [":", function], ""},
        {line, [":", line], ""},
        "] ",
        message,
        "\n"
    ],
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    ok = application:set_env(lager, crash_log, "crash.log"),
    case os:getenv("CT_LAGER", "NONE") of
        "DEBUG" ->
            ok = application:set_env(lager, handlers, [
                {lager_console_backend, [
                    {level, error},
                    {formatter_config, FormatStr}
                ]},
                {lager_file_backend, [
                    {file, "router.log"},
                    {level, error},
                    {formatter_config, FormatStr}
                ]},
                {lager_file_backend, [
                    {file, "device.log"},
                    {level, error},
                    {formatter_config, FormatStr}
                ]}
            ]),
            ok = application:set_env(lager, traces, [
                {lager_console_backend, [{application, router}], debug},
                {lager_console_backend, [{module, router_console_api}], debug},
                {lager_console_backend, [{module, router_device_routing}], debug},
                {lager_console_backend, [{module, router_test_console_callback}], debug},
                {lager_console_backend, [{module, router_test_device}], debug},
                {{lager_file_backend, "router.log"}, [{application, router}], debug},
                {{lager_file_backend, "router.log"}, [{module, router_console_api}], debug},
                {{lager_file_backend, "router.log"}, [{module, router_device_routing}], debug},
                {{lager_file_backend, "device.log"}, [{device_id, <<"yolo_id">>}], debug},
                {{lager_file_backend, "router.log"}, [{module, console_callback}], debug}
            ]);
        _ ->
            ok
    end,

    %% FIX ME: Mocking router_device_devaddr as we do not have a proper OUI setup  maybe fixed by add OUI?
    % meck:new(router_device_devaddr, [passthrough]),
    % meck:expect(router_device_devaddr, allocate, fun(_, _) ->
    %     DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),
    %     {ok, <<33554431:25/integer-unsigned-little, DevAddrPrefix:7/integer>>}
    % end),

    %% Start testing Console
    TestConsolePid = router_test_console:init(self()),
    ct:pal("testing Console started @ ~p", [TestConsolePid]),

    %% Start Router
    {ok, _} = application:ensure_all_started(router),

    % Grab Router's keys
    SwarmKey = filename:join([
        application:get_env(blockchain, base_dir, "data"),
        "blockchain",
        "swarm_key"
    ]),
    ok = filelib:ensure_dir(SwarmKey),
    {ok, RouterKeys} = libp2p_crypto:load_keys(SwarmKey),
    #{public := RouterPubKey, secret := RouterPrivKey} = RouterKeys,

    % Generate some keys to act as hotspots
    RandomHotspotsKey = lists:map(
        fun(_) ->
            #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
            {PrivKey, PubKey}
        end,
        lists:seq(1, 10)
    ),

    %% Insert Keys into init chain each keys will receive a locationa as well as some DC
    %% FIX ME: maybe Router should not get inserted as a gateway as well
    {ok, _GenesisMembers, ConsensusMembers, _Keys} = blockchain_test_utils:init_chain(
        5000,
        [{RouterPrivKey, RouterPubKey}] ++ RandomHotspotsKey
    ),

    %% Create OUI Routing and advance chain 1 block
    OUI = 1,
    ok = add_oui(OUI, ConsensusMembers),

    [
        {base_dir, BaseDir},
        {hotspots, RandomHotspotsKey},
        {consensus_member, ConsensusMembers},
        {test_console, TestConsolePid},
        {oui, OUI}
        | Config
    ].

-spec end_per_testcase(atom(), list()) -> ok.
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(test_console, Config),
    ok = router_test_console:stop(Pid),
    ok = application:stop(router),
    ok = application:stop(lager),
    e2qc:teardown(router_console_api_get_devices_by_deveui_appeui),
    e2qc:teardown(router_console_api_get_org),
    application:stop(e2qc),
    ok = application:stop(throttle),
    % meck:unload(router_device_devaddr),
    ok.

join_device(Config) ->
    join_device(Config, #{}).

join_device(TestDevicePid, JoinOpts) ->
    {ok, SCPacket} = router_test_device:join(TestDevicePid, JoinOpts),
    timer:sleep(router_utils:join_timeout()),
    ?assert(router_test_device:joined(TestDevicePid)),

    TestDevice = router_test_device:device(TestDevicePid),
    DeviceID = router_device:id(TestDevice),

    PubKeyBin = router_test_device:hotspot_pubkey_bin(TestDevicePid),
    HotspotName = blockchain_utils:addr2name(PubKeyBin),

    %% Waiting for report device status on that join request
    ?MODULE:wait_for_console_event(<<"join_request">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"join_request">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => DeviceID,
        <<"data">> => #{
            <<"dc">> => fun erlang:is_map/1,
            <<"fcnt">> => 0,
            <<"payload_size">> => 0,
            <<"payload">> => <<>>,
            <<"raw_packet">> => base64:encode(
                blockchain_helium_packet_v1:payload(
                    blockchain_state_channel_packet_v1:packet(SCPacket)
                )
            ),
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => 0.0,
                <<"snr">> => 0.0,
                <<"spreading">> => <<"SF8BW125">>,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),

    %% Waiting for report device status on that join request
    ?MODULE:wait_for_console_event(<<"join_accept">>, #{
        <<"id">> => fun erlang:is_binary/1,
        <<"category">> => <<"join_accept">>,
        <<"sub_category">> => <<"undefined">>,
        <<"description">> => fun erlang:is_binary/1,
        <<"reported_at">> => fun erlang:is_integer/1,
        <<"device_id">> => DeviceID,
        <<"data">> => #{
            <<"fcnt">> => 0,
            <<"payload_size">> => fun erlang:is_integer/1,
            <<"payload">> => fun erlang:is_binary/1,
            <<"port">> => fun erlang:is_integer/1,
            <<"devaddr">> => fun erlang:is_binary/1,
            <<"hotspot">> => #{
                <<"id">> => erlang:list_to_binary(libp2p_crypto:bin_to_b58(PubKeyBin)),
                <<"name">> => erlang:list_to_binary(HotspotName),
                <<"rssi">> => fun erlang:is_integer/1,
                <<"snr">> => 0.0,
                <<"spreading">> => fun erlang:is_binary/1,
                <<"frequency">> => fun erlang:is_float/1,
                <<"channel">> => fun erlang:is_number/1,
                <<"lat">> => fun erlang:is_float/1,
                <<"long">> => fun erlang:is_float/1
            }
        }
    }),
    ok.

ignore_messages() ->
    receive
        Msg ->
            ct:pal("ignored message: ~p~n", [Msg]),
            ?MODULE:ignore_messages()
    after 2000 -> ok
    end.

% "category": "uplink | downlink | misc"
wait_for_console_event(Category, #{<<"id">> := ExpectedUUID} = Expected) when
    erlang:is_binary(ExpectedUUID)
->
    try
        receive
            {console_event, Category, _, #{<<"id">> := ExpectedUUID} = Got} ->
                case match_map(Expected, Got) of
                    true ->
                        {ok, Got};
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_for_console_event (explicit id) ~p data failed ~p", [
                            Category,
                            Reason
                        ])
                end
        after 4250 -> ct:fail("wait_for_console_event (explicit id) ~p timeout", [Category])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event (explicit id) ~p stacktrace ~n~p", [
                Category,
                {_Reason, _Stacktrace}
            ]),
            ct:fail("wait_for_console_event (explicit id) ~p failed", [Category])
    end;
wait_for_console_event(Category, Expected) ->
    Got =
        receive
            {console_event, Category, _, G} -> G
        after 4250 ->
            ct:fail("wait_for_console_event ~p timeout", [Category])
        end,
    try match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({wait_for_console_event, {category, Category}, Reason})
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event ~p stacktrace ~n~p", [Category, {_Reason, _Stacktrace}]),
            ct:fail({wait_for_console_event, {category, Category}, _Reason})
    end.

% "sub_category":
%   "undefined
%   | uplink_confirmed | uplink_unconfirmed | uplink_integration_req | uplink_integration_res | uplink_dropped
%   | downlink_confirmed | downlink_unconfirmed | downlink_dropped | downlink_queued | downlink_ack
%   | misc_integration_error"
wait_for_console_event_sub(SubCategory, #{<<"id">> := ExpectedUUID} = Expected) when
    erlang:is_binary(ExpectedUUID)
->
    Got =
        receive
            {console_event, _, SubCategory, #{<<"id">> := ExpectedUUID} = G} ->
                G
        after 4250 ->
            ct:fail("wait_for_console_event_sub (explicit id: ~p) ~p timeout", [
                ExpectedUUID,
                SubCategory
            ])
        end,

    try match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED: got: ~n~p~n~nexpected: ~n~p", [Got, Expected]),
            ct:fail({
                wait_for_console_event_sub,
                {sub_category, SubCategory},
                {expected_id, ExpectedUUID},
                Reason
            })
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event_sub (explicit id: ~p) ~p stacktrace ~n~p", [
                ExpectedUUID,
                SubCategory,
                {_Reason, _Stacktrace}
            ]),
            ct:fail({
                wait_for_console_event_sub,
                {sub_category, SubCategory},
                {expected_id, ExpectedUUID},
                _Reason
            })
    end;
wait_for_console_event_sub(SubCategory, Expected) ->
    try
        receive
            {console_event, _, SubCategory, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        {ok, Got};
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_for_console_event_sub ~p data failed ~p", [
                            SubCategory,
                            Reason
                        ])
                end
        after 4250 -> ct:fail("wait_for_console_event_sub ~p timeout", [SubCategory])
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_for_console_event_sub ~p stacktrace ~n~p", [
                SubCategory,
                {_Reason, _Stacktrace}
            ]),
            ct:fail("wait_for_console_event_sub ~p failed", [SubCategory])
    end.

wait_channel_data(Expected) ->
    Got =
        receive
            {channel_data, G} -> G
        after 1250 ->
            ct:fail("wait_channel_data timeout")
        end,
    try match_map(Expected, Got) of
        true ->
            {ok, Got};
        {false, Reason} ->
            ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
            ct:fail({wait_channel_data, Reason})
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_channel_data stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_channel_data failed caught ~p", [_Reason])
    end.

wait_organizations_burned(Expected) ->
    try
        receive
            {organizations_burned, Got} ->
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    {false, Reason} ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_organizations_burned failed ~p", [Reason])
                end
        after 1250 -> ct:fail("wait_organizations_burned timeout")
        end
    catch
        _Class:_Reason:_Stacktrace ->
            ct:pal("wait_organizations_burned stacktrace ~n~p", [{_Reason, _Stacktrace}]),
            ct:fail("wait_organizations_burned failed")
    end.

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory to be used as a scratch by eunit tests
%% @end
%%-------------------------------------------------------------------
tmp_dir() ->
    os:cmd("mkdir -p " ++ ?BASE_TMP_DIR),
    create_tmp_dir(?BASE_TMP_DIR_TEMPLATE).

tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        {fail, _Reason} = Fail ->
            Fail;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

wait_until_no_messages(Pid) ->
    wait_until(fun() ->
        case erlang:process_info(Pid, message_queue_len) of
            {message_queue_len, 0} ->
                true;
            {message_queue_len, N} ->
                {messages_still_in_queue, N}
        end
    end).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec match_map(map(), any()) -> true | {false, term()}.
match_map(Expected, Got) when is_map(Got) ->
    ESize = maps:size(Expected),
    GSize = maps:size(Got),
    case ESize == GSize of
        false ->
            Flavor =
                case ESize > GSize of
                    true -> {missing_keys, maps:keys(Expected) -- maps:keys(Got)};
                    false -> {extra_keys, maps:keys(Got) -- maps:keys(Expected)}
                end,
            {false, {size_mismatch, {expected, ESize}, {got, GSize}, Flavor}};
        true ->
            maps:fold(
                fun
                    (_K, _V, {false, _} = Acc) ->
                        Acc;
                    (K, V, true) when is_function(V) ->
                        case V(maps:get(K, Got, undefined)) of
                            true ->
                                true;
                            false ->
                                {false, {value_predicate_failed, K, maps:get(K, Got, undefined)}}
                        end;
                    (K, '_', true) ->
                        case maps:is_key(K, Got) of
                            true -> true;
                            false -> {false, {missing_key, K}}
                        end;
                    (K, V, true) when is_map(V) ->
                        case match_map(V, maps:get(K, Got, #{})) of
                            true -> true;
                            Err -> {false, {key, K, Err}}
                        end;
                    (K, V0, true) when is_list(V0) ->
                        V1 = lists:zip(lists:seq(1, erlang:length(V0)), lists:sort(V0)),
                        G0 = maps:get(K, Got, []),
                        G1 = lists:zip(lists:seq(1, erlang:length(G0)), lists:sort(G0)),
                        case match_map(maps:from_list(V1), maps:from_list(G1)) of
                            true -> true;
                            Err -> {false, {key, K, Err}}
                        end;
                    (K, V, true) ->
                        case maps:get(K, Got, undefined) of
                            V -> true;
                            _ -> {false, {value_mismatch, K, V, maps:get(K, Got, undefined)}}
                        end
                end,
                true,
                Expected
            )
    end;
match_map(_Expected, _Got) ->
    {false, not_map}.

-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path) ->
    nonl(os:cmd("mktemp -d " ++ Path)).

nonl([$\n | T]) -> nonl(T);
nonl([H | T]) -> [H | nonl(T)];
nonl([]) -> [].

%%%-------------------------------------------------------------------
%% @doc
%%
%% `jsx:encode/1' turns proplists into maps, but empty proplists into arrays.
%% There are times empty "maps" are what we expect, but they're proplists before
%% they hit the api boundary.
%%
%% @end
%% %-------------------------------------------------------------------
-spec is_jsx_encoded_map(map() | list()) -> boolean().
is_jsx_encoded_map([]) -> true;
is_jsx_encoded_map(M) when is_map(M) -> true;
is_jsx_encoded_map(_) -> false.

-spec ws_init() -> {ok, pid()}.
ws_init() ->
    receive
        {websocket_init, Pid} ->
            {ok, Pid}
    after 2500 -> ct:fail(websocket_init_timeout)
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec add_oui(non_neg_integer(), list()) -> ok.
add_oui(OUI, ConsensusMembers) ->
    {ok, PubKey, SigFun, _} = blockchain_swarm:keys(),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    %% Create and submit OUI txn with an empty filter
    OUI = 1,
    {Filter, _} = xor16:to_bin(xor16:new([0], fun xxhash:hash64/1)),
    OUITxn = blockchain_txn_oui_v1:new(OUI, PubKeyBin, [PubKeyBin], Filter, 8),
    OUITxnFee = blockchain_txn_oui_v1:calculate_fee(OUITxn, Chain),
    OUITxnStakingFee = blockchain_txn_oui_v1:calculate_staking_fee(OUITxn, Chain),
    OUITxn0 = blockchain_txn_oui_v1:fee(OUITxn, OUITxnFee),
    OUITxn1 = blockchain_txn_oui_v1:staking_fee(OUITxn0, OUITxnStakingFee),

    SignedOUITxn = blockchain_txn_oui_v1:sign(OUITxn1, SigFun),

    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI, Ledger)),

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn]),
    _ = blockchain_test_utils:add_block(Block0, Chain, self(), blockchain_swarm:tid()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),
    ok.
