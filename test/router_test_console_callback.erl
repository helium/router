-module(router_test_console_callback).

-behaviour(elli_handler).
-behaviour(elli_websocket_handler).

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

%% CONSOLE: Get token
handle('POST', [<<"api">>, <<"router">>, <<"sessions">>], _Req, _Args) ->
    Body = #{<<"jwt">> => <<"console_callback_token">>},
    {201, [], jsx:encode(Body)};
%% CONSOLE: Get unknown device
handle('GET', [<<"api">>, <<"router">>, <<"devices">>, <<"unknown">>], _Req, _Args) ->
    Body = lists:map(
        fun({Device, Appkey}) ->
            Meta = router_device:metadata(Device),
            #{
                <<"id">> => router_device:id(Device),
                <<"name">> => router_device:name(Device),
                <<"app_key">> => lorawan_utils:binary_to_hex(Appkey),
                <<"app_eui">> => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
                <<"dev_eui">> => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
                %% TODO OPTIONS FOR ALL THIS
                <<"channels">> => [],
                <<"labels">> => maps:get(labels, Meta),
                <<"organization_id">> => maps:get(organization_id, Meta),
                <<"active">> => true,
                <<"multi_buy">> => 1,
                <<"adr_allowed">> => false,
                <<"cf_list_enabled">> => false,
                <<"rx_delay">> => 1
            }
        end,
        router_test_console:lookup_devices()
    ),
    {200, [], jsx:encode(Body)};
%% CONSOLE:  Get Device
handle('GET', [<<"api">>, <<"router">>, <<"devices">>, DeviceID], _Req, _Args) ->
    case router_test_console:lookup_device(DeviceID) of
        {error, not_found} ->
            {404, [], <<"Not Found">>};
        {ok, Device, Appkey} ->
            Meta = router_device:metadata(Device),
            Body = #{
                <<"id">> => router_device:id(Device),
                <<"name">> => router_device:name(Device),
                <<"app_key">> => lorawan_utils:binary_to_hex(Appkey),
                <<"app_eui">> => lorawan_utils:binary_to_hex(router_device:app_eui(Device)),
                <<"dev_eui">> => lorawan_utils:binary_to_hex(router_device:dev_eui(Device)),
                %% TODO OPTIONS FOR ALL THIS
                <<"channels">> => maps:get(channels, Meta),
                <<"labels">> => maps:get(labels, Meta),
                <<"organization_id">> => maps:get(organization_id, Meta),
                <<"active">> => router_device:is_active(Device),
                <<"multi_buy">> => maps:get(multi_buy, Meta),
                <<"adr_allowed">> => maps:get(adr_allowed, Meta),
                <<"cf_list_enabled">> => maps:get(cf_list_enabled, Meta),
                <<"rx_delay">> => maps:get(rx_delay, Meta)
            },
            {200, [], jsx:encode(Body)}
    end;
%% CONSOLE: Post event
handle(
    'POST',
    [
        <<"api">>,
        <<"router">>,
        <<"devices">>,
        _DeviceID,
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
%% HTTP INTEGRATION: Post
handle('POST', [<<"channel">>], Req, Args) ->
    Pid = maps:get(forward, Args),
    Body = elli_request:body(Req),
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
                    {200, [], <<"success">>}
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
    {close, <<"1000">>};
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
handle_message(Map, #{forward := Pid} = State) ->
    lager:info("got unhandle message ~p ~p", [Map, lager:pr(State, ?MODULE)]),
    Pid ! {websocket_msg, Map},
    {ok, State}.

init_ws([<<"websocket">>], _Req, _Args) ->
    {ok, handover};
init_ws(_, _, _) ->
    ignore.
