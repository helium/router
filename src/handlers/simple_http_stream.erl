%%%-------------------------------------------------------------------
%% @doc
%% == Simple Http Stream ==
%% This is only intended for Cargo use, more complicated packet exchange will be implemented later
%% @end
%%%-------------------------------------------------------------------
-module(simple_http_stream).

-behavior(libp2p_framed_stream).

-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
         server/4,
         client/2,
         add_stream_handler/1,
         version/0
        ]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
         init/3,
         handle_data/3,
         handle_info/3
        ]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(VERSION, "simple_http/1.0.0").

-record(state, {
                endpoint :: string() | undefined
               }).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

-spec add_stream_handler(pid()) -> ok.
add_stream_handler(Swarm) ->
    ok = libp2p_swarm:add_stream_handler(
           Swarm,
           ?VERSION,
           {libp2p_framed_stream, server, [?MODULE, self()]}
          ).

-spec version() -> string().
version() ->
    ?VERSION.

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(server, _Conn, _Args) ->
    Endpoint = application:get_env(router, simple_http_endpoint, undefined),
    {ok, #state{endpoint=Endpoint}};
init(client, _Conn, _Args) ->
    {ok, #state{}}.

handle_data(server, _Bin, #state{endpoint=undefined}=State) ->
    lager:warning("server ignoring data ~p (cause no endpoint)", [_Bin]),
    {noreply, State};
handle_data(server, Data, #state{endpoint=Endpoint}=State) ->
    lager:info("got data ~p", [Data]),
    case decode_data(Data) of
        {ok, _Packet} ->
            lager:info("decoded data ~p", [_Packet]),
            Headers = [{<<"Content-Type">>, <<"application/octet-stream">>}],
            Opts = [{use_default_pool, false}],
            try hackney:post(Endpoint, Headers, Data, Opts) of
                {ok, _StatusCode, _RespHeaders, _ClientRef} ->
                    lager:info("got result ~p", [_StatusCode]),
                    lager:debug("got result ~p", [{_StatusCode, _RespHeaders, _ClientRef}]);
                {error, _Reason} ->
                    lager:error("failed to post to ~p got error ~p", [Endpoint, _Reason])
            catch
                E:R ->
                    lager:error("failed to post to ~p got error ~p", [Endpoint, {E, R}])
            end;
        {error, Reason} ->
            lager:error("packet decode failed ~p", [Reason])
    end,
    {noreply, State};
handle_data(_Type, _Bin, State) ->
    lager:warning("~p got data ~p", [_Type, _Bin]),
    {noreply, State}.

handle_info(_Type, _Msg, State) ->
    lager:debug("~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec decode_data(binary()) -> {ok, binary()} | {error, any()}.
decode_data(Data) ->
    try helium_longfi_pb:decode_msg(Data, helium_LongFiResp_pb) of
        Packet ->
            {ok, Packet}
    catch
        E:R ->
            lager:error("got error trying to decode  ~p", [{E, R}]),
            {error, decoding}
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
