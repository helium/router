-module(router_chain_vars_handler).

%% ------------------------------------------------------------------
%% Stream Exports
%% ------------------------------------------------------------------
-export([
    init/0,
    handle_msg/2,
    handle_info/2
]).

init() ->
    [].

handle_msg({headers, _Headers}, StreamState) ->
    lager:debug("*** grpc client ignoring headers ~p", [_Headers]),
    StreamState;
handle_msg({data, Msg}, StreamState) ->
    lager:debug("grpc client handler received msg ~p", [Msg]),
    _ = router_chain_vars_statem:handle_msg(Msg),
    StreamState.

handle_info(_Msg, StreamState) ->
    lager:warning("grpc client unhandled msg: ~p", [_Msg]),
    StreamState.
