-module(console_callback).

-behaviour(elli_handler).
-behaviour(elli_websocket_handler).

-include("console_test.hrl").

-export([
    init/2,
    handle/2,
    handle_event/3
]).

-export([
    websocket_init/2,
    websocket_handle/3,
    websocket_info/3,
    websocket_handle_event/3
]).

init(Req, Args) ->
    case elli_request:get_header(<<"Upgrade">>, Req) of
        <<"websocket">> ->
            init_ws(elli_request:path(Req), Req, Args);
        _ ->
            ignore
    end.

handle(Req, _Args) ->
    Method =
        case elli_request:get_header(<<"Upgrade">>, Req) of
            <<"websocket">> ->
                websocket;
            _ ->
                elli_request:method(Req)
        end,
    handle(Method, elli_request:path(Req), Req, _Args).

device_to_json(Device) ->
    #{
        <<"id">> => router_device:id(Device),
        <<"name">> => router_device:name(Device),
        <<"app_key">> => lorawan_utils:binary_to_hex(router_device:app_s_key(Device)),
        <<"app_eui">> => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
        <<"dev_eui">> => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
        <<"channels">> => [],
        <<"labels">> => maps:get(labels, router_device:metadata(Device), []),
        <<"organization_id">> => maps:get(
            organization_id,
            router_device:metadata(Device),
            <<"fake org id">>
        ),
        <<"active">> => true,
        <<"multi_buy">> => 9
    }.

%% Get All Devices
handle('GET', [<<"api">>, <<"router">>, <<"devices">>], Req, Args) ->
    Tab = maps:get(ets, Args),
    Qs = elli_request:query_str(Req),
    {Devices, ResourceID} =
        case ets:lookup(Tab, devices) of
            [] ->
                {
                    [
                        #{
                            <<"id">> => ?CONSOLE_DEVICE_ID,
                            <<"name">> => ?CONSOLE_DEVICE_NAME,
                            <<"app_key">> => lorawan_utils:binary_to_hex(maps:get(app_key, Args)),
                            <<"app_eui">> => lorawan_utils:binary_to_hex(maps:get(app_eui, Args)),
                            <<"dev_eui">> => lorawan_utils:binary_to_hex(maps:get(dev_eui, Args)),
                            <<"channels">> => [],
                            <<"labels">> => ?CONSOLE_LABELS,
                            <<"organization_id">> => ?CONSOLE_ORG_ID,
                            <<"active">> => true,
                            <<"multi_buy">> => 9
                        }
                    ],
                    undefined
                };
            [{devices, {Qs, [], Refill}}] ->
                true = ets:insert(Tab, {devices, Refill}),
                {[], undefined};
            [{devices, {Qs, Ds, Refill}}] ->
                UUID = router_utils:uuid_v4(),
                {PickedDevices, LeftOverDevices} = split_list(Ds),
                true = ets:insert(
                    Tab,
                    {devices, {<<"after=", UUID/binary>>, LeftOverDevices, Refill}}
                ),
                {lists:map(fun device_to_json/1, PickedDevices), UUID};
            [{devices, Ds}] ->
                UUID = router_utils:uuid_v4(),
                {PickedDevices, LeftOverDevices} = split_list(Ds),
                true = ets:insert(Tab, {devices, {<<"after=", UUID/binary>>, LeftOverDevices, Ds}}),
                {lists:map(fun device_to_json/1, PickedDevices), UUID}
        end,
    case ResourceID of
        undefined ->
            {200, [], jsx:encode(#{data => Devices})};
        ResourceID when is_binary(ResourceID) ->
            {200, [], jsx:encode(#{data => Devices, 'after' => ResourceID})}
    end;
%% Get All Orgs
handle('GET', [<<"api">>, <<"router">>, <<"organizations">>], Req, Args) ->
    Tab = maps:get(ets, Args),
    Qs = elli_request:query_str(Req),
    {Orgs, ResourceID} =
        case ets:lookup(Tab, organizations) of
            [] ->
                {[], undefined};
            [{organizations, {Qs, []}}] ->
                true = ets:delete(Tab, organizations),
                {[], undefined};
            [{organizations, {Qs, Os}}] ->
                UUID = router_utils:uuid_v4(),
                {PickedOrgs, LeftOverOrgs} = split_list(Os),
                true = ets:insert(
                    Tab,
                    {organizations, {<<"after=", UUID/binary>>, LeftOverOrgs}}
                ),
                {PickedOrgs, UUID};
            [{organizations, Os}] ->
                UUID = router_utils:uuid_v4(),
                {PickedOrgs, LeftOverOrgs} = split_list(Os),
                true = ets:insert(
                    Tab,
                    {organizations, {<<"after=", UUID/binary>>, LeftOverOrgs}}
                ),
                {PickedOrgs, UUID}
        end,
    case ResourceID of
        undefined ->
            {200, [], jsx:encode(#{data => Orgs})};
        ResourceID when is_binary(ResourceID) ->
            {200, [],
                jsx:encode(#{
                    data => Orgs,
                    'after' => ResourceID
                })}
    end;
%% Get Device
handle('GET', [<<"api">>, <<"router">>, <<"devices">>, DID], _Req, Args) ->
    Tab = maps:get(ets, Args),
    PreferredHotspots =
        case ets:lookup(Tab, preferred_hotspots) of
            [] -> [];
            [{preferred_hotspots, PH}] -> PH
        end,
    ChannelType =
        case ets:lookup(Tab, channel_type) of
            [] -> http;
            [{channel_type, Type}] -> Type
        end,
    NoChannel =
        case ets:lookup(Tab, no_channel) of
            [] -> false;
            [{no_channel, No}] -> No
        end,
    Channel =
        case ChannelType of
            http -> ?CONSOLE_HTTP_CHANNEL;
            mqtt -> ?CONSOLE_MQTT_CHANNEL;
            aws -> ?CONSOLE_AWS_CHANNEL;
            iot_hub -> ?CONSOLE_IOT_HUB_CHANNEL;
            iot_central -> ?CONSOLE_IOT_CENTRAL_CHANNEL;
            decoder -> ?CONSOLE_DECODER_CHANNEL;
            console -> ?CONSOLE_CONSOLE_CHANNEL;
            template -> ?CONSOLE_TEMPLATE_CHANNEL
        end,
    Channels =
        case NoChannel of
            true ->
                [];
            false ->
                case ets:lookup(Tab, channels) of
                    [] -> [Channel];
                    [{channels, C}] -> C
                end
        end,
    DeviceID =
        case ets:lookup(Tab, device_id) of
            [] -> ?CONSOLE_DEVICE_ID;
            [{device_id, ID}] -> ID
        end,
    NotFound =
        case ets:lookup(Tab, device_not_found) of
            [] -> false;
            [{device_not_found, Bool}] -> Bool
        end,
    IsActive =
        case ets:lookup(Tab, is_active) of
            [] -> true;
            [{is_active, IS}] -> IS
        end,
    US915JoinAcceptCFListEnabled =
        case ets:lookup(Tab, cf_list_enabled) of
            [] -> false;
            [{cf_list_enabled, IS2}] -> IS2
        end,
    ADRAllowed =
        case ets:lookup(Tab, adr_allowed) of
            [] -> false;
            [{adr_allowed, IS3}] -> IS3
        end,
    RxDelay =
        case ets:lookup(Tab, rx_delay) of
            [] -> 0;
            [{rx_delay, DelaySeconds}] -> DelaySeconds
        end,
    AppEUI =
        case ets:lookup(Tab, app_eui) of
            [] -> maps:get(app_eui, Args);
            [{app_eui, EUI1}] -> EUI1
        end,
    DevEUI =
        case ets:lookup(Tab, dev_eui) of
            [] -> maps:get(dev_eui, Args);
            [{dev_eui, EUI2}] -> EUI2
        end,

    Body = #{
        <<"id">> => DeviceID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"app_key">> => lorawan_utils:binary_to_hex(maps:get(app_key, Args)),
        <<"app_eui">> => lorawan_utils:binary_to_hex(AppEUI),
        <<"dev_eui">> => lorawan_utils:binary_to_hex(DevEUI),
        <<"channels">> => Channels,
        <<"labels">> => ?CONSOLE_LABELS,
        <<"organization_id">> => ?CONSOLE_ORG_ID,
        <<"active">> => IsActive,
        <<"multi_buy">> => 9,
        <<"adr_allowed">> => ADRAllowed,
        <<"cf_list_enabled">> => US915JoinAcceptCFListEnabled,
        <<"rx_delay">> => RxDelay,
        <<"preferred_hotspots">> => [
            list_to_binary(libp2p_crypto:bin_to_b58(P))
         || P <- PreferredHotspots
        ]
    },
    case NotFound of
        true ->
            {404, [], <<"Not Found">>};
        false ->
            case DID == <<"unknown">> of
                true ->
                    {200, [], jsx:encode([Body])};
                false ->
                    {200, [], jsx:encode(Body)}
            end
    end;
handle('POST', [<<"api">>, <<"router">>, <<"devices">>, <<"update_in_xor_filter">>], Req, Args) ->
    Pid = maps:get(forward, Args),
    Body = elli_request:body(Req),
    try jsx:decode(Body, [return_maps]) of
        JSON ->
            Added = maps:get(<<"added">>, JSON, <<"added not present">>),
            Removed = maps:get(<<"removed">>, JSON, <<"removed not present">>),
            Pid ! {console_filter_update, Added, Removed},
            {200, [], <<>>}
    catch
        _:_ ->
            {400, [], <<"bad_body">>}
    end;
%% Get token
handle('POST', [<<"api">>, <<"router">>, <<"sessions">>], _Req, _Args) ->
    Body = #{<<"jwt">> => <<"console_callback_token">>},
    {201, [], jsx:encode(Body)};
%% Report status
handle(
    'POST',
    [
        <<"api">>,
        <<"router">>,
        <<"devices">>,
        _DID,
        <<"event">>
    ],
    Req,
    Args
) ->
    Pid = maps:get(forward, Args),
    Body = elli_request:body(Req),
    Data = jsx:decode(Body, [return_maps]),
    Cat = maps:get(<<"category">>, Data, <<"unknown">>),
    SubCat = maps:get(<<"sub_category">>, Data, <<"unknown">>),
    ct:print("Console Event: ~p (~p)~n~n~p", [Cat, SubCat, Data]),
    Pid ! {console_event, Cat, SubCat, Data},
    {200, [], <<>>};
handle('POST', [<<"api">>, <<"router">>, <<"organizations">>, <<"burned">>], Req, Args) ->
    Pid = maps:get(forward, Args),
    Body = elli_request:body(Req),
    try jsx:decode(Body, [return_maps]) of
        Map ->
            Pid ! {organizations_burned, Map},
            {204, [], <<>>}
    catch
        _:_ ->
            {400, [], <<"bad_body">>}
    end;
handle('GET', [<<"api">>, <<"router">>, <<"organizations">>, <<"zero_dc">>], _Req, Args) ->
    _Pid = maps:get(forward, Args),
    Tab = maps:get(ets, Args),
    OrgIDs =
        case ets:lookup(Tab, unfunded_org_ids) of
            [] -> [<<"no balance org">>];
            [{unfunded_org_ids, IDs}] -> IDs
        end,
    {200, [], jsx:encode(#{<<"data">> => OrgIDs})};
%% POST to channel
handle('POST', [<<"channel">>], Req, Args) ->
    Pid = maps:get(forward, Args),
    Body = elli_request:body(Req),
    Tab = maps:get(ets, Args),
    Resp =
        case ets:lookup(Tab, http_resp) of
            [] -> <<"success">>;
            [{http_resp, R}] -> R
        end,
    IsBodyJson =
        case ets:lookup(Tab, http_resp_is_json) of
            [] -> true;
            [{http_resp_is_json, R2}] -> R2
        end,

    case IsBodyJson of
        false ->
            %% Wrap in a map() so tests can use matching utilities
            Pid ! {channel_data, #{body => Body}},
            {200, [], Resp};
        true ->
            try jsx:decode(Body, [return_maps]) of
                JSON ->
                    Pid ! {channel_data, JSON},
                    Reply = base64:encode(<<"reply">>),
                    case maps:find(<<"payload">>, JSON) of
                        {ok, Reply} ->
                            {200, [],
                                jsx:encode(#{
                                    payload_raw => base64:encode(<<"ack">>),
                                    port => 1,
                                    confirmed => true
                                })};
                        _ ->
                            {200, [], Resp}
                    end
            catch
                _:_ ->
                    {400, [], <<"bad_body">>}
            end
    end;
handle('websocket', [<<"websocket">>], Req, Args) ->
    %% Upgrade to a websocket connection.
    elli_websocket:upgrade(Req, [
        {handler, ?MODULE},
        {handler_opts, Args}
    ]),
    %% websocket is closed:
    %% See RFC-6455 (https://tools.ietf.org/html/rfc6455) for a list of
    %% valid WS status codes than can be used on a close frame.
    %% Note that the second element is the reason and is abitrary but should be meaningful
    %% in regards to your server and sub-protocol.
    {<<"1000">>, <<"Closed">>};
handle(_Method, _Path, _Req, _Args) ->
    ct:pal("got unknown ~p req on ~p args=~p", [_Method, _Path, _Args]),
    {404, [], <<"Not Found">>}.

handle_event(_Event, _Data, _Args) ->
    ok.

websocket_init(Req, Opts) ->
    lager:info("websocket_init ~p", [Req]),
    lager:info("websocket_init ~p", [Opts]),
    maps:get(forward, Opts) ! {websocket_init, self()},
    {ok, [], Opts}.

websocket_handle(_Req, {text, Msg}, State) ->
    {ok, Map} = router_console_ws_handler:decode_msg(Msg),
    handle_message(Map, State);
websocket_handle(_Req, _Frame, State) ->
    lager:info("websocket_handle ~p", [_Frame]),
    {ok, State}.

websocket_info(_Req, clear_queue, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"device:all">>,
        <<"device:all:clear_downlink_queue:devices">>,
        #{<<"devices">> => [?CONSOLE_DEVICE_ID]}
    ),
    _ = e2qc:evict(router_console_api_get_device, ?CONSOLE_DEVICE_ID),
    {reply, {text, Data}, State};
websocket_info(_Req, {downlink, Payload}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"device:all">>,
        <<"device:all:downlink:devices">>,
        #{
            <<"devices">> => [?CONSOLE_DEVICE_ID],
            <<"payload">> => Payload,
            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME
        }
    ),
    _ = e2qc:evict(router_console_api_get_device, ?CONSOLE_DEVICE_ID),
    {reply, {text, Data}, State};
websocket_info(_Req, {device_update, Topic}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        Topic,
        <<"device:all:refetch:devices">>,
        #{<<"devices">> => [?CONSOLE_DEVICE_ID]}
    ),
    _ = e2qc:evict(router_console_api_get_device, ?CONSOLE_DEVICE_ID),
    {reply, {text, Data}, State};
websocket_info(_Req, {org_update, Topic}, State) ->
    Payload = #{
        <<"id">> => ?CONSOLE_ORG_ID,
        <<"dc_balance_nonce">> => 0,
        <<"dc_balance">> => 0
    },
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        Topic,
        <<"organization:all:refill:dc_balance">>,
        Payload
    ),
    {reply, {text, Data}, State};
websocket_info(_Req, {org_refill, OrgID, RefillAmount}, State) ->
    Payload = #{
        <<"id">> => OrgID,
        <<"dc_balance_nonce">> => 1,
        <<"dc_balance">> => RefillAmount
    },
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"organization:all">>,
        <<"organization:all:refill:dc_balance">>,
        Payload
    ),
    {reply, {text, Data}, State};
websocket_info(_Req, {org_zero_dc, OrgID}, State) ->
    Payload = #{<<"id">> => OrgID, <<"dc_balance">> => 0},
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"organization:all">>,
        <<"organization:all:zeroed:dc_balance">>,
        Payload
    ),
    {reply, {text, Data}, State};
websocket_info(_Req, refetch_router_address, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"organization:all">>,
        <<"organization:all:refetch:router_address">>,
        #{}
    ),
    {reply, {text, Data}, State};
websocket_info(_Req, {is_active, true}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"device:all">>,
        <<"device:all:active:devices">>,
        #{<<"devices">> => [?CONSOLE_DEVICE_ID]}
    ),
    _ = e2qc:evict(router_console_api_get_device, ?CONSOLE_DEVICE_ID),
    {reply, {text, Data}, State};
websocket_info(_Req, {is_active, false}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"device:all">>,
        <<"device:all:inactive:devices">>,
        #{<<"devices">> => [?CONSOLE_DEVICE_ID]}
    ),
    _ = e2qc:evict(router_console_api_get_device, ?CONSOLE_DEVICE_ID),
    {reply, {text, Data}, State};
websocket_info(_Req, get_router_address, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"router">>,
        <<"router:get_address">>,
        #{}
    ),
    {reply, {text, Data}, State};
websocket_info(_Req, {label_fetch_queue, LabelID}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"label:all">>,
        <<"label:all:downlink:fetch_queue">>,
        #{
            <<"label">> => LabelID,
            <<"devices">> => [?CONSOLE_DEVICE_ID]
        }
    ),
    _ = e2qc:evict(router_console_api_get_device, ?CONSOLE_DEVICE_ID),
    {reply, {text, Data}, State};
websocket_info(_Req, device_fetch_queue, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"device:all">>,
        <<"device:all:downlink:fetch_queue">>,
        #{
            <<"device">> => ?CONSOLE_DEVICE_ID
        }
    ),
    _ = e2qc:evict(router_console_api_get_device, ?CONSOLE_DEVICE_ID),
    {reply, {text, Data}, State};
websocket_info(_Req, {discovery, Map}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"device:all">>,
        <<"device:all:discover:devices">>,
        Map
    ),
    {reply, {text, Data}, State};
websocket_info(_Req, _Msg, State) ->
    lager:info("websocket_info ~p", [_Msg]),
    {ok, State}.

websocket_handle_event(_Event, _Args, _State) ->
    lager:info("websocket_handle_event ~p", [_Event]),
    ok.

handle_message(#{ref := Ref, topic := <<"phoenix">>, event := <<"heartbeat">>}, State) ->
    Data = router_console_ws_handler:encode_msg(Ref, <<"phoenix">>, <<"phx_reply">>, #{
        <<"status">> => <<"ok">>
    }),
    {reply, {text, Data}, State};
handle_message(#{ref := Ref, topic := Topic, event := <<"phx_join">>}, State) ->
    Data = router_console_ws_handler:encode_msg(
        Ref,
        Topic,
        <<"phx_reply">>,
        #{<<"status">> => <<"ok">>},
        Ref
    ),
    {reply, {text, Data}, State};
handle_message(Map, State) ->
    lager:info("got unhandle message ~p ~p", [Map, lager:pr(State, ?MODULE)]),
    Pid = maps:get(forward, State),
    Pid ! {websocket_msg, Map},
    {ok, State}.

init_ws([<<"websocket">>], _Req, _Args) ->
    {ok, handover};
init_ws(_, _, _) ->
    ignore.

-spec split_list(List :: list()) -> {list(), list()}.
split_list(List) ->
    case erlang:length(List) of
        L when L > 1 ->
            lists:split(erlang:trunc(L / 2), List);
        _ ->
            {List, []}
    end.
