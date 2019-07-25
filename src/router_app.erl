%%%-------------------------------------------------------------------
%% @doc router public API
%% @end
%%%-------------------------------------------------------------------

-module(router_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    PoolName = simple_http_stream,
    Options = [{max_connections, 1000}],
    ok = hackney_pool:start_pool(PoolName, Options),
    router_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
