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
-define(MAX_RETRIES, 3).
% V8's JS timeout in milliseconds
-define(MAX_EXECUTION_TIME, 500).

-record(state, {
    id :: binary(),
    vm :: pid() | undefined,
    context :: context() | undefined,
    function :: binary(),
    timer :: reference()
}).

-type context() :: integer() | {error, crashed | invalid_context}.

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
    State =
        case init_context(VM, Function) of
            {ok, Context} ->
                TimerRef = erlang:send_after(?TIMER, self(), timeout),
                #state{
                    id = ID,
                    vm = VM,
                    context = Context,
                    function = Function,
                    timer = TimerRef
                };
            {context_error, Error} ->
                %% Will try again upon first call to decode()
                ShortSHA = binary:part(maps:get(hash, Args), 0, 7),
                lager:error(
                    "failed creating context for V8 decoder_id=~p hash=~p error=~p",
                    [ID, ShortSHA, Error]
                ),
                TimerRef = erlang:send_after(?TIMER, self(), timeout),
                #state{
                    id = ID,
                    vm = VM,
                    context = undefined,
                    function = Function,
                    timer = TimerRef
                };
            {js_error, Error} ->
                %% When eval fails, avoid calls to that JavaScript function
                %% but need this worker (erlang process) to accommodate that
                ShortSHA = binary:part(maps:get(hash, Args, <<"unknown">>), 0, 7),
                lager:error(
                    "V8 javascript eval failed decoder_id=~p hash=~p error=~p",
                    [ID, ShortSHA, Error]
                ),
                TimerRef = erlang:send_after(?TIMER, self(), timeout),
                #state{id = ID, function = <<>>, timer = TimerRef}
        end,
    {ok, State}.

handle_call({decode, Payload, Port, UplinkDetails}, _From, #state{timer = TimerRef0} = State0) ->
    _ = erlang:cancel_timer(TimerRef0),
    TimerRef1 = erlang:send_after(?TIMER, self(), timeout),
    {Reply, State1} = decode(Payload, Port, UplinkDetails, State0, ?MAX_RETRIES),
    {reply, Reply, State1#state{timer = TimerRef1}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(timeout, #state{id = ID} = State) ->
    lager:info("context ~p has not been used for awhile, shutting down", [ID]),
    {stop, normal, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{id = ID, context = Context} = _State) when
    not erlang:is_integer(Context)
->
    ok = router_decoder_custom_sup:delete(ID),
    lager:info("decoder with invalid context ~p went down: ~p", [ID, _Reason]),
    ok;
terminate(_Reason, #state{id = ID, vm = VM, context = Context} = _State) ->
    catch erlang_v8:destroy_context(VM, Context),
    ok = router_decoder_custom_sup:delete(ID),
    lager:info("context ~p went down: ~p", [ID, _Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec init_context(VMPid :: pid(), Function :: binary()) ->
    {ok, context()} | {error, any()} | {context_error, any()} | {js_error, any()}.
init_context(VM, Function) ->
    case erlang_v8:create_context(VM) of
        {error, Error0} = Error0 ->
            %% Failure creating a context should be transient/recoverable error
            {context_error, Error0};
        {ok, Context} ->
            case erlang_v8:eval(VM, Context, Function) of
                {error, Error1} ->
                    {js_error, Error1};
                {ok, _} ->
                    {ok, Context}
            end
    end.

%% FIXME: Bringing back the retry mechanism for decoding until we have the
%% context issue figured out on a better way. If there is not context, let's try
%% at least one more time to create it. If a context was nuked by another, reset
%% and try again.
-spec decode(
    Payload :: string(),
    Port :: non_neg_integer(),
    UplinkDetails :: map(),
    State :: #state{},
    Retries :: non_neg_integer()
) -> {any(), #state{}}.
decode(_Payload, _Port, _UplinkDetails, State, 0) ->
    {{error, failed_too_many_times}, State};
decode(_Payload, _Port, _UplinkDetails, #state{function = <<>>} = State, _Retry) ->
    {{error, ignoring_invalid_javascript}, State};
decode(
    Payload,
    Port,
    UplinkDetails,
    #state{context = Ctx, vm = VM, function = Function} = State,
    Retry
) when not erlang:is_number(Ctx) ->
    %% Recover from earlier transient failure; see init() above for happy-path.
    case init_context(VM, Function) of
        {ok, Context} ->
            decode(Payload, Port, UplinkDetails, State#state{context = Context}, Retry - 1);
        Err ->
            {Err, State}
    end;
decode(
    Payload,
    Port,
    UplinkDetails,
    #state{vm = VM, context = Context0, function = Function} = State,
    Retry
) ->
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
            {ok, Context1} = init_context(VM, Function),
            decode(Payload, Port, UplinkDetails, State#state{context = Context1}, Retry - 1);
        {error, Err} ->
            %% TODO this eliminates any tolerance for intermittent
            %% errors such as an occasional payload crashing their
            %% JavaScript code, so maybe add `js_error_count` in
            %% State and a threshold test here.
            {{js_error, Err}, State#state{function = <<>>}};
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

another_test() ->
    meck:new(router_decoder_custom_sup, [passthrough]),
    meck:expect(router_decoder_custom_sup, delete, fun(_) -> ok end),

    {ok, VMPid} = router_v8:start_link(#{}),
    {ok, VM} = router_v8:get(),

    GoodFunction = <<"function Decoder() { return 1; }">>,
    BadFunction = <<"function Decoder() { returrrrrrn 1; }">>,

    GoodArgs = #{id => <<"GoodID">>, vm => VM, function => GoodFunction},
    BadArgs = #{id => <<"BadID">>, vm => VM, function => BadFunction},

    {ok, GoodPid} = ?MODULE:start_link(GoodArgs),
    Payload = erlang:binary_to_list(base64:decode(<<"AQQACgsgGAQgAAA=">>)),
    Port = 6,
    Result = 1,

    %% Make sure decodes work
    ?assertMatch({ok, Result}, ?MODULE:decode(GoodPid, Payload, Port, #{call => 1})),
    ?assertMatch({ok, Result}, ?MODULE:decode(GoodPid, Payload, Port, #{call => 2})),

    {ok, BadPid} = ?MODULE:start_link(BadArgs),
    ?assertMatch({error, _}, ?MODULE:decode(BadPid, Payload, Port, #{call => 3})),

    %% Good Decoder hasn't broken
    One = (catch ?MODULE:decode(GoodPid, Payload, Port, #{call => 4})),
    ?assertMatch({ok, Result}, One),

    gen_server:stop(GoodPid),
    gen_server:stop(BadPid),

    gen_server:stop(VMPid),
    meck:validate(router_decoder_custom_sup),
    meck:unload(router_decoder_custom_sup),
    ok.

-endif.
