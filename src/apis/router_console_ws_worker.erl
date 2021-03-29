%%%-------------------------------------------------------------------
%% @doc
%% == Router Console WS Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_console_ws_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(DOWNLINK_TOOL_ORIGIN, <<"console_downlink_queue">>).
-define(DOWNLINK_TOOL_CHANNEL_NAME, <<"Console downlink tool">>).

-record(state, {
    ws :: pid(),
    ws_endpoint :: binary(),
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    WSEndpoint = maps:get(ws_endpoint, Args),
    Token = router_console_api:get_token(),
    WSPid = start_ws(WSEndpoint, Token),
    {ok, DB, [_, CF]} = router_db:get(),
    {ok, #state{
        ws = WSPid,
        ws_endpoint = WSEndpoint,
        db = DB,
        cf = CF
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {'EXIT', WSPid0, _Reason},
    #state{ws = WSPid0, ws_endpoint = WSEndpoint, db = DB, cf = CF} = State
) ->
    lager:error("websocket connetion went down: ~p, restarting", [_Reason]),
    Token = router_console_api:get_token(),
    WSPid1 = start_ws(WSEndpoint, Token),
    check_devices(DB, CF),
    {noreply, State#state{ws = WSPid1}};
handle_info(ws_joined, #state{ws = WSPid} = State) ->
    lager:info("joined, sending router address to console", []),
    PubKeyBin = blockchain_swarm:pubkey_bin(),
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    Payload = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"organization:all">>,
        <<"router:address">>,
        #{address => B58}
    ),
    WSPid ! {ws_resp, Payload},
    {noreply, State};
handle_info(
    {ws_message, <<"device:all">>, <<"device:all:clear_downlink_queue:devices">>, #{
        <<"devices">> := DeviceIDs
    }},
    State
) ->
    lager:info("console triggered clearing downlink for devices ~p", [DeviceIDs]),
    lists:foreach(
        fun(DeviceID) ->
            case router_devices_sup:maybe_start_worker(DeviceID, #{}) of
                {error, _Reason} ->
                    lager:info("failed to clear queue, could not find device ~p: ~p", [
                        DeviceID,
                        _Reason
                    ]);
                {ok, Pid} ->
                    router_device_worker:clear_queue(Pid)
            end
        end,
        DeviceIDs
    ),
    {noreply, State};
handle_info(
    {ws_message, <<"device:all">>, <<"device:all:downlink:devices">>, #{
        <<"devices">> := DeviceIDs,
        <<"payload">> := MapPayload,
        <<"channel_name">> := ProvidedChannelName
    }},
    State
) ->
    ChannelName =
        case maps:get(<<"from">>, MapPayload, undefined) of
            ?DOWNLINK_TOOL_ORIGIN ->
                ?DOWNLINK_TOOL_CHANNEL_NAME;
            _ ->
                ProvidedChannelName
        end,
    Position =
        case maps:get(<<"position">>, MapPayload, <<"last">>) of
            <<"first">> -> first;
            _ -> last
        end,

    lager:info("sending downlink ~p for devices ~p from channel ~p in position ~p", [
        MapPayload,
        DeviceIDs,
        ChannelName,
        Position
    ]),
    lists:foreach(
        fun(DeviceID) ->
            Channel = router_channel:new(
                <<"console_websocket">>,
                websocket,
                ChannelName,
                #{},
                DeviceID,
                self()
            ),
            ok = router_device_channels_worker:handle_console_downlink(
                DeviceID,
                MapPayload,
                Channel,
                Position
            )
        end,
        DeviceIDs
    ),
    {noreply, State};
handle_info(
    {ws_message, <<"device:all">>, <<"device:all:refetch:devices">>, #{<<"devices">> := DeviceIDs}},
    #state{db = DB, cf = CF} = State
) ->
    update_devices(DB, CF, DeviceIDs),
    {noreply, State};
handle_info(
    {ws_message, <<"organization:all">>, <<"organization:all:refill:dc_balance">>, #{
        <<"id">> := OrgID,
        <<"dc_balance_nonce">> := Nonce,
        <<"dc_balance">> := Balance
    }},
    State
) ->
    lager:info("got an org balance refill for ~p of ~p (~p)", [OrgID, Balance, Nonce]),
    ok = router_console_dc_tracker:refill(OrgID, Nonce, Balance),
    {noreply, State};
handle_info(
    {ws_message, <<"device:all">>, <<"device:all:active:devices">>, #{<<"devices">> := DeviceIDs}},
    #state{db = DB, cf = CF} = State
) ->
    lager:info("got activate message for devices: ~p", [DeviceIDs]),
    update_devices(DB, CF, DeviceIDs),
    {noreply, State};
handle_info(
    {ws_message, <<"device:all">>, <<"device:all:inactive:devices">>, #{
        <<"devices">> := DeviceIDs
    }},
    #state{db = DB, cf = CF} = State
) ->
    lager:info("got deactivate message for devices: ~p", [DeviceIDs]),
    update_devices(DB, CF, DeviceIDs),
    {noreply, State};
handle_info(
    {ws_message, <<"label:all">>, <<"label:all:downlink:fetch_queue">>, #{
        <<"label">> := LabelID,
        <<"devices">> := DeviceIDs
    }},
    State
) ->
    lager:info("got label ~p fetch_queue message for devices: ~p", [LabelID, DeviceIDs]),
    lists:foreach(
        fun(DeviceID) ->
            case router_devices_sup:maybe_start_worker(DeviceID, #{}) of
                {error, _Reason} ->
                    lager:info(
                        [{device_id, DeviceID}],
                        "fetch_queue could not find device ~p: ~p",
                        [
                            DeviceID,
                            _Reason
                        ]
                    );
                {ok, Pid} ->
                    router_device_worker:get_queue_updates(Pid, self(), LabelID)
            end
        end,
        DeviceIDs
    ),
    {noreply, State};
handle_info(
    {ws_message, <<"device:all">>, <<"device:all:downlink:fetch_queue">>, #{
        <<"device">> := DeviceID
    }},
    State
) ->
    lager:info([{device_id, DeviceID}], "got device fetch_queue message for device: ~p", [DeviceID]),
    case router_devices_sup:maybe_start_worker(DeviceID, #{}) of
        {error, _Reason} ->
            lager:warning([{device_id, DeviceID}], "fetch_queue could not find device ~p: ~p", [
                DeviceID,
                _Reason
            ]);
        {ok, Pid} ->
            router_device_worker:get_queue_updates(Pid, self(), undefined)
    end,
    {noreply, State};
handle_info(
    {ws_message, <<"device:all">>, <<"device:all:discover:devices">>, Map},
    State
) ->
    DeviceID = maps:get(<<"device_id">>, Map),
    Hostpost = maps:get(<<"hotspot">>, Map),
    PubKeyBin = libp2p_crypto:b58_to_bin(erlang:binary_to_list(Hostpost)),
    TxnID = maps:get(<<"transaction_id">>, Map),
    lager:debug([{device_id, DeviceID}], "starting discovery for ~p/~p (txn id=~p)", [
        DeviceID,
        blockchain_utils:addr2name(PubKeyBin),
        TxnID
    ]),
    _ = erlang:spawn(router_discovery, start, [Map]),
    {noreply, State};
handle_info(
    {router_device_worker, queue_update, LabelID, DeviceID, Queue},
    #state{ws = WSPid} = State
) ->
    lager:debug([{device_id, DeviceID}], "got device ~p queue_update: ~p, label ~p", [
        DeviceID,
        Queue,
        LabelID
    ]),
    Payload =
        case LabelID of
            undefined ->
                router_console_ws_handler:encode_msg(
                    <<"0">>,
                    <<"device:all">>,
                    <<"downlink:update_queue">>,
                    #{device => DeviceID, queue => Queue}
                );
            LabelID ->
                router_console_ws_handler:encode_msg(
                    <<"0">>,
                    <<"label:all">>,
                    <<"downlink:update_queue">>,
                    #{label => LabelID, device => DeviceID, queue => Queue}
                )
        end,
    WSPid ! {ws_resp, Payload},
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    lager:warning("went down ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec start_ws(WSEndpoint :: binary(), Token :: binary()) -> pid().
start_ws(WSEndpoint, Token) ->
    Url = binary_to_list(<<WSEndpoint/binary, "?token=", Token/binary, "&vsn=2.0.0">>),
    {ok, Pid} = router_console_ws_handler:start_link(#{
        url => Url,
        auto_join => [<<"device:all">>, <<"organization:all">>, <<"label:all">>],
        forward => self()
    }),
    Pid.

-spec update_devices(
    DB :: rocksdb:db_handle(),
    CF :: rocksdb:cf_handle(),
    DeviceIDs :: [binary()]
) -> pid().
update_devices(DB, CF, DeviceIDs) ->
    erlang:spawn(
        fun() ->
            Total = erlang:length(DeviceIDs),
            lager:info("got update for ~p devices: ~p from WS", [Total, DeviceIDs]),
            lists:foreach(
                fun({Index, DeviceID}) ->
                    case router_devices_sup:lookup_device_worker(DeviceID) of
                        {error, not_found} ->
                            lager:info(
                                "[~p/~p] device worker not running for device ~p, updating DB record",
                                [Index, Total, DeviceID]
                            ),
                            update_device_record(DB, CF, DeviceID);
                        {ok, Pid} ->
                            router_device_worker:device_update(Pid)
                    end
                end,
                lists:zip(lists:seq(1, Total), DeviceIDs)
            )
        end
    ).

-spec update_device_record(
    DB :: rocksdb:db_handle(),
    CF :: rocksdb:cf_handle(),
    DeviceID :: binary()
) -> ok.
update_device_record(DB, CF, DeviceID) ->
    case router_console_api:get_device(DeviceID) of
        {error, _Reason} ->
            lager:warning("failed to get device ~p ~p", [DeviceID, _Reason]);
        {ok, APIDevice} ->
            Device0 =
                case router_device:get_by_id(DB, CF, DeviceID) of
                    {ok, D} -> D;
                    {error, _} -> router_device:new(DeviceID)
                end,
            DeviceUpdates = [
                {name, router_device:name(APIDevice)},
                {dev_eui, router_device:dev_eui(APIDevice)},
                {app_eui, router_device:app_eui(APIDevice)},
                {metadata, router_device:metadata(APIDevice)},
                {is_active, router_device:is_active(APIDevice)}
            ],
            Device = router_device:update(DeviceUpdates, Device0),
            {ok, _} = router_device_cache:save(Device),
            {ok, _} = router_device:save(DB, CF, Device),
            ok
    end.

-spec check_devices(DB :: rocksdb:db_handle(), CF :: rocksdb:cf_handle()) -> pid().
check_devices(DB, CF) ->
    lager:info("checking all devices in DB"),
    DeviceIDs = [router_device:id(Device) || Device <- router_device:get(DB, CF)],
    update_devices(DB, CF, DeviceIDs).
