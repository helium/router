%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 04. Aug 2022 11:35 AM
%%%-------------------------------------------------------------------
-module(gwmp_gateway_connections).
-author("jonathanruttenberg").

-type socket_address() :: inet:socket_address() | inet:hostname().
-type socket_port() :: inet:port_number().
-type socket_info() :: {socket_address(), socket_port()}.

-record(gateway_connection, {
    mac :: binary(),
    gateway_endpoint :: socket_info(),
    expiration_time :: integer()
}).

-define(GATEWAY_CONNECTIONS_ETS, gwmp_gateway_connections_ets).

-export([init_ets/0, lookup_connection/1, new_connection/3, delete_ets/0]).

%% API

-spec init_ets() -> ok.
init_ets() ->
    ?GATEWAY_CONNECTIONS_ETS = ets:new(?GATEWAY_CONNECTIONS_ETS, [
        public,
        named_table,
        set,
        {keypos, 2},
        {read_concurrency, false},
        {write_concurrency, false}
    ]),
    ok.

-spec delete_ets() -> ok.
delete_ets() ->
    true = ets:delete(?GATEWAY_CONNECTIONS_ETS),
    ok.

-spec new_connection(binary(), socket_info(), integer()) -> ok.
new_connection(MAC, Endpoint, LifetimeSeconds) ->
    insert_connection(#gateway_connection{
        mac = MAC,
        gateway_endpoint = Endpoint,
        expiration_time = erlang:monotonic_time(second) + LifetimeSeconds
    }).

-spec lookup_connection(binary()) -> socket_info() | undefined.
lookup_connection(MAC) ->
    case ets:lookup(?GATEWAY_CONNECTIONS_ETS, MAC) of
        [#gateway_connection{gateway_endpoint = Endpoint, expiration_time = Expiration}] ->
            case erlang:monotonic_time(second) >= Expiration of
                false ->
                    Endpoint;
                true ->
                    delete_connection(MAC),
                    undefined
            end;
        [] ->
            undefined
    end.

-spec insert_connection(#gateway_connection{}) -> ok.
insert_connection(Connection) ->
    true = ets:insert(?GATEWAY_CONNECTIONS_ETS, Connection),
    ok.

-spec delete_connection(MAC :: binary()) -> ok.
delete_connection(MAC) ->
    true = ets:delete(?GATEWAY_CONNECTIONS_ETS, MAC),
    ok.
