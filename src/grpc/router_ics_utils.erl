%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_utils).

-export([
    start_link_args/1,
    channel/0,
    connect/3
]).

-define(ICS_CHANNEL, ics_channel).

-spec start_link_args(map()) -> ignore | map().
start_link_args(#{transport := ""}) ->
    ignore;
start_link_args(#{host := ""}) ->
    ignore;
start_link_args(#{port := ""}) ->
    ignore;
start_link_args(#{transport := "http"} = Args) ->
    start_link_args(Args#{transport => http});
start_link_args(#{transport := "https"} = Args) ->
    start_link_args(Args#{transport => https});
start_link_args(#{port := Port} = Args) when is_list(Port) ->
    start_link_args(Args#{port => erlang:list_to_integer(Port)});
start_link_args(#{transport := Transport, host := Host, port := Port} = Args) when
    is_atom(Transport) andalso is_list(Host) andalso is_integer(Port)
->
    Args;
start_link_args(_) ->
    ignore.

channel() ->
    ?ICS_CHANNEL.

-spec connect(Transport :: http | https, Host :: string(), Port :: non_neg_integer()) ->
    ok | {error, any()}.
connect(Transport, Host, Port) ->
    case grpcbox_channel:pick(?MODULE:channel(), stream) of
        {error, _} ->
            case
                grpcbox_client:connect(?MODULE:channel(), [{Transport, Host, Port, []}], #{
                    sync_start => true
                })
            of
                {ok, _Conn} ->
                    connect(Transport, Host, Port);
                {error, {already_started, _}} ->
                    connect(Transport, Host, Port);
                {error, _Reason} = Error ->
                    Error
            end;
        {ok, {_Conn, _Interceptor}} ->
            ok
    end.
