-module(router_mqtt_sup).
-behaviour(supervisor).

%% API
-export([
         start_link/0,
         get_connection/3
        ]).

%% Supervisor callbacks
-export([init/1]).

-define(WORKER(I), 
        #{
          id => I,
          start => {I, start_link, []},
          restart => temporary,
          shutdown => 1000,
          type => worker,
          modules => [I]
         }).

-define(FLAGS, 
        #{
          strategy => simple_one_for_one,
          intensity => 3,
          period => 60
         }).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

get_connection(MAC, ChannelName, Args) ->
    case ets:lookup(router_mqtt_workers, {MAC, ChannelName}) of
        [] ->
            supervisor:start_child(?MODULE, [MAC, ChannelName, Args]);
        [{{MAC, ChannelName}, Pid}] ->
            case is_process_alive(Pid) of
                true ->
                    {ok, Pid};
                false ->
                    supervisor:start_child(?MODULE, [MAC, ChannelName, Args])
            end
    end.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    ets:new(router_mqtt_workers, [public, named_table, set]),
    {ok, _} = application:ensure_all_started(emqtt),
    {ok, {?FLAGS, [?WORKER(router_mqtt_worker)]}}.
