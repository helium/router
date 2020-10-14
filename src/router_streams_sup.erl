-module(router_streams_sup).

-behaviour(supervisor).

%% API
-export([
    start_link/2
]).

-export([init/1]).

-include("router_streams.hrl").

%% API
%%
-spec start_link(string(), any()) ->
    {ok, pid()} | {error, term()}.
start_link(BaseDir, KeyPair) ->
    supervisor:start_link(?MODULE, [BaseDir, KeyPair]).


%% Private
%%

init([BaseDir, KeyPair] = _Args) ->
    Flags = #{strategy => rest_for_one},

    ListenPort =  application:get_env(router, streams_listen_port, ?LISTEN_PORT),
    %% TODO - add helper function to build the handler list
    HandlerFun = fun() ->
        [
            libp2p_stream_plaintext:handler(#{
                public_key => libp2p_keypair:public_key(KeyPair),
                handlers => [
                    libp2p_stream_mplex:handler(#{
                        handlers => [
                            blockchain_state_channel_stream:handler(#{})
                        ]})
                ]
            })
        ]
    end,
    Listener = #{
        id => router_streams_sup,
        start => {libp2p_stream_tcp_listen_sup, start_link,
            [?LISTEN_IP, ListenPort, #{cache_dir => BaseDir, handler_fn => HandlerFun}]}
    },
    {ok, {Flags, [Listener]}}.




