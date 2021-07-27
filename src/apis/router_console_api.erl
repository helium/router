%%%-------------------------------------------------------------------
%% @doc
%% == Router Console API ==
%% @end
%%%-------------------------------------------------------------------
-module(router_console_api).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    get_device/1,
    get_devices_by_deveui_appeui/2,
    get_all_devices/0,
    get_channels/2,
    event/2,
    get_downlink_url/2,
    get_org/1,
    organizations_burned/3,
    get_token/0,
    json_device_to_record/2,
    xor_filter_updates/2
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
-define(POOL, router_console_api_pool).
-define(ETS, router_console_api_ets).
-define(TOKEN_CACHE_TIME, timer:hours(23)).
-define(TICK_INTERVAL, 1000).
-define(TICK, '__router_console_api_tick').
-define(PENDING_KEY, <<"router_console_api.PENDING_KEY">>).
-define(HEADER_JSON, {<<"Content-Type">>, <<"application/json">>}).
-define(DOWNLINK_TOOL_ORIGIN, <<"console_downlink_queue">>).
-define(DOWNLINK_TOOL_CHANNEL_NAME, <<"Console downlink tool">>).

-define(GET_ORG_CACHE_NAME, router_console_api_get_org).
-define(GET_DEVICES_CACHE_NAME, router_console_api_get_devices_by_deveui_appeui).
%% E2QC durations are in seconds while our eviction handling is milliseconds
-define(GET_ORG_LIFETIME, 300).
-define(GET_DEVICES_LIFETIME, 10).
-define(GET_ORG_EVICTION_TIMEOUT, timer:seconds(10)).

-type request_body() :: maps:map().
-type pending() :: #{router_utils:uuid_v4() => request_body()}.
-type inflight() :: {router_utils:uuid_v4(), pid()}.

-record(state, {
    endpoint :: binary(),
    secret :: binary(),
    token :: binary(),
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle(),
    pending_burns = #{} :: pending(),
    inflight = [] :: [inflight()],
    tref :: reference()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec get_device(DeviceID :: binary()) -> {ok, router_device:device()} | {error, any()}.
get_device(DeviceID) ->
    {Endpoint, Token} = token_lookup(),
    Device = router_device:new(DeviceID),
    case get_device_(Endpoint, Token, Device) of
        {error, _Reason} = Error ->
            Error;
        {ok, JSONDevice} ->
            {ok, json_device_to_record(JSONDevice, use_meta_defaults)}
    end.

-spec get_all_devices() -> {ok, [router_device:device()]} | {error, any()}.
get_all_devices() ->
    {Endpoint, Token} = token_lookup(),
    Url = <<Endpoint/binary, "/api/router/devices">>,
    lager:debug("get ~p", [Url]),
    Opts = [
        with_body,
        {pool, ?POOL},
        {connect_timeout, timer:seconds(2)},
        {recv_timeout, timer:seconds(2)}
    ],
    Start = erlang:system_time(millisecond),
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, Opts) of
        {ok, 200, _Headers, Body} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_all_devices, ok, End - Start),
            FilterMapFun = fun(JSONDevice) ->
                try json_device_to_record(JSONDevice, ignore_meta_defaults) of
                    Device -> {true, Device}
                catch
                    _E:_R ->
                        lager:error("failed to create record for device ~p: ~p", [
                            JSONDevice,
                            {_E, _R}
                        ]),
                        false
                end
            end,
            {ok,
                lists:filtermap(
                    FilterMapFun,
                    jsx:decode(Body, [return_maps])
                )};
        Other ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_all_devices, error, End - Start),
            {error, Other}
    end.

-spec get_devices_by_deveui_appeui(DevEui :: binary(), AppEui :: binary()) ->
    [{binary(), router_device:device()}].
get_devices_by_deveui_appeui(DevEui, AppEui) ->
    e2qc:cache(
        ?GET_DEVICES_CACHE_NAME,
        {DevEui, AppEui},
        ?GET_DEVICES_LIFETIME,
        fun() ->
            get_devices_by_deveui_appeui_(DevEui, AppEui)
        end
    ).

-spec get_org(OrgID :: binary()) -> {ok, map()} | {error, any()}.
get_org(OrgID) ->
    e2qc:cache(
        ?GET_ORG_CACHE_NAME,
        OrgID,
        ?GET_ORG_LIFETIME,
        fun() ->
            case get_org_(OrgID) of
                {error, Reason} = Error ->
                    ok = schedule_org_eviction(OrgID, Reason),
                    Error;
                Value ->
                    Value
            end
        end
    ).

-spec get_channels(Device :: router_device:device(), DeviceWorkerPid :: pid()) ->
    [router_channel:channel()].
get_channels(Device, DeviceWorkerPid) ->
    {Endpoint, Token} = token_lookup(),
    case get_device_(Endpoint, Token, Device) of
        {error, _Reason} ->
            [];
        {ok, JSON} ->
            Channels0 = kvc:path([<<"channels">>], JSON),
            Channels1 = lists:filtermap(
                fun(JSONChannel) ->
                    convert_channel(Device, DeviceWorkerPid, JSONChannel)
                end,
                Channels0
            ),
            Channels1
    end.

-spec event(Device :: router_device:device(), Map :: map()) -> ok.
event(Device, Map) ->
    erlang:spawn(
        fun() ->
            ok = router_utils:lager_md(Device),
            lager:debug("event ~p", [Map]),
            {Endpoint, Token} = token_lookup(),
            DeviceID = router_device:id(Device),
            Url = <<Endpoint/binary, "/api/router/devices/", DeviceID/binary, "/event">>,
            Category = maps:get(category, Map),
            true = lists:member(Category, [
                uplink,
                uplink_dropped,
                downlink,
                downlink_dropped,
                join_request,
                join_accept,
                misc
            ]),
            SubCategory = maps:get(sub_category, Map, undefined),
            true = lists:member(SubCategory, [
                undefined,
                uplink_confirmed,
                uplink_unconfirmed,
                uplink_integration_req,
                uplink_integration_res,
                uplink_dropped_device_inactive,
                uplink_dropped_not_enough_dc,
                uplink_dropped_late,
                uplink_dropped_invalid,
                downlink_confirmed,
                downlink_unconfirmed,
                downlink_dropped_payload_size_exceeded,
                downlink_dropped_misc,
                downlink_queued,
                downlink_ack,
                misc_integration_error
            ]),
            Data =
                case {Category, SubCategory} of
                    {downlink, SC} when SC == downlink_queued ->
                        #{
                            fcnt => maps:get(fcnt, Map),
                            payload_size => maps:get(payload_size, Map),
                            payload => maps:get(payload, Map),
                            port => maps:get(port, Map),
                            devaddr => maps:get(devaddr, Map),
                            hotspot => maps:get(hotspot, Map),
                            integration => #{
                                id => maps:get(channel_id, Map),
                                name => maps:get(channel_name, Map),
                                status => maps:get(channel_status, Map)
                            }
                        };
                    {downlink, SC} when
                        SC == downlink_confirmed orelse SC == downlink_unconfirmed
                    ->
                        #{
                            fcnt => maps:get(fcnt, Map),
                            payload_size => maps:get(payload_size, Map),
                            payload => maps:get(payload, Map),
                            port => maps:get(port, Map),
                            devaddr => maps:get(devaddr, Map),
                            hotspot => maps:get(hotspot, Map),
                            integration => #{
                                id => maps:get(channel_id, Map),
                                name => maps:get(channel_name, Map),
                                status => maps:get(channel_status, Map)
                            },
                            mac => maps:get(mac, Map)
                        };
                    {_C, SC} when
                        SC == uplink_integration_req orelse
                            SC == uplink_integration_res orelse
                            SC == downlink_dropped_payload_size_exceeded orelse
                            SC == downlink_dropped_misc orelse
                            SC == misc_integration_error
                    ->
                        Report = #{
                            integration => #{
                                id => maps:get(channel_id, Map),
                                name => maps:get(channel_name, Map),
                                status => maps:get(channel_status, Map)
                            }
                        },
                        case SC of
                            uplink_integration_req -> Report#{req => maps:get(request, Map)};
                            uplink_integration_res -> Report#{res => maps:get(response, Map)};
                            _ -> Report
                        end;
                    {uplink_dropped, _SC} ->
                        #{
                            fcnt => maps:get(fcnt, Map),
                            hotspot => maps:get(hotspot, Map)
                        };
                    {uplink, SC} when SC == uplink_confirmed orelse SC == uplink_unconfirmed ->
                        #{
                            fcnt => maps:get(fcnt, Map),
                            payload_size => maps:get(payload_size, Map),
                            payload => maps:get(payload, Map),
                            port => maps:get(port, Map),
                            devaddr => maps:get(devaddr, Map),
                            hotspot => maps:get(hotspot, Map),
                            dc => maps:get(dc, Map),
                            mac => maps:get(mac, Map)
                        };
                    {C, _SC} when
                        C == uplink orelse
                            C == downlink orelse
                            C == join_request orelse
                            C == join_accept
                    ->
                        #{
                            fcnt => maps:get(fcnt, Map),
                            payload_size => maps:get(payload_size, Map),
                            payload => maps:get(payload, Map),
                            port => maps:get(port, Map),
                            devaddr => maps:get(devaddr, Map),
                            hotspot => maps:get(hotspot, Map)
                        }
                end,
            Body = #{
                id => maps:get(id, Map),
                category => Category,
                sub_category => SubCategory,
                description => maps:get(description, Map),
                reported_at => maps:get(reported_at, Map),
                device_id => router_device:id(Device),
                data => Data
            },
            lager:debug("post ~p to ~p", [Body, Url]),
            Start = erlang:system_time(millisecond),
            case
                hackney:post(
                    Url,
                    [{<<"Authorization">>, <<"Bearer ", Token/binary>>}, ?HEADER_JSON],
                    jsx:encode(Body),
                    [with_body, {pool, ?POOL}]
                )
            of
                {ok, 200, _Headers, _Body} ->
                    End = erlang:system_time(millisecond),
                    ok = router_metrics:console_api_observe(report_status, ok, End - Start);
                _Other ->
                    lager:warning("got non 200 resp ~p", [_Other]),
                    End = erlang:system_time(millisecond),
                    ok = router_metrics:console_api_observe(report_status, error, End - Start)
            end
        end
    ),
    ok.

-spec get_downlink_url(Channel :: router_channel:channel(), DeviceID :: binary()) -> binary().
get_downlink_url(Channel, DeviceID) ->
    case maps:get(downlink_token, router_channel:args(Channel), undefined) of
        undefined ->
            <<>>;
        DownlinkToken ->
            {Endpoint, _Token} = token_lookup(),
            ChannelID = router_channel:id(Channel),
            <<Endpoint/binary, "/api/v1/down/", ChannelID/binary, "/", DownlinkToken/binary, "/",
                DeviceID/binary>>
    end.

-spec organizations_burned(
    Memo :: non_neg_integer(),
    HNTAmount :: non_neg_integer(),
    DCAmount :: non_neg_integer()
) -> ok.
organizations_burned(Memo, HNTAmount, DCAmount) ->
    Body = #{
        memo => Memo,
        hnt_amount => HNTAmount,
        dc_amount => DCAmount
    },
    gen_server:cast(?SERVER, {hnt_burn, Body}).

-spec get_token() -> binary().
get_token() ->
    gen_server:call(?SERVER, get_token).

-spec xor_filter_updates(AddedDeviceIDs :: [binary()], RemovedDeviceIDs :: [binary()]) -> ok.
xor_filter_updates(AddedDeviceIDs, RemovedDeviceIDs) ->
    {Endpoint, Token} = token_lookup(),
    Url = <<Endpoint/binary, "/api/router/devices/update_in_xor_filter">>,
    Body = #{added => AddedDeviceIDs, removed => RemovedDeviceIDs},
    case
        hackney:post(
            Url,
            [{<<"Authorization">>, <<"Bearer ", Token/binary>>}, ?HEADER_JSON],
            jsx:encode(Body),
            [with_body, {pool, ?POOL}]
        )
    of
        {ok, 200, _Headers, _Body} ->
            lager:info("Send filter updates to console ~p", [Body]),
            ok;
        _Other ->
            lager:warning("got non 200 resp for filter update ~p", [_Other]),
            ok
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    ets:new(?ETS, [public, named_table, set]),
    ok = hackney_pool:start_pool(?POOL, [{timeout, timer:seconds(60)}, {max_connections, 100}]),
    Endpoint = maps:get(endpoint, Args),
    Secret = maps:get(secret, Args),
    Token = get_token(Endpoint, Secret),
    ok = token_insert(Endpoint, Token),
    {ok, DB, [_, CF]} = router_db:get(),
    _ = erlang:send_after(?TOKEN_CACHE_TIME, self(), refresh_token),
    {ok, P} = load_pending_burns(DB),
    Inflight = maybe_spawn_pending_burns(P, []),
    Tref = schedule_next_tick(),
    {ok, #state{
        endpoint = Endpoint,
        secret = Secret,
        token = Token,
        db = DB,
        cf = CF,
        pending_burns = P,
        tref = Tref,
        inflight = Inflight
    }}.

handle_call(get_token, _From, #state{token = Token} = State) ->
    {reply, Token, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({hnt_burn, Body}, #state{db = DB, pending_burns = P, inflight = I} = State) ->
    Uuid = router_utils:uuid_v4(),
    ReqBody = Body#{request_id => Uuid},
    NewP = maps:put(Uuid, ReqBody, P),
    ok = store_pending_burns(DB, NewP),
    Pid = spawn_pending_burn(Uuid, ReqBody),
    {noreply, State#state{pending_burns = NewP, inflight = [{Uuid, Pid} | I]}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?TICK, #state{db = DB, pending_burns = P, inflight = I} = State) ->
    %% there is a race condition between spawning HTTP requests and possible
    %% success/fail replies from the http process. It's possible that a
    %% success or failure message could hit our gen_server before the
    %% gen_server's inflight state has been updated.
    %%
    %% Every TICK we will garbage collect the inflight list to make sure we
    %% retry things that should be retried and remove successes we missed due
    %% to the race.
    GCI = garbage_collect_inflight(P, I),
    NewInflight = maybe_spawn_pending_burns(P, GCI),
    ok = store_pending_burns(DB, P),
    Tref = schedule_next_tick(),
    {noreply, State#state{inflight = GCI ++ NewInflight, tref = Tref}};
handle_info({evict_org, OrgId, EvictionReason}, State) ->
    case e2qc:evict(?GET_ORG_CACHE_NAME, OrgId) of
        ok ->
            lager:info("Evicted ~p from cache early because ~p", [OrgId, EvictionReason]);
        notfound ->
            lager:info("~p not found in cache for early eviction because ~p", [
                OrgId,
                EvictionReason
            ])
    end,
    {noreply, State};
handle_info({hnt_burn, success, Uuid}, #state{pending_burns = P, inflight = I} = State) ->
    {noreply, State#state{
        pending_burns = maps:remove(Uuid, P),
        inflight = lists:keydelete(Uuid, 1, I)
    }};
handle_info({hnt_burn, drop, Uuid}, #state{pending_burns = P, inflight = I} = State) ->
    {noreply, State#state{
        pending_burns = maps:remove(Uuid, P),
        inflight = lists:keydelete(Uuid, 1, I)
    }};
handle_info({hnt_burn, fail, Uuid}, #state{inflight = I} = State) ->
    {noreply, State#state{inflight = lists:keydelete(Uuid, 1, I)}};
handle_info(refresh_token, #state{endpoint = Endpoint, secret = Secret} = State) ->
    Token = get_token(Endpoint, Secret),
    _ = erlang:send_after(?TOKEN_CACHE_TIME, self(), refresh_token),
    ok = token_insert(Endpoint, Token),
    {noreply, State#state{token = Token}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{db = DB, pending_burns = P}) ->
    ok = store_pending_burns(DB, P),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec convert_channel(Device :: router_device:device(), Pid :: pid(), JSONChannel :: map()) ->
    false | {true, router_channel:channel()}.
convert_channel(Device, Pid, #{<<"type">> := <<"http">>} = JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_http_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{
        url => kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
        headers => maps:to_list(kvc:path([<<"credentials">>, <<"headers">>], JSONChannel)),
        url_params => maps:to_list(
            kvc:path([<<"credentials">>, <<"url_params">>], JSONChannel, #{})
        ),
        method => list_to_existing_atom(
            binary_to_list(
                router_utils:to_bin(kvc:path([<<"credentials">>, <<"method">>], JSONChannel))
            )
        ),
        downlink_token => router_utils:to_bin(kvc:path([<<"downlink_token">>], JSONChannel))
    },
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Template = convert_template(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder, Template),
    {true, Channel};
convert_channel(Device, Pid, #{<<"type">> := <<"mqtt">>} = JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_mqtt_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{
        endpoint => kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
        uplink_topic => kvc:path([<<"credentials">>, <<"uplink">>, <<"topic">>], JSONChannel),
        downlink_topic => kvc:path(
            [<<"credentials">>, <<"downlink">>, <<"topic">>],
            JSONChannel,
            undefined
        )
    },
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Template = convert_template(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder, Template),
    {true, Channel};
convert_channel(Device, Pid, #{<<"type">> := <<"aws">>} = JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_aws_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{
        aws_access_key => binary_to_list(
            router_utils:to_bin(kvc:path([<<"credentials">>, <<"aws_access_key">>], JSONChannel))
        ),
        aws_secret_key => binary_to_list(
            router_utils:to_bin(kvc:path([<<"credentials">>, <<"aws_secret_key">>], JSONChannel))
        ),
        aws_region => binary_to_list(
            router_utils:to_bin(kvc:path([<<"credentials">>, <<"aws_region">>], JSONChannel))
        ),
        topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)
    },
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Template = convert_template(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid, Decoder, Template),
    {true, Channel};
convert_channel(Device, Pid, #{<<"type">> := <<"console">>} = JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_console_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    DeviceID = router_device:id(Device),
    Decoder = convert_decoder(JSONChannel),
    Template = convert_template(JSONChannel),
    Channel = router_channel:new(ID, Handler, Name, #{}, DeviceID, Pid, Decoder, Template),
    {true, Channel};
convert_channel(_Device, _Pid, _Channel) ->
    false.

-spec convert_decoder(JSONChannel :: map()) -> undefined | router_decoder:decoder().
convert_decoder(JSONChannel) ->
    case kvc:path([<<"function">>], JSONChannel, undefined) of
        undefined ->
            undefined;
        JSONDecoder ->
            case kvc:path([<<"active">>], JSONDecoder, false) of
                false ->
                    undefined;
                true ->
                    case kvc:path([<<"format">>], JSONDecoder, undefined) of
                        <<"custom">> ->
                            router_decoder:new(
                                kvc:path([<<"id">>], JSONDecoder),
                                custom,
                                #{function => kvc:path([<<"body">>], JSONDecoder)}
                            );
                        <<"cayenne">> ->
                            router_decoder:new(kvc:path([<<"id">>], JSONDecoder), cayenne, #{});
                        <<"browan_object_locator">> ->
                            router_decoder:new(
                                kvc:path([<<"id">>], JSONDecoder),
                                browan_object_locator,
                                #{}
                            );
                        _ ->
                            undefined
                    end
            end
    end.

-spec convert_template(JSONChannel :: map()) -> undefined | binary().
convert_template(JSONChannel) ->
    case kvc:path([<<"payload_template">>], JSONChannel, null) of
        null -> undefined;
        Template -> router_utils:to_bin(Template)
    end.

-spec get_token(Endpoint :: binary(), Secret :: binary()) -> binary().
get_token(Endpoint, Secret) ->
    Start = erlang:system_time(millisecond),
    case
        hackney:post(
            <<Endpoint/binary, "/api/router/sessions">>,
            [?HEADER_JSON],
            jsx:encode(#{secret => Secret}),
            [with_body, {pool, ?POOL}]
        )
    of
        {ok, 201, _Headers, Body} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_token, ok, End - Start),
            #{<<"jwt">> := Token} = jsx:decode(Body, [return_maps]),
            Token;
        _ ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_token, error, End - Start),
            erlang:throw(get_token)
    end.

-spec get_device_(Endpoint :: binary(), Token :: binary(), Device :: router_device:device()) ->
    {ok, map()} | {error, any()}.
get_device_(Endpoint, Token, Device) ->
    DeviceId = router_device:id(Device),
    Url = <<Endpoint/binary, "/api/router/devices/", DeviceId/binary>>,
    lager:debug("get ~p", [Url]),
    Opts = [
        with_body,
        {pool, ?POOL},
        {connect_timeout, timer:seconds(2)},
        {recv_timeout, timer:seconds(2)}
    ],
    Start = erlang:system_time(millisecond),
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, Opts) of
        {ok, 200, _Headers, Body} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_device, ok, End - Start),
            lager:debug("Body for ~p ~p", [Url, Body]),
            {ok, jsx:decode(Body, [return_maps])};
        {ok, 404, _ResponseHeaders, _ResponseBody} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_device, not_found, End - Start),
            lager:debug("device ~p not found", [DeviceId]),
            {error, not_found};
        _Other ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_device, error, End - Start),
            {error, {get_device_failed, _Other}}
    end.

-spec get_devices_by_deveui_appeui_(DevEui :: binary(), AppEui :: binary()) ->
    [{binary(), router_device:device()}].
get_devices_by_deveui_appeui_(DevEui, AppEui) ->
    {Endpoint, Token} = token_lookup(),
    Url =
        <<Endpoint/binary, "/api/router/devices/unknown?dev_eui=",
            (lorawan_utils:binary_to_hex(DevEui))/binary, "&app_eui=",
            (lorawan_utils:binary_to_hex(AppEui))/binary>>,
    lager:debug("get ~p", [Url]),
    Opts = [
        with_body,
        {pool, ?POOL},
        {connect_timeout, timer:seconds(2)},
        {recv_timeout, timer:seconds(2)}
    ],
    Start = erlang:system_time(millisecond),
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, Opts) of
        {ok, 200, _Headers, Body} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_devices_by_deveui_appeui, ok, End - Start),
            lists:map(
                fun(JSONDevice) ->
                    AppKey = lorawan_utils:hex_to_binary(
                        kvc:path([<<"app_key">>], JSONDevice)
                    ),
                    {AppKey, json_device_to_record(JSONDevice, ignore_meta_defaults)}
                end,
                jsx:decode(Body, [return_maps])
            );
        _Other ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(
                get_devices_by_deveui_appeui,
                error,
                End - Start
            ),
            []
    end.

-spec get_org_(OrgID :: binary()) -> {ok, map()} | {error, any()}.
get_org_(OrgID) ->
    {Endpoint, Token} = token_lookup(),
    Url = <<Endpoint/binary, "/api/router/organizations/", OrgID/binary>>,
    lager:debug("get ~p", [Url]),
    Opts = [
        with_body,
        {pool, ?POOL},
        {connect_timeout, timer:seconds(2)},
        {recv_timeout, timer:seconds(2)}
    ],
    Start = erlang:system_time(millisecond),
    case hackney:get(Url, [{<<"Authorization">>, <<"Bearer ", Token/binary>>}], <<>>, Opts) of
        {ok, 200, _Headers, Body} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_org, ok, End - Start),
            lager:debug("Body for ~p ~p", [Url, Body]),
            {ok, jsx:decode(Body, [return_maps])};
        {ok, 404, _ResponseHeaders, _ResponseBody} ->
            lager:debug("org ~p not found", [OrgID]),
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_org, not_found, End - Start),
            {error, not_found};
        _Other ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(get_org, error, End - Start),
            {error, {get_org_failed, _Other}}
    end.

%%%-------------------------------------------------------------------
%%% @ doc
%% Some metadata is only sent when requesting a single device, in this case we want
%% the correct default values present. Otherwise, to ignore those fields when
%% updating a device we pass `undefined' in their place.
%%
%% This is a helper function to opt into _all_ or _none_ of the defaults.
%%
%% @end
%% %-------------------------------------------------------------------
-spec json_device_to_record(
    JSONDevice :: map(),
    DefaultsAction :: use_meta_defaults | ignore_meta_defaults
) -> router_device:device().
json_device_to_record(JSONDevice, ignore_meta_defaults) ->
    json_device_to_record(
        JSONDevice,
        _IgnoreADRMeta = undefined,
        _IgnoreUS915CFListMeta = undefined
    );
json_device_to_record(JSONDevice, use_meta_defaults) ->
    json_device_to_record(
        JSONDevice,
        _ADRDefault = false,
        _US915CFListDefault = false
    ).

-spec json_device_to_record(
    JSONDevice :: map(),
    ADRDefault :: undefined | boolean(),
    US915CFListDefault :: undefined | boolean()
) -> router_device:device().
json_device_to_record(JSONDevice, ADRDefault, US915CFListDefault) ->
    ID = kvc:path([<<"id">>], JSONDevice),
    Metadata = #{
        labels => kvc:path([<<"labels">>], JSONDevice, undefined),
        organization_id => kvc:path([<<"organization_id">>], JSONDevice, undefined),
        multi_buy => kvc:path([<<"multi_buy">>], JSONDevice, undefined),
        adr_allowed => kvc:path([<<"adr_allowed">>], JSONDevice, ADRDefault),
        cf_list_enabled => kvc:path([<<"cf_list_enabled">>], JSONDevice, US915CFListDefault)
    },
    DeviceUpdates = [
        {name, kvc:path([<<"name">>], JSONDevice)},
        {dev_eui, lorawan_utils:hex_to_binary(kvc:path([<<"dev_eui">>], JSONDevice))},
        {app_eui, lorawan_utils:hex_to_binary(kvc:path([<<"app_eui">>], JSONDevice))},
        {metadata, maps:filter(fun(_K, V) -> V =/= undefined end, Metadata)},
        {is_active, kvc:path([<<"active">>], JSONDevice)}
    ],
    router_device:update(DeviceUpdates, router_device:new(ID)).

-spec token_lookup() -> {binary(), binary()}.
token_lookup() ->
    case ets:lookup(?ETS, token) of
        [] -> {<<>>, <<>>};
        [{token, EndpointToken}] -> EndpointToken
    end.

-spec token_insert(Endpoint :: binary(), Token :: binary()) -> ok.
token_insert(Endpoint, Token) ->
    true = ets:insert(?ETS, {token, {Endpoint, Token}}),
    ok.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?TICK_INTERVAL, self(), ?TICK).

-spec schedule_org_eviction(OrgID :: binary(), Reason :: any()) -> ok.
schedule_org_eviction(OrgID, Reason) ->
    _ = erlang:send_after(?GET_ORG_EVICTION_TIMEOUT, self(), {evict_org, OrgID, Reason}),
    ok.

-spec store_pending_burns(
    DB :: rocksdb:db_handle(),
    Pending :: pending()
) -> ok | {error, term()}.
store_pending_burns(DB, Pending) ->
    Bin = term_to_binary(Pending),
    rocksdb:put(DB, ?PENDING_KEY, Bin, []).

-spec load_pending_burns(DB :: rocksdb:db_handle()) -> {ok, pending()}.
load_pending_burns(DB) ->
    case rocksdb:get(DB, ?PENDING_KEY, []) of
        {ok, Bin} -> {ok, binary_to_term(Bin)};
        not_found -> {ok, #{}};
        Error -> Error
    end.

-spec garbage_collect_inflight(
    Pending :: pending(),
    Inflight :: [inflight()]
) -> [inflight()].
garbage_collect_inflight(P, I) ->
    Garbage = lists:foldl(
        fun({Uuid, Pid} = E, Acc) ->
            case maps:is_key(Uuid, P) of
                true ->
                    %% if the uuid is in the map, it means
                    %% the request is:
                    %%   - in flight, or,
                    %%   - a failure that we missed removing
                    %%     and needs to be retried.
                    case is_process_alive(Pid) of
                        %% if the process is alive,
                        %% it's inflight, so don't
                        %% garbage collect it
                        true -> Acc;
                        %% the pid isn't alive - it's a failure
                        %% and we should re-attempt it
                        false -> [E | Acc]
                    end;
                false ->
                    %% not in the map, this is a success
                    %% but somehow we missed removing it
                    [E | Acc]
            end
        end,
        [],
        I
    ),
    I -- Garbage.

-spec maybe_spawn_pending_burns(
    Pending :: pending(),
    Inflight :: [inflight()]
) -> [inflight()].
maybe_spawn_pending_burns(P, []) when map_size(P) == 0 ->
    [];
maybe_spawn_pending_burns(P, I) ->
    maps:fold(
        fun(Uuid, Body, Acc) ->
            Pid = spawn_pending_burn(Uuid, Body),
            [{Uuid, Pid} | Acc]
        end,
        [],
        maps:without(
            [Uuid || {Uuid, _} <- I],
            P
        )
    ).

-spec spawn_pending_burn(
    Uuid :: router_utils:uuid_v4(),
    Body :: maps:map()
) -> pid().
spawn_pending_burn(Uuid, Body) ->
    Self = self(),
    spawn(fun() ->
        do_hnt_burn_post(Uuid, Self, Body, 5, 8, 5)
    end).

-spec do_hnt_burn_post(
    Uuid :: router_utils:uuid_v4(),
    ReplyPid :: pid(),
    Body :: request_body(),
    Delay :: pos_integer(),
    Next :: pos_integer(),
    Retries :: non_neg_integer()
) -> {hnt_burn, success | fail, router_utils:uuid_v4()}.
do_hnt_burn_post(Uuid, ReplyPid, _Body, _Delay, _Next, 0) ->
    ReplyPid ! {hnt_burn, fail, Uuid};
do_hnt_burn_post(Uuid, ReplyPid, Body, Delay, Next, Retries) ->
    {Endpoint, Token} = token_lookup(),
    Url = <<Endpoint/binary, "/api/router/organizations/burned">>,
    lager:debug("post ~p to ~p", [Body, Url]),
    Start = erlang:system_time(millisecond),
    case
        hackney:post(
            Url,
            [{<<"Authorization">>, <<"Bearer ", Token/binary>>}, ?HEADER_JSON],
            jsx:encode(Body),
            [with_body, {pool, ?POOL}]
        )
    of
        {ok, 204, _Headers, _Reply} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(org_burn, ok, End - Start),
            lager:debug("Burn notification successful"),
            ReplyPid ! {hnt_burn, success, Uuid};
        {ok, 404, _Headers, _Reply} ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(org_burn, not_found, End - Start),
            lager:debug("Memo not found in console database; drop"),
            ReplyPid ! {hnt_burn, drop, Uuid};
        Other ->
            End = erlang:system_time(millisecond),
            ok = router_metrics:console_api_observe(org_burn, error, End - Start),
            lager:debug("Burn notification failed ~p", [Other]),
            timer:sleep(Delay),
            %% fibonacci delay timer
            do_hnt_burn_post(Uuid, ReplyPid, Body, Next, Delay + Next, Retries - 1)
    end.
