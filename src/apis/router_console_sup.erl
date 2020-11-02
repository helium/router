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
    DeviceAPIModule = router_device_api:module(),
    DeviceAPIData = maps:from_list(application:get_env(router, DeviceAPIModule, [])),
    {ok,
        {?FLAGS, [
            ?WORKER(DeviceAPIModule, [DeviceAPIData]),
            ?WORKER(router_console_dc_tracker, [#{}])
        ]}}.

%%====================================================================
%% Internal functions
%%====================================================================
