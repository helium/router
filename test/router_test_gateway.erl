-module(router_test_gateway).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/1,
    pubkey_bin/1,
    send_packet/2,
    receive_send_packet/1,
    receive_env_down/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(SEND_PACKET, send).

-record(state, {
    forward :: pid(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: libp2p_crypto:sig_fun(),
    stream :: grpcbox_client:stream()
}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%%% API Function Definitions
%% ------------------------------------------------------------------

-spec start(Args :: map()) -> any().
start(Args) ->
    gen_server:start(?SERVER, Args, []).

-spec pubkey_bin(Pid :: pid()) -> libp2p_crypto:pubkey_bin().
pubkey_bin(Pid) ->
    gen_server:call(Pid, pubkey_bin).

-spec send_packet(Pid :: pid(), Args :: map()) -> ok.
send_packet(Pid, Args) ->
    gen_server:cast(Pid, {?SEND_PACKET, Args}).

-spec receive_send_packet(GatewayPid :: pid()) ->
    {ok, EnvDown :: hpr_envelope_up:envelope()} | {error, timeout}.
receive_send_packet(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, {?SEND_PACKET, EnvUp}} ->
            {ok, EnvUp}
    after timer:seconds(2) ->
        {error, timeout}
    end.

-spec receive_env_down(GatewayPid :: pid()) ->
    {ok, EnvDown :: hpr_envelope_down:envelope()} | {error, timeout}.
receive_env_down(GatewayPid) ->
    receive
        {?MODULE, GatewayPid, {data, EnvDown}} ->
            {ok, EnvDown}
    after timer:seconds(2) ->
        {error, timeout}
    end.

%% ------------------------------------------------------------------
%%% gen_server Function Definitions
%% ------------------------------------------------------------------
-spec init(map()) -> {ok, state()}.
init(#{forward := Pid} = Args) ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ed25519),
    lager:info(maps:to_list(Args), "started"),

    {ok, Stream} = helium_packet_route_packet_client:route(),
    {ok, #state{
        forward = Pid,
        pubkey_bin = libp2p_crypto:pubkey_to_bin(PubKey),
        sig_fun = libp2p_crypto:mk_sig_fun(PrivKey),
        stream = Stream
    }}.

handle_call(pubkey_bin, _From, #state{pubkey_bin = PubKeyBin} = State) ->
    {reply, PubKeyBin, State};
handle_call(_Msg, _From, State) ->
    lager:debug("unknown call ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(
    {?SEND_PACKET, Args},
    #state{
        forward = Pid,
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        stream = Stream
    } =
        State
) ->
    PacketUp = test_utils:uplink_packet_up(Args#{
        gateway => PubKeyBin, sig_fun => SigFun
    }),
    EnvUp = hpr_envelope_up:new(PacketUp),
    ok = grpcbox_client:send(Stream, EnvUp),
    Pid ! {?MODULE, self(), {?SEND_PACKET, EnvUp}},
    lager:debug("send_packet ~p", [EnvUp]),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:debug("unknown cast ~p", [_Msg]),
    {noreply, State}.

%% GRPC stream callbacks
handle_info({send, SCPacket}, #state{} = State) ->
    ct:print("test gateway sending packet: ~p", [SCPacket]),
    ok = ?MODULE:send_packet(self(), SCPacket),
    {noreply, State};
handle_info({data, _StreamID, Data}, #state{forward = Pid} = State) ->
    lager:debug("got data ~p", [Data]),
    Pid ! {?MODULE, self(), {data, Data}},
    {noreply, State};
handle_info(
    {'DOWN', Ref, process, Pid, _Reason},
    #state{stream = #{stream_pid := Pid, monitor_ref := Ref}} = State
) ->
    lager:debug("test gateway stream went down"),
    {noreply, State#state{stream = undefined}};
handle_info({headers, _StreamID, _Headers}, State) ->
    {noreply, State};
handle_info({trailers, _StreamID, _Trailers}, State) ->
    {noreply, State};
handle_info(_Msg, State) ->
    lager:debug("unknown info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, #state{forward = Pid, stream = Stream}) ->
    ok = grpcbox_client:close_send(Stream),
    Pid ! {?MODULE, self(), {terminate, Stream}},
    lager:debug("terminate ~p", [_Reason]),
    ok.

%% ------------------------------------------------------------------
%%% Internal Function Definitions
%% ------------------------------------------------------------------
