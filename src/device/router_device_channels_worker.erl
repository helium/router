%%%-------------------------------------------------------------------
%% @doc
%% == Router Device Channels Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_device_channels_worker).

-behavior(gen_server).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include("device_worker.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         handle_join/1,
         handle_device_update/2,
         handle_data/3,
         report_status/3,
         handle_downlink/2,
         state/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(BACKOFF_MIN, timer:seconds(15)).
-define(BACKOFF_MAX, timer:minutes(5)).
-define(BACKOFF_INIT,
        {backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
         erlang:make_ref()}).
-define(DATA_TIMEOUT, timer:seconds(1)).
-define(CHANNELS_RESP_TIMEOUT, timer:seconds(3)).

-record(state, {chain=blockchain:blockchain(),
                event_mgr :: pid(),
                device_worker :: pid(),
                device :: router_device:device(),
                channels = #{} :: map(),
                channels_backoffs = #{} :: map(),
                data_cache = #{} :: map(),
                fcnt :: integer(),
                channels_resp_cache = #{} :: map()}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec handle_join(pid()) -> ok.
handle_join(Pid) ->
    gen_server:cast(Pid, handle_join).

-spec state(Pid :: pid()) -> state().
state(Pid) ->
    gen_server:call(Pid, state, infinity).

-spec handle_device_update(pid(), router_device:device()) -> ok.
handle_device_update(Pid, Device) ->
    gen_server:cast(Pid, {handle_device_update, Device}).

-spec handle_data(pid(), router_device:device(), {libp2p_crypto:pubkey_bin(), #packet_pb{}, #frame{}, integer()}) -> ok.
handle_data(Pid, Device, Data) ->
    gen_server:cast(Pid, {handle_data, Device, Data}).

-spec report_status(pid(), reference(), map()) -> ok.
report_status(Pid, Ref, Map) ->
    gen_server:cast(Pid, {report_status, Ref, Map}).

-spec handle_downlink(pid() | binary(), binary()) -> ok.
handle_downlink(Pid, BinaryPayload) when is_pid(Pid) ->
    case downlink_decode(BinaryPayload) of
        {ok, Msg} ->
            gen_server:cast(Pid, {handle_downlink, Msg});
        {error, _Reason} ->
            lager:info("could not parse json downlink message ~p", [_Reason])
    end;
handle_downlink(DeviceID, BinaryPayload) when is_binary(DeviceID) ->
    case router_devices_sup:lookup_device_worker(DeviceID) of
        {error, _Reason} ->
            lager:info("failed to find device ~p: ~p", [DeviceID, _Reason]);
        {ok, Pid} ->
            case downlink_decode(BinaryPayload) of
                {ok, Msg} ->
                    router_device_worker:queue_message(Pid, Msg);
                {error, _Reason} ->
                    lager:info("could not parse json downlink message ~p", [_Reason])
            end
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Blockchain = maps:get(blockchain, Args),
    DeviceWorker = maps:get(device_worker, Args),
    Device = maps:get(device, Args),
    lager:md([{device_id, router_device:id(Device)}]),
    {ok, EventMgrRef} = router_channel:start_link(),
    self() ! refresh_channels,
    {ok, #state{chain=Blockchain, event_mgr=EventMgrRef, device_worker=DeviceWorker, device=Device, fcnt=-1}}.

handle_call(state, _From, State) ->
    {reply, State, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(handle_join, State) ->
    {noreply, State#state{fcnt=-1}};
handle_cast({handle_device_update, Device}, State) ->
    {noreply, State#state{device=Device}};
handle_cast({handle_data, Device, {PubKeyBin, Packet, _Frame, _Time}=Data}, #state{data_cache=DataCache0, fcnt=CurrFCnt}=State) ->
    FCnt = router_device:fcnt(Device),
    DataCache1 =
        case FCnt =< CurrFCnt of
            true ->
                lager:debug("we received a late packet ~p from ~p: ~p", [{FCnt, CurrFCnt}, PubKeyBin, Packet]),
                DataCache0;
            false ->
                case maps:get(FCnt, DataCache0, undefined) of
                    undefined ->
                        _ = erlang:send_after(?DATA_TIMEOUT, self(), {data_timeout, FCnt}),
                        maps:put(FCnt, #{PubKeyBin => Data}, DataCache0);
                    CachedData0 ->
                        CachedData1 = maps:put(PubKeyBin, Data, CachedData0),
                        case maps:get(PubKeyBin, CachedData0, undefined) of
                            undefined ->
                                maps:put(FCnt, CachedData1, DataCache0);
                            {_, #packet_pb{signal_strength=RSSI}, _, _} ->
                                case Packet#packet_pb.signal_strength > RSSI of
                                    true -> maps:put(FCnt, CachedData1, DataCache0);
                                    false -> DataCache0
                                end
                        end
                end
        end,
    {noreply, State#state{device=Device, data_cache=DataCache1}};
handle_cast({handle_downlink, Msg}, #state{device_worker=DeviceWorker}=State) ->
    ok = router_device_worker:queue_message(DeviceWorker, Msg),
    {noreply, State};
handle_cast({report_status, FCnt, Report}, #state{channels_resp_cache=Cache0}=State) ->
    lager:debug("received report_status ~p ~p", [FCnt, Report]),
    Cache1 =
        case maps:get(FCnt, Cache0, undefined) of
            undefined ->
                lager:warning("received report_status ~p too late ignoring ~p", [FCnt, Report]),
                Cache0;
            {Data, CachedReports} ->
                maps:put(FCnt, {Data, [Report|CachedReports]}, Cache0)
        end,
    {noreply, State#state{channels_resp_cache=Cache1}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Data Handling
%% ------------------------------------------------------------------
handle_info({data_timeout, FCnt}, #state{chain=Blockchain, event_mgr=EventMgrRef, device=Device,
                                         data_cache=DataCache0, channels_resp_cache=RespCache0}=State) ->
    CachedData = maps:values(maps:get(FCnt, DataCache0)),
    {ok, Map} = send_to_channel(CachedData, Device, EventMgrRef, Blockchain),
     lager:debug("data_timeout for ~p data: ~p", [FCnt, Map]),
    _ = erlang:send_after(?CHANNELS_RESP_TIMEOUT, self(), {report_status_timeout, FCnt}),
    {noreply, State#state{data_cache=maps:remove(FCnt, DataCache0),
                          fcnt=FCnt,
                          channels_resp_cache=maps:put(FCnt, {Map, []}, RespCache0)}};
%% ------------------------------------------------------------------
%% Channel Handling
%% ------------------------------------------------------------------
handle_info({report_status_timeout, FCnt}, #state{device=Device, channels_resp_cache=Cache0}=State) ->
    lager:debug("report_status_timeout for ~p", [FCnt]),
    {Data, CachedReports} = maps:get(FCnt, Cache0),
    Payload = maps:get(payload, Data),
    ReportsMap = #{category => <<"up">>,
                   description => <<"Channels report">>,
                   reported_at => erlang:system_time(seconds),
                   payload => base64:encode(Payload),
                   payload_size => erlang:byte_size(Payload),
                   port => maps:get(port, Data),
                   devaddr => maps:get(devaddr, Data),
                   hotspots => maps:get(hotspots, Data),
                   channels => CachedReports,
                   fcnt => maps:get(fcnt, Data)},
    ok = router_device_api:report_status(Device, ReportsMap),
    {noreply, State#state{channels_resp_cache=maps:remove(FCnt, Cache0)}};
handle_info(refresh_channels, #state{event_mgr=EventMgrRef, device=Device, channels=Channels0}=State) ->
    APIChannels = lists:foldl(
                    fun(Channel, Acc) ->
                            ID = router_channel:unique_id(Channel),
                            maps:put(ID, Channel, Acc)
                    end,
                    #{},
                    router_device_api:get_channels(Device, self())),
    Channels1 =
        case maps:size(APIChannels) == 0 of
            true ->
                %% API returned no channels removing all of them and adding the "no channel"
                lists:foreach(
                  fun({router_no_channel, <<"no_channel">>}) -> ok;
                     (Handler) -> gen_event:delete_handler(EventMgrRef, Handler, [])
                  end,
                  gen_event:which_handlers(EventMgrRef)),
                NoChannel = maybe_start_no_channel(Device, EventMgrRef),
                #{router_channel:unique_id(NoChannel) => NoChannel};
            false ->
                %% Start channels asynchronously 
                lists:foreach(
                  fun(Channel) -> self() ! {start_channel, Channel} end,
                  maps:values(APIChannels)),
                %% Removing old channels left in cache but not in API call
                remove_old_channels(EventMgrRef, APIChannels, Channels0)

        end,
    {noreply, State#state{channels=Channels1}};
handle_info({start_channel, Channel}, #state{device=Device, event_mgr=EventMgrRef,
                                             channels=Channels, channels_backoffs=Backoffs0}=State) ->
    ChannelID = router_channel:unique_id(Channel),
    case maps:get(ChannelID, Channels, undefined) of
        undefined ->
            case start_channel(EventMgrRef, Channel, Device, Backoffs0) of
                {ok, Backoffs1} ->
                    {noreply, State#state{channels=maps:put(ChannelID, Channel, Channels),
                                          channels_backoffs=Backoffs1}};
                {error, _Reason, Backoffs1} ->
                    {noreply, State#state{channels_backoffs=Backoffs1}}
            end;
        CachedChannel ->
            ChannelHash = router_channel:hash(Channel),
            case router_channel:hash(CachedChannel) of
                ChannelHash ->
                    lager:info("channel ~p already started", [ChannelID]),
                    {noreply, State};
                _OldHash ->
                    lager:info("updating channel ~p", [ChannelID]),
                    case update_channel(EventMgrRef, Channel, Device, Backoffs0) of  
                        {ok, Backoffs1} ->
                            lager:info("channel ~p updated", [ChannelID]),
                            {noreply, State#state{channels=maps:put(ChannelID, Channel, Channels),
                                                  channels_backoffs=Backoffs1}};
                        {error, _Reason, Backoffs1} ->
                            {noreply, State#state{channels=maps:remove(ChannelID, Channels),
                                                  channels_backoffs=Backoffs1}}
                    end
            end
    end;
handle_info({gen_event_EXIT, {_Handler, ChannelID}, ExitReason}, #state{device=Device, channels=Channels,
                                                                        event_mgr=EventMgrRef,
                                                                        channels_backoffs=Backoffs0}=State) ->
    case ExitReason of
        {swapped, _NewHandler, _Pid} ->
            lager:info("channel ~p got swapped ~p", [ChannelID, {_NewHandler, _Pid}]),
            {noreply, State};
        R when R == normal orelse R == shutdown ->
            lager:info("channel ~p went down normally", [ChannelID]),
            {noreply, State#state{channels=maps:remove(ChannelID, Channels),
                                  channels_backoffs=maps:remove(ChannelID, Backoffs0)}};
        Error ->
            case maps:get(ChannelID, Channels, undefined) of
                undefined ->
                    lager:error("unknown channel ~p went down", [ChannelID]),
                    {noreply, State#state{channels=maps:remove(ChannelID, Channels),
                                          channels_backoffs=maps:remove(ChannelID, Backoffs0)}};
                Channel -> 
                    ChannelName = router_channel:name(Channel),
                    lager:error("channel ~p crashed: ~p", [{ChannelID, ChannelName}, Error]),
                    Desc = erlang:list_to_binary(io_lib:format("~p", [Error])),
                    Report = #{category => <<"channel_crash">>,
                               description => Desc,
                               reported_at => erlang:system_time(seconds),
                               payload => <<>>,
                               payload_size => 0,
                               port => 0,
                               devaddr => <<>>,
                               hotspots => [],
                               channels => [#{id => ChannelID,
                                              name => ChannelName,
                                              reported_at => erlang:system_time(seconds),
                                              status => <<"error">>,
                                              description => Desc}]},
                    router_device_api:report_status(Device, Report),
                    case start_channel(EventMgrRef, Channel, Device, Backoffs0) of  
                        {ok, Backoffs1} ->
                            {noreply, State#state{channels=maps:put(ChannelID, Channel, Channels),
                                                  channels_backoffs=Backoffs1}};
                        {error, _Reason, Backoffs1} ->
                            {noreply, State#state{channels=maps:remove(ChannelID, Channels),
                                                  channels_backoffs=Backoffs1}}
                    end
            end
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec downlink_decode(binary() | map()) -> {ok, {boolean(), integer(), binary()}} | {error, any()}.
downlink_decode(BinaryPayload) when is_binary(BinaryPayload) ->
    try jsx:decode(BinaryPayload, [return_maps]) of
        JSON -> downlink_decode(JSON)
    catch
        _:_ ->
            {error, failed_to_decode_json}
    end;
downlink_decode(MapPayload) when is_map(MapPayload) ->
    case maps:find(<<"payload_raw">>, MapPayload) of
        {ok, Payload} ->
            Port = case maps:find(<<"port">>, MapPayload) of
                       {ok, X} when is_integer(X), X > 0, X < 224 ->
                           X;
                       _ ->
                           1
                   end,
            Confirmed = case maps:find(<<"confirmed">>, MapPayload) of
                            {ok, true} ->
                                true;
                            _ ->
                                false
                        end,
            try base64:decode(Payload) of
                Decoded ->
                    {ok, {Confirmed, Port, Decoded}}
            catch
                _:_ ->
                    {error, failed_to_decode_base64}
            end;
        error ->
            {error, payload_raw_not_found}
    end.

-spec send_to_channel([{string(), #packet_pb{}, #frame{}}], router_device:device(),
                      pid() , blockchain:blockchain()) -> {ok, map()}.
send_to_channel(CachedData, Device, EventMgrRef, Blockchain) ->
    FoldFun =
        fun({PubKeyBin, Packet, _, Time}, Acc) ->
                B58 = libp2p_crypto:bin_to_b58(PubKeyBin),
                {ok, HotspotName} = erl_angry_purple_tiger:animal_name(B58),
                Freq = Packet#packet_pb.frequency,
                {Lat, Long} = router_utils:get_hotspot_location(PubKeyBin, Blockchain),
                [#{id => erlang:list_to_binary(B58),
                   name => erlang:list_to_binary(HotspotName),
                   reported_at => Time,
                   status => <<"success">>,
                   rssi => Packet#packet_pb.signal_strength,
                   snr => Packet#packet_pb.snr,
                   spreading => erlang:list_to_binary(Packet#packet_pb.datarate),
                   frequency => Freq,
                   %% TODO use correct regulatory domain here
                   channel => lorawan_mac_region:f2uch('US915', Freq),
                   lat => Lat,
                   long => Long}|Acc]
        end,
    [{_, _, #frame{data=Data, fport=Port, fcnt=FCnt, devaddr=DevAddr}, Time}|_] = CachedData,
    Map = #{id => router_device:id(Device),
            name => router_device:name(Device),
            dev_eui => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
            app_eui => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
            metadata => router_device:metadata(Device),
            fcnt => FCnt,
            reported_at => Time,
            payload => Data,
            port => Port,
            devaddr => lorawan_utils:binary_to_hex(DevAddr),
            hotspots => lists:foldr(FoldFun, [], CachedData)},
    ok = router_channel:handle_data(EventMgrRef, Map, FCnt),
    {ok, Map}.

-spec start_channel(pid(), router_channel:channel(), router_device:device(), map()) -> {ok, map()} | {error, any(), map()}.
start_channel(EventMgrRef, Channel, Device, Backoffs) ->
    ChannelID = router_channel:unique_id(Channel),
    ChannelName = router_channel:name(Channel),
    case router_channel:add(EventMgrRef, Channel, Device) of
        ok ->
            lager:info("channel ~p started", [{ChannelID, ChannelName}]),
            ok = maybe_start_decoder(Channel),
            {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs, ?BACKOFF_INIT),
            _ = erlang:cancel_timer(TimerRef0),
            {_Delay, Backoff1} = backoff:succeed(Backoff0),
            {ok, maps:put(ChannelID, {Backoff1, erlang:make_ref()}, Backoffs)};
        {E, Reason} when E == 'EXIT'; E == error ->
            Desc = erlang:list_to_binary(io_lib:format("~p ~p", [E, Reason])),
            Report = #{category => <<"channel_start_error">>,
                       description => Desc,
                       reported_at => erlang:system_time(seconds),
                       payload => <<>>,
                       payload_size => 0,
                       port => 0,
                       devaddr => <<>>,
                       hotspots => [],
                       channels => [#{id => ChannelID,
                                      name => ChannelName,
                                      reported_at => erlang:system_time(seconds),
                                      status => <<"error">>,
                                      description => Desc}]},
            router_device_api:report_status(Device, Report),
            {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs, ?BACKOFF_INIT),
            _ = erlang:cancel_timer(TimerRef0),
            {Delay, Backoff1} = backoff:fail(Backoff0),
            TimerRef1 = erlang:send_after(Delay, self(), {start_channel, Channel}),
            lager:error("failed to start channel ~p: ~p, retrying in ~pms", [{ChannelID, ChannelName}, {E, Reason}, Delay]),
            {error, Reason, maps:put(ChannelID, {Backoff1, TimerRef1}, Backoffs)}
    end.

-spec update_channel(pid(), router_channel:channel(), router_device:device(), map()) -> {ok, map()} | {error, any(), map()}.
update_channel(EventMgrRef, Channel, Device, Backoffs) ->
    ChannelID = router_channel:unique_id(Channel),
    ChannelName = router_channel:name(Channel),
    case router_channel:update(EventMgrRef, Channel, Device) of
        ok ->
            lager:info("channel ~p updated", [{ChannelID, ChannelName}]),
            ok = maybe_start_decoder(Channel),
            {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs, ?BACKOFF_INIT),
            _ = erlang:cancel_timer(TimerRef0),
            {_Delay, Backoff1} = backoff:succeed(Backoff0),
            {ok, maps:put(ChannelID, {Backoff1, erlang:make_ref()}, Backoffs)};
        {E, Reason} when E == 'EXIT'; E == error ->
            lager:error("failed to update channel ~p: ~p", [{ChannelID, ChannelName}, {E, Reason}]),
            Desc = erlang:list_to_binary(io_lib:format("~p ~p", [E, Reason])),
            Report = #{category => <<"update_channel_failure">>,
                       description => Desc,
                       reported_at => erlang:system_time(seconds),
                       payload => <<>>,
                       payload_size => 0,
                       hotspots => [],
                       channels => [#{id => ChannelID,
                                      name => ChannelName,
                                      reported_at => erlang:system_time(seconds),
                                      status => <<"error">>,
                                      description => Desc}]},
            router_device_api:report_status(Device, Report),
            {Backoff0, TimerRef0} = maps:get(ChannelID, Backoffs, ?BACKOFF_INIT),
            _ = erlang:cancel_timer(TimerRef0),
            {Delay, Backoff1} = backoff:fail(Backoff0),
            TimerRef1 = erlang:send_after(Delay, self(), {start_channel, Channel}),
            {error, Reason, maps:put(ChannelID, {Backoff1, TimerRef1}, Backoffs)}
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
                    lager:error("failed to attached decoder ~p to ~p: ~p", [DecoderID, ChannelID, _Reason])
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
      Channels).

-spec maybe_start_no_channel(router_device:device(), pid()) -> router_channel:channel().
maybe_start_no_channel(Device, EventMgrRef) ->
    Handlers = gen_event:which_handlers(EventMgrRef),
    NoChannel = router_channel:new(<<"no_channel">>,
                                   router_no_channel,
                                   <<"no_channel">>,
                                   #{},
                                   router_device:id(Device),
                                   self()),
    case lists:keyfind(router_no_channel, 1, Handlers) of
        {router_no_channel, _} -> noop;
        _ -> router_channel:add(EventMgrRef, NoChannel, Device)
    end,
    NoChannel.
