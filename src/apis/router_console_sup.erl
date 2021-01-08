-module(router_console_sup).

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
    DeviceAPIData = maps:from_list(application:get_env(router, router_console_device_api, [])),
    {ok,
        {?FLAGS, [
            ?WORKER(router_console_device_api, [DeviceAPIData]),
            ?WORKER(router_console_dc_tracker, [#{}])
        ]}}.

%%====================================================================
%% Internal functions
%%====================================================================
