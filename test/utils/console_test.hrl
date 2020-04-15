-define(CONSOLE_IP_PORT, <<"127.0.0.1:3000">>).
-define(CONSOLE_URL, <<"http://", ?CONSOLE_IP_PORT/binary>>).
-define(CONSOLE_WS_URL, <<"ws://", ?CONSOLE_IP_PORT/binary, "/websocket">>).

-define(CONSOLE_DEVICE_ID, <<"yolo_id">>).
-define(CONSOLE_DEVICE_NAME, <<"yolo_name">>).

-define(CONSOLE_HTTP_CHANNEL_ID, <<"12345">>).
-define(CONSOLE_HTTP_CHANNEL_NAME, <<"fake_http">>).
-define(CONSOLE_HTTP_CHANNEL, #{<<"type">> => <<"http">>,
                                <<"credentials">> => #{<<"headers">> => #{},
                                                       <<"endpoint">> => <<?CONSOLE_URL/binary, "/channel">>,
                                                       <<"method">> => <<"POST">>},
                                <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME}).

-define(CONSOLE_MQTT_CHANNEL_ID, <<"56789">>).
-define(CONSOLE_MQTT_CHANNEL_NAME, <<"fake_mqtt">>).
-define(CONSOLE_MQTT_CHANNEL, #{<<"type">> => <<"mqtt">>,
                                <<"credentials">> => #{<<"endpoint">> => <<"mqtt://127.0.0.1:1883">>,
                                                       <<"topic">> => <<"test/">>},
                                <<"id">> => ?CONSOLE_MQTT_CHANNEL_ID,
                                <<"name">> => ?CONSOLE_MQTT_CHANNEL_NAME}).

-define(CONSOLE_AWS_CHANNEL_ID, <<"101112">>).
-define(CONSOLE_AWS_CHANNEL_NAME, <<"fake_aws">>).
-define(CONSOLE_AWS_CHANNEL, #{<<"type">> => <<"aws">>,
                               <<"credentials">> => #{<<"aws_access_key">> => list_to_binary(os:getenv("aws_access_key")),
                                                      <<"aws_secret_key">> => list_to_binary(os:getenv("aws_secret_key")),
                                                      <<"aws_region">> => <<"us-west-1">>,
                                                      <<"topic">> => <<"helium/test">>},
                               <<"id">> => ?CONSOLE_AWS_CHANNEL_ID,
                               <<"name">> => ?CONSOLE_AWS_CHANNEL_NAME}).

-define(CONSOLE_LABELS, [#{<<"id">> => <<"label_id">>,
                           <<"name">> => <<"label_name">>,
                           <<"organization_id">> => <<"label_organization_id">>}]).
