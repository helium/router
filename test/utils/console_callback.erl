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

%% Get All Devices
handle('GET', [<<"api">>, <<"router">>, <<"devices">>], _Req, Args) ->
    Body = #{
        <<"id">> => ?CONSOLE_DEVICE_ID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"app_key">> => lorawan_utils:binary_to_hex(maps:get(app_key, Args)),
        <<"app_eui">> => lorawan_utils:binary_to_hex(maps:get(app_eui, Args)),
        <<"dev_eui">> => lorawan_utils:binary_to_hex(maps:get(dev_eui, Args)),
        <<"channels">> => [],
        <<"labels">> => ?CONSOLE_LABELS,
        <<"organization_id">> => ?CONSOLE_ORG_ID,
        <<"active">> => true,
        <<"multi_buy">> => 1
    },
    {200, [], jsx:encode([Body])};
%% Get Device
handle('GET', [<<"api">>, <<"router">>, <<"devices">>, DID], _Req, Args) ->
    Tab = maps:get(ets, Args),
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
    Body = #{
        <<"id">> => DeviceID,
        <<"name">> => ?CONSOLE_DEVICE_NAME,
        <<"app_key">> => lorawan_utils:binary_to_hex(maps:get(app_key, Args)),
        <<"app_eui">> => lorawan_utils:binary_to_hex(maps:get(app_eui, Args)),
        <<"dev_eui">> => lorawan_utils:binary_to_hex(maps:get(dev_eui, Args)),
        <<"channels">> => Channels,
        <<"labels">> => ?CONSOLE_LABELS,
        <<"organization_id">> => ?CONSOLE_ORG_ID,
        <<"active">> => IsActive,
        <<"multi_buy">> => 1,
        <<"adr_allowed">> => false
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
    Pid ! {console_event, maps:get(<<"category">>, Data, <<"unknown">>), Data},
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

websocket_info(_Req, {joined, Topic}, State) ->
    Data = router_console_ws_handler:encode_msg(<<"0">>, Topic, <<"device:all:debug:devices">>, #{
        <<"devices">> => [?CONSOLE_DEVICE_ID]
    }),
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
    {reply, {text, Data}, State};
websocket_info(_Req, {device_update, Topic}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        Topic,
        <<"device:all:refetch:devices">>,
        #{<<"devices">> => [?CONSOLE_DEVICE_ID]}
    ),
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
websocket_info(_Req, {is_active, true}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"device:all">>,
        <<"device:all:active:devices">>,
        #{<<"devices">> => [?CONSOLE_DEVICE_ID]}
    ),
    {reply, {text, Data}, State};
websocket_info(_Req, {is_active, false}, State) ->
    Data = router_console_ws_handler:encode_msg(
        <<"0">>,
        <<"device:all">>,
        <<"device:all:inactive:devices">>,
        #{<<"devices">> => [?CONSOLE_DEVICE_ID]}
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
    lager:warning("got unknow message ~p", [Map]),
    {ok, State}.

init_ws([<<"websocket">>], _Req, _Args) ->
    {ok, handover};
init_ws(_, _, _) ->
    ignore.
