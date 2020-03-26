-define(CONSOLE_DEVICE_ID, <<"yolo_id">>).
-define(CONSOLE_DEVICE_NAME, <<"yolo_name">>).

-define(CONSOLE_HTTP_CHANNEL_ID, <<"12345">>).
-define(CONSOLE_HTTP_CHANNEL_NAME, <<"fake_http">>).
-define(CONSOLE_HTTP_CHANNEL, #{<<"type">> => <<"http">>,
                                <<"credentials">> => #{<<"headers">> => #{},
                                                       <<"endpoint">> => <<"http://localhost:3000/channel">>,
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

-define(CONSOLE_LABELS, [#{<<"id">> => <<"label_id">>,
                           <<"name">> => <<"label_name">>,
                           <<"organization_id">> => <<"label_organization_id">>}]).
