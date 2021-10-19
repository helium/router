%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Channels Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_channels_worker).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

-include("router_device_worker.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    handle_join/2,
    handle_device_update/2,
    handle_frame/2,
    report_request/4,
    report_response/4,
    handle_downlink/3,
    handle_console_downlink/4,
    new_data_cache/7,
    refresh_channels/1,
    frame_timeout/2
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
-define(BACKOFF_MIN, timer:seconds(15)).
-define(BACKOFF_MAX, timer:minutes(5)).
-define(BACKOFF_INIT,
    {backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal), erlang:make_ref()}
).
-define(CLEAR_QUEUE_PAYLOAD, <<"__clear_downlink_queue__">>).

-record(data_cache, {
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    uuid :: router_utils:uuid_v4(),
    packet :: #packet_pb{},
    frame :: #frame{},
    region :: atom(),
    time :: non_neg_integer(),
    hold_time :: non_neg_integer()
}).

-record(state, {
    chain = blockchain:blockchain(),
    event_mgr :: pid(),
    device_worker :: pid(),
    device :: router_device:device(),
    channels = #{} :: map(),
    channels_backoffs = #{} :: map(),
    data_cache = #{} :: #{router_utils:uuid_v4() => #{libp2p_crypto:pubkey_bin() => #data_cache{}}}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_join(pid(), #join_cache{}) -> ok.
handle_join(Pid, JoinCache) ->
    gen_server:cast(Pid, {handle_join, JoinCache}).

-spec handle_device_update(pid(), router_device:device()) -> ok.
handle_device_update(Pid, Device) ->
    gen_server:cast(Pid, {handle_device_update, Device}).

-spec handle_frame(pid(), #data_cache{}) -> ok.
handle_frame(Pid, DataCache) ->
    gen_server:cast(Pid, {handle_frame, DataCache}).

-spec report_request(pid(), router_utils:uuid_v4(), router_channel:channel(), map()) -> ok.
report_request(Pid, UUID, Channel, Map) ->
    gen_server:cast(Pid, {report_request, UUID, Channel, Map}).

-spec report_response(pid(), router_utils:uuid_v4(), router_channel:channel(), map()) -> ok.
report_response(Pid, UUID, Channel, Map) ->
    gen_server:cast(Pid, {report_response, UUID, Channel, Map}).

-spec frame_timeout(pid(), router_utils:uuid_v4()) -> ok.
frame_timeout(Pid, UUID) ->
    gen_server:cast(Pid, {frame_timeout, UUID}).

-spec handle_console_downlink(binary(), map(), router_channel:channel(), first | last) -> ok.
handle_console_downlink(DeviceID, MapPayload, Channel, Position) ->
    {ChannelHandler, _} = router_channel:handler(Channel),
    case router_devices_sup:maybe_start_worker(DeviceID, #{}) of
        {error, _Reason} ->
            ok = router_metrics:downlink_inc(ChannelHandler, error),
            Desc = io_lib:format("Failed to queue downlink (worker failed): ~p", [_Reason]),
            ok = maybe_report_downlink_dropped(DeviceID, Desc, Channel),
            lager:info("failed to start/find device ~p: ~p", [DeviceID, _Reason]);
        {ok, Pid} ->
            case downlink_decode(MapPayload) of
                {ok, clear_queue} ->
                    lager:info("clearing device queue because downlink payload from console"),
                    router_device_worker:clear_queue(Pid);
                {ok, {Confirmed, Port, Payload}} ->
                    ok = router_metrics:downlink_inc(ChannelHandler, ok),
                    router_device_worker:queue_message(
                        Pid,
                        #downlink{
                            confirmed = Confirmed,
                            port = Port,
                            payload = Payload,
                            channel = Channel
                        },
                        Position
                    );
                {error, _Reason} ->
                    Desc = io_lib:format("Failed to queue downlink (downlink_decode failed): ~p", [
                        _Reason
                    ]),
                    ok = maybe_report_downlink_dropped(DeviceID, Desc, Channel),
                    ok = router_metrics:downlink_inc(ChannelHandler, error),
                    lager:debug("could not parse json downlink message ~p for ~p", [
                        _Reason,
                        DeviceID
                    ])
            end
    end.

-spec handle_downlink(
    Pid :: pid(),
    BinaryPayload :: binary(),
    Channel :: router_channel:channel()
) -> ok.
handle_downlink(Pid, BinaryPayload, Channel) ->
    gen_server:cast(
        Pid,
        {handle_downlink, BinaryPayload, Channel}
    ).

-spec new_data_cache(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    UUID :: router_utils:uuid_v4(),
    Packet :: #packet_pb{},
    Frame :: #frame{},
    Region :: atom(),
    Time :: non_neg_integer(),
    HoldTime :: non_neg_integer()
) -> #data_cache{}.
new_data_cache(PubKeyBin, UUID, Packet, Frame, Region, Time, HoldTime) ->
    #data_cache{
        pubkey_bin = PubKeyBin,
        uuid = UUID,
        packet = Packet,
        frame = Frame,
        region = Region,
        time = Time,
        hold_time = HoldTime
    }.

-spec refresh_channels(Pid :: pid()) -> ok.
refresh_channels(Pid) ->
    Pid ! refresh_channels,
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    Blockchain = maps:get(blockchain, Args),
    DeviceWorkerPid = maps:get(device_worker, Args),
    Device = maps:get(device, Args),
    {ok, EventMgrRef} = router_channel:start_link(),
    %% We are doing this because of trap_exit in gen_event
    _ = erlang:monitor(process, DeviceWorkerPid),
    ?MODULE:refresh_channels(self()),
    ok = router_utils:lager_md(Device),
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, #state{
        chain = Blockchain,
        event_mgr = EventMgrRef,
        device_worker = DeviceWorkerPid,
        device = Device
    }}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {handle_join, JoinData = #join_cache{}},
    #state{
        chain = Blockchain,
        event_mgr = EventMgrPid,
        device = Device
    } = State
) ->
    {ok, Map} = send_join_to_channel(JoinData, Device, EventMgrPid, Blockchain),
    lager:debug("join_timeout for data: ~p", [Map]),
    {noreply, State};
handle_cast({handle_device_update, Device}, State) ->
    {noreply, State#state{device = Device}};
handle_cast(
    {handle_frame,
        #data_cache{uuid = UUID, pubkey_bin = PubKeyBin, packet = NewPacket} = NewDataCache},
    #state{data_cache = DataCache} = State
) ->
    %% We (sadly) still need to do a little deduplication here
    UUIDCache0 = maps:get(UUID, DataCache, #{}),
    UUIDCache1 =
        case maps:get(PubKeyBin, UUIDCache0, undefined) of
            undefined ->
                maps:put(PubKeyBin, NewDataCache, UUIDCache0);
            #data_cache{pubkey_bin = PubKeyBin, packet = OldPacket} ->
                NewRSSI = blockchain_helium_packet_v1:signal_strength(NewPacket),
                OldRSSI = blockchain_helium_packet_v1:signal_strength(OldPacket),
                case NewRSSI > OldRSSI of
                    false ->
                        UUIDCache0;
                    true ->
                        maps:put(PubKeyBin, NewDataCache, UUIDCache0)
                end
        end,
    DataCache1 = maps:put(UUID, UUIDCache1, DataCache),
    {noreply, State#state{data_cache = DataCache1}};
handle_cast(
    {frame_timeout, UUID},
    #state{
        data_cache = DataCache0,
        chain = Blockchain,
        event_mgr = EventMgrPid,
        device = Device
    } = State
) ->
    case maps:take(UUID, DataCache0) of
        {CachedData, DataCache1} ->
            {ok, Map} = send_data_to_channel(CachedData, Device, EventMgrPid, Blockchain),
            lager:debug("frame_timeout for ~p data: ~p", [UUID, Map]),
            {noreply, State#state{data_cache = DataCache1}};
        error ->
            lager:debug("frame_timeout unknown UUID", [UUID]),
            {noreply, State}
    end;
handle_cast(
    {handle_downlink, BinaryPayload, Channel},
    #state{device_worker = DeviceWorker} = State
) ->
    {ChannelHandler, _} = router_channel:handler(Channel),
    case downlink_decode(BinaryPayload) of
        {ok, clear_queue} ->
            lager:info("clearing device queue because downlink payload"),
            router_device_worker:clear_queue(DeviceWorker);
        {ok, {Confirmed, Port, Payload}} ->
            ok = router_metrics:downlink_inc(ChannelHandler, ok),
            ok = router_device_worker:queue_message(DeviceWorker, #downlink{
                confirmed = Confirmed,
                port = Port,
                payload = Payload,
                channel = Channel
            });
        {error, _Reason} ->
            ok = router_metrics:downlink_inc(ChannelHandler, error),
            lager:debug("could not parse json downlink message ~p", [_Reason])
    end,
    {noreply, State};
handle_cast({report_request, UUID, Channel, Report}, #state{device = Device} = State) ->
    ChannelName = router_channel:name(Channel),
    lager:debug("received report_request from channel ~p uuid ~p ~p", [ChannelName, UUID, Report]),

    ChannelInfo = #{
        id => router_channel:id(Channel),
        name => ChannelName
    },

    Description =
        case maps:get(status, Report) of
            success ->
                io_lib:format("Request sent to ~p", [ChannelName]);
            error ->
                maps:get(description, Report, <<"Error">>);
            no_channel ->
                "No Channel Configured"
        end,

    ok = router_utils:event_uplink_integration_req(
        UUID,
        Device,
        maps:get(status, Report),
        router_utils:to_bin(Description),
        maps:get(request, Report),
        ChannelInfo
    ),
    {noreply, State};
handle_cast({report_response, UUID, Channel, Report}, #state{device = Device} = State) ->
    ChannelName = router_channel:name(Channel),
    lager:debug("received report_response from channel ~p uuid ~p ~p", [ChannelName, UUID, Report]),

    ChannelInfo = #{
        id => router_channel:id(Channel),
        name => ChannelName
    },
    Description =
        case maps:get(status, Report) of
            success ->
                io_lib:format("Response received from ~p", [ChannelName]);
            error ->
                maps:get(description, Report, <<"Error">>);
            no_channel ->
                "No Channel Configured"
        end,

    case maps:get(status, Report) of
        no_channel ->
            noop;
        Status ->
            router_utils:event_uplink_integration_res(
                UUID,
                Device,
                Status,
                router_utils:to_bin(Description),
                maps:get(response, Report),
                ChannelInfo
            )
    end,

    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Channel Handling
%% ------------------------------------------------------------------
handle_info(
    refresh_channels,
    #state{event_mgr = EventMgrRef, device = Device, channels = Channels0} = State
) ->
    APIChannels = lists:foldl(
        fun(Channel, Acc) ->
            ID = router_channel:unique_id(Channel),
            maps:put(ID, Channel, Acc)
        end,
        #{},
        router_console_api:get_channels(Device, self())
    ),
    Channels1 =
        case maps:size(APIChannels) == 0 of
            true ->
                %% API returned no channels removing all of them and adding the "no channel"
                lists:foreach(
                    fun
                        ({router_no_channel, <<"no_channel">>}) -> ok;
                        (Handler) -> gen_event:delete_handler(EventMgrRef, Handler, [])
                    end,
                    gen_event:which_handlers(EventMgrRef)
                ),
                NoChannel = maybe_start_no_channel(Device, EventMgrRef),
                #{router_channel:unique_id(NoChannel) => NoChannel};
            false ->
                %% Start channels asynchronously
                lists:foreach(
                    fun(Channel) -> self() ! {start_channel, Channel} end,
                    maps:values(APIChannels)
                ),
                %% Removing old channels left in cache but not in API call
                remove_old_channels(EventMgrRef, APIChannels, Channels0)
        end,
    {noreply, State#state{channels = Channels1}};
handle_info(
    {start_channel, Channel},
    #state{
        device = Device,
        event_mgr = EventMgrRef,
        channels = Channels,
        channels_backoffs = Backoffs0
    } = State
) ->
    ChannelID = router_channel:unique_id(Channel),
    ChannelState =
        case maps:get(ChannelID, Channels, undefined) of
            undefined ->
                missing;
            CachedChan ->
                case router_channel:hash(CachedChan) == router_channel:hash(Channel) of
                    true -> exists;
                    false -> stale
                end
        end,
    State1 =
        case ChannelState of
            missing ->
                lager:info("starting channel ~p", [ChannelID]),
                case start_channel(EventMgrRef, Channel, Device, Backoffs0) of
                    {ok, Backoffs1} ->
                        State#state{
                            channels = maps:put(ChannelID, Channel, Channels),
                            channels_backoffs = Backoffs1
                        };
                    {error, _Reason, Backoffs1} ->
                        State#state{channels_backoffs = Backoffs1}
                end;
            stale ->
                lager:info("updating channel ~p", [ChannelID]),
                case update_channel(EventMgrRef, Channel, Device, Backoffs0) of
                    {ok, Backoffs1} ->
                        State#state{
                            channels = maps:put(ChannelID, Channel, Channels),
                            channels_backoffs = Backoffs1
                        };
                    {error, _Reason, Backoffs1} ->
                        State#state{
                            channels = maps:remove(ChannelID, Channels),
                            channels_backoffs = Backoffs1
                        }
                end;
            exists ->
                lager:info("channel ~p already started", [ChannelID]),
                State
        end,
    {noreply, State1};
handle_info(
    {gen_event_EXIT, {_Handler, ChannelID}, ExitReason},
    #state{
        device = Device,
        channels = Channels,
        event_mgr = EventMgrRef,
        channels_backoffs = Backoffs0
    } = State
) ->
    case ExitReason of
        {swapped, _NewHandler, _Pid} ->
            lager:info("channel ~p got swapped ~p", [ChannelID, {_NewHandler, _Pid}]),
            {noreply, State};
        R when R == normal orelse R == shutdown ->
            lager:info("channel ~p went down normally", [ChannelID]),
            {noreply, State#state{
                channels = maps:remove(ChannelID, Channels),
                channels_backoffs = maps:remove(ChannelID, Backoffs0)
            }};
        Error ->
            case maps:get(ChannelID, Channels, undefined) of
                undefined ->
                    lager:error("unknown channel ~p went down: ~p", [ChannelID, Error]),
                    {noreply, State#state{
                        channels = maps:remove(ChannelID, Channels),
                        channels_backoffs = maps:remove(ChannelID, Backoffs0)
                    }};
                Channel ->
                    Description = io_lib:format("channel_crash: ~p", [Error]),
                    ok = report_integration_error(Device, Description, Channel),
                    ChannelName = router_channel:name(Channel),
                    lager:error("channel ~p crashed: ~p", [{ChannelID, ChannelName}, Error]),
                    case start_channel(EventMgrRef, Channel, Device, Backoffs0) of
                        {ok, Backoffs1} ->
                            {noreply, State#state{
                                channels = maps:put(ChannelID, Channel, Channels),
                                channels_backoffs = Backoffs1
                            }};
                        {error, _Reason, Backoffs1} ->
                            {noreply, State#state{
                                channels = maps:remove(ChannelID, Channels),
                                channels_backoffs = Backoffs1
                            }}
                    end
            end
    end;
handle_info(
    {'DOWN', _MonitorRef, process, Pid, Info},
    #state{device_worker = Pid} = State
) ->
    lager:info("device worker ~p went down (~p) shutting down also", [Pid, Info]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    lager:info("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec maybe_report_downlink_dropped(
    DeviceID :: binary(),
    Desc :: string(),
    Channel :: router_channel:channel()
) -> ok.
maybe_report_downlink_dropped(DeviceID, Desc, Channel) ->
    case router_device_cache:get(DeviceID) of
        {ok, Device} ->
            ok = router_utils:event_downlink_dropped_misc(
                erlang:list_to_binary(Desc),
                Device,
                router_channel:to_map(Channel)
            );
        {error, not_found} ->
            lager:info([{device_id, DeviceID}], "failed to get device ~p from cache", [DeviceID])
    end.

-spec downlink_decode(binary() | map()) ->
    {ok, {boolean(), integer(), binary()} | clear_queue} | {error, any()}.
downlink_decode(BinaryPayload) when is_binary(BinaryPayload) ->
    try jsx:decode(BinaryPayload, [return_maps]) of
        JSON -> downlink_decode(JSON)
    catch
        _:_ ->
            {error, {failed_to_decode_json, BinaryPayload}}
    end;
downlink_decode(MapPayload) when is_map(MapPayload) ->
    case maps:find(<<"payload_raw">>, MapPayload) of
        {ok, Payload} ->
            Port =
                case maps:find(<<"port">>, MapPayload) of
                    {ok, X} when is_integer(X), X > 0, X < 224 ->
                        X;
                    _ ->
                        1
                end,
            Confirmed =
                case maps:find(<<"confirmed">>, MapPayload) of
                    {ok, true} ->
                        true;
                    _ ->
                        false
                end,
            try base64:decode(Payload) of
                ?CLEAR_QUEUE_PAYLOAD ->
                    {ok, clear_queue};
                Decoded ->
                    {ok, {Confirmed, Port, Decoded}}
            catch
                _:_ ->
                    {error, failed_to_decode_base64}
            end;
        error ->
            {error, payload_raw_not_found}
    end;
downlink_decode(Payload) ->
    {error, {not_binary_or_map, Payload}}.

-spec send_join_to_channel(
    JoinCache :: #join_cache{},
    Device :: router_device:device(),
    EventMgrRef :: pid(),
    Blockchain :: blockchain:blockchain()
) -> {ok, map()}.
send_join_to_channel(
    #join_cache{
        uuid = UUID,
        packet_selected = {_Packet0, _PubKeyBin, _Region, PacketTime, _HoldTime} = SelectedPacket,
        packets = CollectedPackets
    },
    Device,
    EventMgrRef,
    Blockchain
) ->
    FormatHotspot = fun({Packet, PubKeyBin, Region, Time, HoldTime}) ->
        format_hotspot(PubKeyBin, Packet, Region, Time, HoldTime, Blockchain)
    end,

    %% No touchy, this is set in STONE
    Map = #{
        %% TODO: How do we tell integrations the difference between joins and frames?
        %% type => join,
        uuid => UUID,
        id => router_device:id(Device),
        name => router_device:name(Device),
        dev_eui => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
        app_eui => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
        metadata => router_device:metadata(Device),
        fcnt => 0,
        reported_at => PacketTime,
        port => 0,
        %% REVIEW: Do we want to fill the assigned devaddr here?
        devaddr => <<>>,
        hotspots => lists:map(FormatHotspot, [SelectedPacket | CollectedPackets])
    },
    ok = router_channel:handle_join(EventMgrRef, Map, UUID),
    {ok, Map}.

-spec send_data_to_channel(
    CachedData0 :: #{libp2p_crypto:pubkey_bin() => #data_cache{}},
    Device :: router_device:device(),
    EventMgrRef :: pid(),
    Blockchain :: blockchain:blockchain()
) -> {ok, map()}.
send_data_to_channel(CachedData0, Device, EventMgrRef, Blockchain) ->
    FormatHotspot = fun(DataCache) ->
        format_hotspot(DataCache, Blockchain)
    end,
    CachedData1 = lists:sort(
        fun(A, B) -> A#data_cache.time < B#data_cache.time end,
        maps:values(CachedData0)
    ),
    [#data_cache{frame = Frame, time = Time, uuid = UUID} | _] = CachedData1,
    #frame{data = Payload, fport = Port, fcnt = FCnt, devaddr = DevAddr} = Frame,
    %% No touchy, this is set in STONE
    Map = #{
        uuid => UUID,
        id => router_device:id(Device),
        name => router_device:name(Device),
        dev_eui => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
        app_eui => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
        metadata => router_device:metadata(Device),
        fcnt => FCnt,
        reported_at => Time,
        payload => Payload,
        payload_size => erlang:byte_size(Payload),
        port =>
            case Port of
                undefined -> 0;
                _ -> Port
            end,
        devaddr => lorawan_utils:binary_to_hex(DevAddr),
        hotspots => lists:map(FormatHotspot, CachedData1)
    },
    ok = router_channel:handle_data(EventMgrRef, Map, UUID),
    {ok, Map}.

-spec start_channel(pid(), router_channel:channel(), router_device:device(), map()) ->
    {ok, map()} | {error, any(), map()}.
start_channel(EventMgrRef, Channel, Device, Backoffs0) ->
    ChannelID = router_channel:unique_id(Channel),
    ChannelName = router_channel:name(Channel),
    case router_channel:add(EventMgrRef, Channel, Device) of
        ok ->
            lager:info("channel ~p started", [{ChannelID, ChannelName}]),
            ok = maybe_start_decoder(Channel),
            Backoffs1 = backoff_succeed(ChannelID, Backoffs0),
            {ok, Backoffs1};
        {E, Reason} when E == 'EXIT'; E == error ->
            Description = io_lib:format("channel_start_error: ~p ~p", [E, Reason]),
            ok = report_integration_error(Device, Description, Channel),
            {Delay, Backoffs1} = backoff_fail(ChannelID, Backoffs0, {start_channel, Channel}),
            lager:error("failed to start channel ~p: ~p, retrying in ~pms", [
                {ChannelID, ChannelName},
                {E, Reason},
                Delay
            ]),
            {error, Reason, Backoffs1}
    end.

-spec update_channel(pid(), router_channel:channel(), router_device:device(), map()) ->
    {ok, map()} | {error, any(), map()}.
update_channel(EventMgrRef, Channel, Device, Backoffs0) ->
    ChannelID = router_channel:unique_id(Channel),
    ChannelName = router_channel:name(Channel),
    case router_channel:update(EventMgrRef, Channel, Device) of
        ok ->
            lager:info("channel ~p updated", [{ChannelID, ChannelName}]),
            ok = maybe_start_decoder(Channel),
            Backoffs1 = backoff_succeed(ChannelID, Backoffs0),
            {ok, Backoffs1};
        {E, Reason} when E == 'EXIT'; E == error ->
            Description = io_lib:format("update_channel_failure: ~p ~p", [E, Reason]),
            ok = report_integration_error(Device, Description, Channel),
            {Delay, Backoffs1} = backoff_fail(ChannelID, Backoffs0, {start_channel, Channel}),
            lager:error("failed to update channel ~p: ~p, retrying in ~pms", [
                {ChannelID, ChannelName},
                {E, Reason},
                Delay
            ]),
            {error, Reason, Backoffs1}
    end.

-spec maybe_start_decoder(router_channel:channel()) -> ok.
maybe_start_decoder(Channel) ->
    case router_channel:decoder(Channel) of
        undefined ->
            lager:debug("no decoder attached");
        Decoder ->
            ChannelID = router_channel:unique_id(Channel),
            DecoderID = router_decoder:id(Decoder),
            case router_decoder:add(Decoder) of
                ok ->
                    lager:info("decoder ~p attached to ~p", [DecoderID, ChannelID]);
                {error, _Reason} ->
                    lager:error("failed to attached decoder ~p to ~p: ~p", [
                        DecoderID,
                        ChannelID,
                        _Reason
                    ])
            end
    end.

-spec remove_old_channels(pid(), map(), map()) -> map().
remove_old_channels(EventMgrRef, APIChannels, Channels) ->
    maps:filter(
        fun(ChannelID, Channel) ->
            case maps:get(ChannelID, APIChannels, undefined) of
                undefined ->
                    ok = router_channel:delete(EventMgrRef, Channel),
                    false;
                _ ->
                    true
            end
        end,
        Channels
    ).

-spec maybe_start_no_channel(router_device:device(), pid()) -> router_channel:channel().
maybe_start_no_channel(Device, EventMgrRef) ->
    Handlers = gen_event:which_handlers(EventMgrRef),
    NoChannel = router_channel:new(
        <<"no_channel">>,
        router_no_channel,
        <<"no_channel">>,
        #{},
        router_device:id(Device),
        self()
    ),
    case lists:keyfind(router_no_channel, 1, Handlers) of
        {router_no_channel, _} -> noop;
        _ -> router_channel:add(EventMgrRef, NoChannel, Device)
    end,
    NoChannel.

-spec report_integration_error(router_device:device(), string(), router_channel:channel()) -> ok.
report_integration_error(Device, Description, Channel) ->
    ChannelInfo = #{
        id => router_channel:id(Channel),
        name => router_channel:name(Channel),
        status => error
    },
    ok = router_utils:event_misc_integration_error(
        Device,
        erlang:list_to_binary(Description),
        ChannelInfo
    ).

-spec backoff_succeed(binary(), map()) -> map().
backoff_succeed(ChannelID, Backoffs0) ->
    {Backoff, TimerRef} = maps:get(ChannelID, Backoffs0, ?BACKOFF_INIT),
    _ = erlang:cancel_timer(TimerRef),
    {_Delay, NewBackoff} = backoff:succeed(Backoff),
    maps:put(ChannelID, {NewBackoff, erlang:make_ref()}, Backoffs0).

-spec backoff_fail(binary(), map(), tuple()) -> {integer(), map()}.
backoff_fail(ChannelID, Backoffs0, ScheduleMessage) ->
    {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs0, ?BACKOFF_INIT),
    _ = erlang:cancel_timer(TimerRef0),
    {Delay, NewBackoff} = backoff:fail(Backoff0),
    TimerRef = erlang:send_after(Delay, self(), ScheduleMessage),
    {Delay, maps:put(ChannelID, {NewBackoff, TimerRef}, Backoffs0)}.

-spec format_hotspot(
    DataCache :: #data_cache{},
    Chain :: blockchain:blockchain()
) -> map().
format_hotspot(
    #data_cache{
        pubkey_bin = PubKeyBin,
        packet = Packet,
        region = Region,
        time = Time,
        hold_time = HoldTime
    },
    Chain
) ->
    format_hotspot(PubKeyBin, Packet, Region, Time, HoldTime, Chain).

-spec format_hotspot(
    PubKeyBin :: libp2p_crypto:pubkey_bin(),
    Packet :: #packet_pb{},
    Region :: atom(),
    Time :: non_neg_integer(),
    HoldTime :: non_neg_integer(),
    Chain :: blockchain:blockchain()
) -> map().
format_hotspot(PubKeyBin, Packet, Region, Time, HoldTime, Chain) ->
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
    HotspotName = blockchain_utils:addr2name(PubKeyBin),
    Freq = blockchain_helium_packet_v1:frequency(Packet),
    {Lat, Long} = router_utils:get_hotspot_location(PubKeyBin, Chain),
    #{
        id => erlang:list_to_binary(B58),
        name => erlang:list_to_binary(HotspotName),
        reported_at => Time,
        status => <<"success">>,
        rssi => blockchain_helium_packet_v1:signal_strength(Packet),
        snr => blockchain_helium_packet_v1:snr(Packet),
        spreading => erlang:list_to_binary(blockchain_helium_packet_v1:datarate(Packet)),
        frequency => Freq,
        channel => lorawan_mac_region:freq_to_chan(Region, Freq),
        lat => Lat,
        long => Long,
        hold_time => HoldTime
    }.
