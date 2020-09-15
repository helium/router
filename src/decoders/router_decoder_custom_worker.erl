%%%-------------------------------------------------------------------
%% @doc
%% == Router v8 Context==
%% @end
%%%-------------------------------------------------------------------
-module(router_decoder_custom_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         decode/3]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(TIMER, timer:hours(48)).
-define(MAX_EXECUTION, 500).

-record(state, {id :: binary(),
                vm :: pid(),
                context :: pid(),
                function :: binary(),
                timer :: reference()}).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec decode(pid(), list(), integer()) -> {ok, any()} | {error, any()}.
decode(Pid, Payload, Port) ->
    gen_server:call(Pid, {decode, Payload, Port}, ?MAX_EXECUTION).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ID = maps:get(id, Args),
    VM = maps:get(vm, Args),
    Function = maps:get(function, Args),
    Context = init_context(VM, Function),
    TimerRef = erlang:send_after(?TIMER, self(), timeout),
    {ok, #state{id=ID, vm=VM, context=Context, function=Function, timer=TimerRef}}.

handle_call({decode, Payload, Port}, _From, #state{timer=TimerRef0}=State0) ->
    _ = erlang:cancel_timer(TimerRef0),
    {Reply, State1} = decode(Payload, Port, State0, 3),
    TimerRef1 = erlang:send_after(?TIMER, self(), timeout),
    {reply, Reply, State1#state{timer=TimerRef1}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(timeout, #state{id=ID}=State) ->
    lager:info("context ~p has not been used for awhile, shutting down", [ID]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{id=ID, vm=VM, context=Context}=_State) ->
    catch erlang_v8:destroy_context(VM, Context),
    ok = router_decoder_custom_sup:delete(ID),
    lager:info("context ~p went down: ~p", [ID, _Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_context(pid(), binary()) -> any().
init_context(VM, Function) ->
    {ok, Context} = erlang_v8:create_context(VM),
    {ok, _} = erlang_v8:eval(VM, Context, Function),
    Context.

-spec decode(binary(), non_neg_integer(), state(), non_neg_integer()) -> {any(), state()}.
decode(_Payload, _Port, State, 0) ->
    {{error, failed_too_many_times}, State};
decode(Payload, Port, #state{vm=VM, context=Context0, function=Function}=State, Retry) ->
    case erlang_v8:call(VM, Context0, <<"Decoder">>, [Payload, Port], ?MAX_EXECUTION) of
        {error, invalid_context} ->
            Context1 = init_context(VM, Function),
            decode(Payload, Port, State#state{context=Context1}, Retry-1);
        Reply ->
            {Reply, State}
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

load_test() ->
    meck:new(router_decoder_custom_sup, [passthrough]),
    meck:expect(router_decoder_custom_sup, delete, fun(_) -> ok end),

    {ok, VMPid} = router_v8:start_link(#{}),

    ID = <<"ID">>,
    {ok, VM} = router_v8:get(),
    Function = <<"
function bytesToInt(by) {
                         f = by[0] | by[1]<<8 | by[2]<<16 | by[3]<<24;
                                                                   return f;
                                                                   } 
  
function bytesToFloat(by) {
    var bits = by[3]<<24 | by[2]<<16 | by[1]<<8 | by[0];
    var sign = (bits>>>31 === 0) ? 1.0 : -1.0;
    var e = bits>>>23 & 0xff;
    var m = (e === 0) ? (bits & 0x7fffff)<<1 : (bits & 0x7fffff) | 0x800000;
    var f = sign * m * Math.pow(2, e - 150);
    return f;
} 
  
function Decoder(bytes, port) {
  
    var decoded = {};
    i = 0;
  
    decoded.latitude = bytesToFloat(bytes.slice(i,i+=4));
    decoded.longitude = bytesToFloat(bytes.slice(i,i+=4));
    decoded.altitude = bytesToFloat(bytes.slice(i,i+=4));
    decoded.course = bytesToFloat(bytes.slice(i,i+=4));
    decoded.speed = bytesToFloat(bytes.slice(i,i+=4));
    decoded.hdop = bytesToFloat(bytes.slice(i,i+=4));
  
    decoded.battery = ((bytes[i++] << 8) | bytes[i++]);

    return decoded;
}
">>,
    Args = #{id => ID, vm => VM, function => Function},
    {ok, Pid} = ?MODULE:start_link(Args),

    Payload1 = erlang:binary_to_list(base64:decode(<<"gY0HQi0LqcLNzDRDpHBEQ6VOCECamalADzo=">>)),
    Result1 = #{<<"altitude">> => 180.8000030517578,
                       <<"battery">> => 3898,
                       <<"course">> => 196.44000244140625,
                       <<"hdop">> => 5.300000190734863,
                       <<"latitude">> => 33.888187408447266,
                       <<"longitude">> => -84.5218276977539,
                       <<"speed">> => 2.1298000812530518},
    Port = 6,

    lists:foreach(
        fun(X) ->
            case X rem 2 of
                0 ->
                     ?assertMatch({ok, Result1}, ?MODULE:decode(Pid, Payload1, Port));
                _ ->
                    ?assertMatch({ok, _}, ?MODULE:decode(Pid, lists:seq(1, X), Port))
            end
        end,
        lists:seq(1, 1000)
    ),
   
    gen_server:stop(Pid),
    gen_server:stop(VMPid),
    ?assert(meck:validate(router_decoder_custom_sup)),
    meck:unload(router_decoder_custom_sup),
    ok.

random_test() ->
    meck:new(router_decoder_custom_sup, [passthrough]),
    meck:expect(router_decoder_custom_sup, delete, fun(_) -> ok end),

    {ok, VMPid} = router_v8:start_link(#{}),

    ID = <<"ID">>,
    {ok, VM} = router_v8:get(),
    Function = <<"
function Decoder(bytes, port) { 
  var decoded = {};
  if (bytes[0] == 1) {
    decoded.reportType = bytes[0];
    decoded.deviceType = bytes[1];
    decoded.voltage = bytes[3]/10;
    decoded.illuminance = (bytes[4]<<8 | bytes[5])
  }
  return decoded; 
}
">>,
    Args = #{id => ID, vm => VM, function => Function},
    {ok, Pid} = ?MODULE:start_link(Args),

    Payload0 = erlang:binary_to_list(base64:decode(<<"AQQACgsgGAQgAAA=">>)),
    Result0 = #{<<"deviceType">> => 4,<<"illuminance">> => 2848,
                       <<"reportType">> => 1,<<"voltage">> => 1},

    Payload1 = erlang:binary_to_list(base64:decode(<<"AQQBHgAJAAAAAAA=">>)),
    Result1 = #{<<"deviceType">> => 4,<<"illuminance">> => 9,
                       <<"reportType">> => 1,<<"voltage">> => 3},
    Port = 6,

    ?assertMatch({ok, Result0}, ?MODULE:decode(Pid, Payload0, Port)),
    ?assertMatch({ok, Result1}, ?MODULE:decode(Pid, Payload1, Port)),
   
    gen_server:stop(Pid),
    gen_server:stop(VMPid),
    ?assert(meck:validate(router_decoder_custom_sup)),
    meck:unload(router_decoder_custom_sup),
    ok.

-endif.
