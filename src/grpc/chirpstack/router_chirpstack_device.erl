%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, Nova Labs
%%% @doc
%%%
%%% @end
%%% Created : 15. Nov 2022 11:35 AM
%%%-------------------------------------------------------------------
-module(router_chirpstack_device).
-author("jonathanruttenberg").

%% API
-export([client_connection/2, create_device/6]).

-spec client_connection(
    Host :: string(),
    Port :: integer()
) -> grpc_client:connection() | {error, term()}.
client_connection(Host, Port) ->
    client_connection(Host, Port, []).

-spec client_connection(
    Host :: string(),
    Port :: integer(),
    Options :: [grpc_client:connection_option()]
) -> grpc_client:connection() | {error, term()}.
client_connection(Host, Port, Options) ->
    case grpc_client:connect(tcp, Host, Port, Options) of
        {ok, Connection} -> Connection;
        Error -> Error
    end.

-spec create_device(
    Connection :: grpc_client:connection(),
    Name :: unicode:chardata(),
    DevEui :: unicode:chardata(),
    ApplicationId :: unicode:chardata(),
    DeviceProfileId :: unicode:chardata(),
    StreamOptions :: [grpc_client:stream_option()]
) -> ok | {error, map()}.
create_device(Connection, Name, DevEui, ApplicationId, DeviceProfileId, StreamOptions) ->
    Device = #{
        dev_eui => DevEui,
        name => Name,
        application_id => ApplicationId,
        device_profile_id => DeviceProfileId
    },
    CreateDeviceRequest = #{device => Device},
    case
        grpc_client:unary(
            Connection,
            CreateDeviceRequest,
            'api.DeviceService',
            'Create',
            device_client_pb,
            StreamOptions
        )
    of
        {ok, _} -> ok;
        Error -> Error
    end.
