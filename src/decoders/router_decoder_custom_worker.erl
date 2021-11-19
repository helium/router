%%%-------------------------------------------------------------------
%% @doc
%% == Custom Decoder Worker ==
%%
%% Decodes payloads with javascript functions using erlang_v8.
%%
%% If a Decoder has not been used in a while, it will decommission itself.
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_decoder_custom_worker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    decode/4
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(TIMER, timer:hours(48)).
% V8's JS timeout in milliseconds
-define(MAX_EXECUTION_TIME, 500).
-define(INIT_CONTEXT, init_context).
-define(BACKOFF_MIN, timer:seconds(15)).
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    id :: binary(),
    vm :: pid(),
    context :: context() | undefined,
    function :: binary(),
    timer :: reference(),
    backoff :: any()
}).

-type context() :: integer().

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

-spec decode(pid(), string(), integer(), map()) -> {ok, any()} | {error, any()}.
decode(Pid, Payload, Port, UplinkDetails) ->
    gen_server:call(Pid, {decode, Payload, Port, UplinkDetails}, ?MAX_EXECUTION_TIME).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ID = maps:get(id, Args),
    VM = maps:get(vm, Args),
    Function = maps:get(function, Args),
    TimerRef = erlang:send_after(?TIMER, self(), timeout),
    self() ! ?INIT_CONTEXT,
    State = #state{
        id = ID,
        vm = VM,
        context = undefined,
        function = Function,
        timer = TimerRef,
        backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal)
    },
    {ok, State}.

handle_call({decode, _Payload, _Port, _UplinkDetails}, _From, #state{context = undefined} = State0) ->
    {reply, {error, no_context}, State0};
handle_call(
    {decode, Payload, Port, UplinkDetails},
    _From,
    #state{vm = VM, context = Context0, timer = TimerRef0, backoff = Backoff0} = State0
) ->
    _ = erlang:cancel_timer(TimerRef0),
    TimerRef1 = erlang:send_after(?TIMER, self(), timeout),
    State1 = State0#state{timer = TimerRef1},
    case
        erlang_v8:call(
            VM,
            Context0,
            <<"Decoder">>,
            [Payload, Port, UplinkDetails],
            ?MAX_EXECUTION_TIME
        )
    of
        {error, invalid_context} ->
            %% Execution reaching here implies V8 vm restarted recently
            {Delay, Backoff1} = backoff:fail(Backoff0),
            %% Refresh their Context and JS definition:
            _ = erlang:send_after(Delay, self(), ?INIT_CONTEXT),
            {reply, {error, invalid_context}, State1#state{
                context = undefined,
                backoff = Backoff1
            }};
        {error, Reason0} = Error ->
            %% Track repeat offenders of bad JS code via external monitoring
            Reason1 =
                case size(Reason0) of
                    N when N =< 10 -> Reason0;
                    _ -> binary:part(Reason0, 0, 10)
                end,
            lager:error(
                "V8 call error=\"~p\" device_id=~p app_eui=~p dev_eui=~p",
                [
                    Reason1,
                    maps:get(device_id, UplinkDetails, unknown),
                    maps:get(app_eui, UplinkDetails, unknown),
                    maps:get(dev_eui, UplinkDetails, unknown)
                ]
            ),
            %% Due to limited error granularity from V8 Port, restart after any error:
            erlang_v8:restart_vm(VM),
            {reply, Error, State1};
        {ok, _} = OK ->
            {reply, OK, State1}
    end;
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    ?INIT_CONTEXT,
    #state{id = ID, vm = VM, function = Function, backoff = Backoff0} = State
) ->
    case init_context(VM, Function) of
        {ok, Context} ->
            {_Delay, Backoff1} = backoff:succeed(Backoff0),
            {noreply, State#state{context = Context, backoff = Backoff1}};
        {error, _Reason} ->
            lager:warning("failed to init context for ~p with ~p error: ~p", [ID, Function, _Reason]),
            {Delay, Backoff1} = backoff:fail(Backoff0),
            _ = erlang:send_after(Delay, self(), ?INIT_CONTEXT),
            {noreply, State#state{backoff = Backoff1}}
    end;
handle_info(timeout, #state{id = ID} = State) ->
    lager:info("context ~p has not been used for awhile, shutting down", [ID]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{id = ID, vm = VM, context = Context} = _State) ->
    catch erlang_v8:destroy_context(VM, Context),
    ok = router_decoder_custom_sup:delete(ID),
    lager:info("context ~p went down: ~p", [ID, _Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_context(VMPid :: pid(), Function :: binary()) -> {ok, context()} | {error, any()}.
init_context(VM, Function) ->
    case erlang_v8:create_context(VM) of
        {error, _} = Error0 ->
            Error0;
        {ok, Context} ->
            case erlang_v8:eval(VM, Context, Function) of
                {error, _} = Error1 ->
                    Error1;
                {ok, _} ->
                    {ok, Context}
            end
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
    Function =
        <<"\n"
            "function bytesToInt(by) {\n"
            "                         f = by[0] | by[1]<<8 | by[2]<<16 | by[3]<<24;\n"
            "                                                                   return f;\n"
            "                                                                   } \n"
            "  \n"
            "function bytesToFloat(by) {\n"
            "    var bits = by[3]<<24 | by[2]<<16 | by[1]<<8 | by[0];\n"
            "    var sign = (bits>>>31 === 0) ? 1.0 : -1.0;\n"
            "    var e = bits>>>23 & 0xff;\n"
            "    var m = (e === 0) ? (bits & 0x7fffff)<<1 : (bits & 0x7fffff) | 0x800000;\n"
            "    var f = sign * m * Math.pow(2, e - 150);\n"
            "    return f;\n"
            "} \n"
            "  \n"
            "function Decoder(bytes, port) {\n"
            "  \n"
            "    var decoded = {};\n"
            "    i = 0;\n"
            "  \n"
            "    decoded.latitude = bytesToFloat(bytes.slice(i,i+=4));\n"
            "    decoded.longitude = bytesToFloat(bytes.slice(i,i+=4));\n"
            "    decoded.altitude = bytesToFloat(bytes.slice(i,i+=4));\n"
            "    decoded.course = bytesToFloat(bytes.slice(i,i+=4));\n"
            "    decoded.speed = bytesToFloat(bytes.slice(i,i+=4));\n"
            "    decoded.hdop = bytesToFloat(bytes.slice(i,i+=4));\n"
            "  \n"
            "    decoded.battery = ((bytes[i++] << 8) | bytes[i++]);\n"
            "\n"
            "    return decoded;\n"
            "}\n">>,
    Args = #{id => ID, vm => VM, function => Function},
    {ok, Pid} = ?MODULE:start_link(Args),

    Payload1 = erlang:binary_to_list(base64:decode(<<"gY0HQi0LqcLNzDRDpHBEQ6VOCECamalADzo=">>)),
    Result1 = #{
        <<"altitude">> => 180.8000030517578,
        <<"battery">> => 3898,
        <<"course">> => 196.44000244140625,
        <<"hdop">> => 5.300000190734863,
        <<"latitude">> => 33.888187408447266,
        <<"longitude">> => -84.5218276977539,
        <<"speed">> => 2.1298000812530518
    },
    Port = 6,

    lists:foreach(
        fun(X) ->
            case X rem 2 of
                0 ->
                    ?assertMatch({ok, Result1}, ?MODULE:decode(Pid, Payload1, Port, #{}));
                _ ->
                    ?assertMatch({ok, _}, ?MODULE:decode(Pid, lists:seq(1, X), Port, #{}))
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
    Function =
        <<"\n"
            "function Decoder(bytes, port) { \n"
            "  var decoded = {};\n"
            "  if (bytes[0] == 1) {\n"
            "    decoded.reportType = bytes[0];\n"
            "    decoded.deviceType = bytes[1];\n"
            "    decoded.voltage = bytes[3]/10;\n"
            "    decoded.illuminance = (bytes[4]<<8 | bytes[5])\n"
            "  }\n"
            "  return decoded; \n"
            "}\n">>,
    Args = #{id => ID, vm => VM, function => Function},
    {ok, Pid} = ?MODULE:start_link(Args),

    Payload0 = erlang:binary_to_list(base64:decode(<<"AQQACgsgGAQgAAA=">>)),
    Result0 = #{
        <<"deviceType">> => 4,
        <<"illuminance">> => 2848,
        <<"reportType">> => 1,
        <<"voltage">> => 1
    },

    Payload1 = erlang:binary_to_list(base64:decode(<<"AQQBHgAJAAAAAAA=">>)),
    Result1 = #{
        <<"deviceType">> => 4,
        <<"illuminance">> => 9,
        <<"reportType">> => 1,
        <<"voltage">> => 3
    },
    Port = 6,

    ?assertMatch({ok, Result0}, ?MODULE:decode(Pid, Payload0, Port, #{})),
    ?assertMatch({ok, Result1}, ?MODULE:decode(Pid, Payload1, Port, #{})),

    %% Confirm JavaScript engine ignores extra parameter when populated,
    %% needed due to JS semantics for equivalence of false, 0, {}, etc.
    UplinkInfo = #{
        <<"dev_eui">> => lorawan_utils:binary_to_hex(<<0, 0, 0, 0, 0, 0, 0, 1>>),
        <<"app_eui">> => lorawan_utils:binary_to_hex(<<0, 0, 0, 2, 0, 0, 0, 1>>),
        <<"fcnt">> => 1,
        <<"reported_at">> => 2147483647,
        <<"devaddr">> => lorawan_utils:binary_to_hex(<<1>>)
    },
    ?assertMatch({ok, Result1}, ?MODULE:decode(Pid, Payload1, Port, UplinkInfo)),

    gen_server:stop(Pid),
    gen_server:stop(VMPid),
    ?assert(meck:validate(router_decoder_custom_sup)),
    meck:unload(router_decoder_custom_sup),
    ok.

with_uplink_info_test() ->
    meck:new(router_decoder_custom_sup, [passthrough]),
    meck:expect(router_decoder_custom_sup, delete, fun(_) -> ok end),

    {ok, VMPid} = router_v8:start_link(#{}),

    ID = <<"ID">>,
    {ok, VM} = router_v8:get(),
    Function =
        <<"\n"
            "function Decoder(bytes, port, uplink_info) { \n"
            "  var decoded = {};\n"
            "  if (uplink_info) {\n"
            "    decoded.dev_eui = uplink_info.dev_eui;\n"
            "    decoded.app_eui = uplink_info.app_eui;\n"
            "    decoded.fcnt = uplink_info.fcnt;\n"
            "    decoded.reported_at = uplink_info.reported_at;\n"
            "    decoded.devaddr = uplink_info.devaddr;\n"
            "  }\n"
            "  return decoded; \n"
            "}\n">>,

    Args = #{id => ID, vm => VM, function => Function},
    {ok, Pid} = ?MODULE:start_link(Args),

    UplinkInfo = #{
        <<"dev_eui">> => lorawan_utils:binary_to_hex(<<0, 0, 0, 0, 0, 0, 0, 1>>),
        <<"app_eui">> => lorawan_utils:binary_to_hex(<<0, 0, 0, 2, 0, 0, 0, 1>>),
        <<"fcnt">> => 1,
        <<"reported_at">> => 2147483647,
        <<"devaddr">> => lorawan_utils:binary_to_hex(<<1>>)
    },
    Result = UplinkInfo,
    Port = 6,

    ?assertMatch({ok, Result}, ?MODULE:decode(Pid, [], Port, UplinkInfo)),

    gen_server:stop(Pid),
    gen_server:stop(VMPid),
    ?assert(meck:validate(router_decoder_custom_sup)),
    meck:unload(router_decoder_custom_sup),
    ok.

-endif.
