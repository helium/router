-define(CONSOLE_IP_PORT, <<"127.0.0.1:3000">>).
-define(CONSOLE_URL, <<"http://", ?CONSOLE_IP_PORT/binary>>).
-define(CONSOLE_WS_URL, <<"ws://", ?CONSOLE_IP_PORT/binary, "/websocket">>).

-define(CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN, <<"downlink_token_123">>).
-define(CONSOLE_HTTP_CHANNEL_ID, <<"12345">>).
-define(CONSOLE_HTTP_CHANNEL_NAME, <<"fake_http">>).
-define(CONSOLE_HTTP_CHANNEL, #{
    <<"type">> => <<"http">>,
    <<"credentials">> => #{
        <<"headers">> => #{},
        <<"url_params">> => #{},
        <<"endpoint">> => <<?CONSOLE_URL/binary, "/channel">>,
        <<"method">> => <<"POST">>
    },
    <<"downlink_token">> => ?CONSOLE_HTTP_CHANNEL_DOWNLINK_TOKEN,
    <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
    <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME
}).
