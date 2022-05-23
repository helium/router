%%%-------------------------------------------------------------------
%% @doc router chain top level supervisor.
%% @end
%%%-------------------------------------------------------------------
-module(router_chain_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

-define(FLAGS, #{
    strategy => one_for_one,
    intensity => 1,
    period => 5
}).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    {ok,
        {?FLAGS, [
            ?WORKER(router_chain_vars_statem, [#{}])
        ]}}.

%%====================================================================
%% Internal functions
%%====================================================================
