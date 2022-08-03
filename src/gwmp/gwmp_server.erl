%%%-------------------------------------------------------------------
%%% @author jonathanruttenberg
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 26. Jul 2022 12:07 PM
%%%-------------------------------------------------------------------
-module(gwmp_server).
-author("jonathanruttenberg").

-behaviour(gen_server).

-include_lib("router_utils/include/semtech_udp.hrl").

%% API
-export([start_link/0, handle_push_data/4, handle_pull_data/4, handle_tx_ack/4]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-record(gwmp_server_state, {
    lns_socket :: gen_udp:socket()
}).

handle_push_data(GWMPValues, #gwmp_server_state{lns_socket = LNSSocket} , IP, Port) ->
    #{
        map := Map,
        token := Token
    } = GWMPValues,
    lager:info("got PUSH_DATA: Token: ~p, Map: ~p", [Token, Map]),
    send_push_ack(IP, Port, LNSSocket, Token).

handle_pull_data(GWMPValues, #gwmp_server_state{lns_socket = LNSSocket}, IP, Port) ->
    #{
        token := Token,
        mac := MAC
    } = GWMPValues,
    lager:info("got PULL_DATA: Token: ~p, MAC: ~p", [Token, MAC]),
    send_pull_ack(IP, Port, LNSSocket, Token).

handle_tx_ack(GWMPValues, _CustomState, _IP, _Port) ->
    #{
        map := Map,
        token := Token,
        mac := MAC
    } = GWMPValues,
    lager:info("got TX_ACK: Token: ~p, Map: ~p, MAC: ~p", [Token, Map, MAC]).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec init(Args :: term()) ->
    {ok, State :: #lns_udp_state{}}
    | {ok, State :: #lns_udp_state{}, timeout() | hibernate}
    | {stop, Reason :: term()}
    | ignore.
init(Args) ->
    process_flag(trap_exit, true),
    lager:info("~p init with ~p", [?SERVER, Args]),
    Port = 1700,
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}]),
    CustomState = #gwmp_server_state{
        lns_socket = Socket
    },
    {ok, #lns_udp_state{
        socket = Socket,
        port = Port,
        custom_state = CustomState,
        handle_push_data_fun = fun handle_push_data/4,
        handle_pull_data_fun = fun handle_pull_data/4,
        handle_tx_ack_fun = fun handle_tx_ack/4
    }}.

%% @private
%% @doc Handling call messages
-spec handle_call(
    Request :: term(),
    From :: {pid(), Tag :: term()},
    State :: #lns_udp_state{}
) ->
    {reply, Reply :: term(), NewState :: #lns_udp_state{}}
    | {reply, Reply :: term(), NewState :: #lns_udp_state{}, timeout() | hibernate}
    | {noreply, NewState :: #lns_udp_state{}}
    | {noreply, NewState :: #lns_udp_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), Reply :: term(), NewState :: #lns_udp_state{}}
    | {stop, Reason :: term(), NewState :: #lns_udp_state{}}.
handle_call(_Request, _From, State = #lns_udp_state{}) ->
    {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec handle_cast(Request :: term(), State :: #lns_udp_state{}) ->
    {noreply, NewState :: #lns_udp_state{}}
    | {noreply, NewState :: #lns_udp_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #lns_udp_state{}}.
handle_cast(_Request, State = #lns_udp_state{}) ->
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec handle_info(Info :: timeout() | term(), State :: #lns_udp_state{}) ->
    {noreply, NewState :: #lns_udp_state{}}
    | {noreply, NewState :: #lns_udp_state{}, timeout() | hibernate}
    | {stop, Reason :: term(), NewState :: #lns_udp_state{}}.
handle_info(
    {udp, Socket, IP, Port, Packet},
    #lns_udp_state{socket = Socket} = State
) ->
    ok = lns_udp_utils:handle_udp(IP, Port, Packet, State),
    {noreply, State};
handle_info(Info, State = #lns_udp_state{}) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [Info, State]),
    {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec terminate(
    Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #lns_udp_state{}
) -> term().
terminate(_Reason, #lns_udp_state{socket = Socket}) ->
    ok = gen_udp:close(Socket),
    ok.

%% @private
%% @doc Convert process state when code is changed
-spec code_change(
    OldVsn :: term() | {down, term()},
    State :: #lns_udp_state{},
    Extra :: term()
) ->
    {ok, NewState :: #lns_udp_state{}} | {error, Reason :: term()}.
code_change(_OldVsn, State = #lns_udp_state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_push_ack(DestinationIP, DestinationPort, LNSSocket, Token) ->
    lager:info("Sending push_ack to ~p.", [{DestinationPort, DestinationIP}]),
    gen_udp:send(LNSSocket, DestinationIP, DestinationPort,  semtech_udp:push_ack(Token)).

send_pull_ack(DestinationIP, DestinationPort, LNSSocket, Token) ->
    lager:info("Sending pull_ack to ~p.", [{DestinationPort, DestinationIP}]),
    gen_udp:send(LNSSocket, DestinationIP, DestinationPort,  semtech_udp:pull_ack(Token)).
