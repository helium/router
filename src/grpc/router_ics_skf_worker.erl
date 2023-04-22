%%%-------------------------------------------------------------------
%% @doc
%% == Router IOT Config Service Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_ics_skf_worker).

-behavior(gen_server).

-include("./autogen/iot_config_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    reconcile/1,
    update/1,
    list_skf/0,
    diff_skfs/1,
    is_reconciling/0,
    skf_to_add_update/1,
    skf_to_remove_update/1,

    %%
    remove_all_skf/1,
    %%
    new_progress_tracker/0
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

-define(SERVER, ?MODULE).
-define(INIT, init).
-define(RECONCILE_START, reconcile_start).
-define(RECONCILE_END, reconcile_end).
-define(UPDATE, update).

-ifdef(TEST).
-define(BACKOFF_MIN, 100).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-record(tracker, {
    caller :: pid(),
    batch_cnt :: non_neg_integer(),
    success :: [any()],
    error :: [any()]
}).

-record(state, {
    oui :: non_neg_integer(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: function(),
    conn_backoff :: backoff:backoff(),
    reconciling = false :: boolean(),
    route_id :: string()
}).

%% -type state() :: #state{}.

-type skf() :: #iot_config_skf_v1_pb{}.
-type skf_update() :: #iot_config_route_skf_update_v1_pb{}.

-type tracker() :: #tracker{}.

-spec new_progress_tracker() -> tracker().
new_progress_tracker() ->
    #tracker{caller = self(), batch_cnt = 0, success = [], error = []}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    case Args of
        #{skf_enabled := "true"} = Map ->
            case maps:get(route_id, Map, "") of
                "" ->
                    lager:warning("~p enabled, but no route_id provided, ignoring", [?MODULE]),
                    ignore;
                _ ->
                    gen_server:start_link({local, ?SERVER}, ?SERVER, Map, [])
            end;
        _ ->
            lager:warning("~s ignored ~p", [?MODULE, Args]),
            ignore
    end.

-spec reconcile(Commit :: boolean() | commit | dry_run) -> ok.
reconcile(commit) ->
    ?MODULE:reconcile(true);
reconcile(dry_run) ->
    ?MODULE:reconcile(false);
reconcile(Commit) ->
    gen_server:cast(?SERVER, {?RECONCILE_START, #{forward_pid => self(), commit => Commit}}).

-spec update(Updates :: list({add | remove, non_neg_integer(), binary()})) ->
    ok.
update([]) ->
    ok;
update(Updates) ->
    Limit = application:get_env(router, update_skf_batch_size, 100),
    case erlang:length(Updates) > Limit of
        true ->
            {Update, Rest} = lists:split(Limit, Updates),
            gen_server:cast(?SERVER, {?UPDATE, Update}),
            update(Rest);
        false ->
            gen_server:cast(?SERVER, {?UPDATE, Updates})
    end.

-spec list_skf() -> {ok, list(#iot_config_skf_v1_pb{})} | {error, any()}.
list_skf() ->
    gen_server:call(?SERVER, list_skf).

-spec remove_all_skf(Options :: map()) -> ok.
remove_all_skf(#{progress_callback := _, done_callback := _} = Options) ->
    gen_server:cast(?SERVER, {remove_all_skf, Options}).

-spec diff_skfs(list(skf())) -> {list(skf()), list(skf())}.
diff_skfs(SKFs) ->
    gen_server:call(?SERVER, {diff_skfs, SKFs}).

-spec is_reconciling() -> boolean().
is_reconciling() ->
    gen_server:call(?SERVER, is_reconciling).

-spec done_reconciling(Options :: map()) -> ok.
done_reconciling(Options) ->
    gen_server:cast(?SERVER, {done_reconciling, Options}).

-spec skf_to_add_update
    (skf()) -> skf_update();
    (list(skf())) -> list(skf_update()).
skf_to_add_update(SKFs) when erlang:is_list(SKFs) ->
    lists:map(fun skf_to_add_update/1, SKFs);
skf_to_add_update(#iot_config_skf_v1_pb{devaddr = Devaddr, session_key = SessionKey}) ->
    #iot_config_route_skf_update_v1_pb{
        action = add,
        devaddr = Devaddr,
        session_key = SessionKey
    }.

-spec skf_to_remove_update
    (skf()) -> skf_update();
    (list(skf())) -> list(skf_update()).
skf_to_remove_update(SKFs) when erlang:is_list(SKFs) ->
    lists:map(fun skf_to_remove_update/1, SKFs);
skf_to_remove_update(#iot_config_skf_v1_pb{devaddr = Devaddr, session_key = SessionKey}) ->
    #iot_config_route_skf_update_v1_pb{
        action = remove,
        devaddr = Devaddr,
        session_key = SessionKey
    }.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(
    #{
        pubkey_bin := PubKeyBin,
        sig_fun := SigFun,
        route_id := RouteID
    } = Args
) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
    %% ok = ?MODULE:reconcile(undefined, true),
    {ok, #state{
        oui = router_utils:get_oui(),
        pubkey_bin = PubKeyBin,
        sig_fun = SigFun,
        conn_backoff = Backoff,
        route_id = RouteID
    }}.

handle_call(
    list_skf,
    From,
    #state{route_id = RouteID, pubkey_bin = PubKeyBin, sig_fun = SigFun} = State
) ->
    lager:info("listing skfs"),
    Callback = fun(Response) -> gen_server:reply(From, Response) end,
    ok = list_skf(RouteID, PubKeyBin, SigFun, Callback),

    {noreply, State};
handle_call(
    {diff_skfs, RemoteSKFs},
    _From,
    #state{route_id = RouteID} = State
) ->
    LocalSKFs = get_local_skfs(RouteID),

    ToAdd = LocalSKFs -- RemoteSKFs,
    ToRemove = RemoteSKFs -- LocalSKFs,

    {reply, {ToAdd, ToRemove}, State};
handle_call(is_reconciling, _From, #state{reconciling = Reconciling} = State) ->
    ct:print("checking reconciling: ~p~n~p", [Reconciling, erlang:process_info(self(), messages)]),
    {reply, Reconciling, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({done_reconciling, Options}, #state{} = State) ->
    case maps:get(forward_pid, Options, undefined) of
        undefined -> ok;
        Pid -> Pid ! {?MODULE, done}
    end,
    {noreply, State#state{reconciling = false}};
handle_cast(
    {?RECONCILE_START, #{commit := Commit} = Options},
    #state{route_id = RouteID, pubkey_bin = PubKeyBin, sig_fun = SigFun} = State
) ->
    ok = list_skf(
        RouteID,
        PubKeyBin,
        SigFun,
        fun(ListResults) ->
            case ListResults of
                {ok, Remote} ->
                    {ToAdd, ToRemove} = ?MODULE:diff_skfs(Remote),
                    case Commit of
                        true ->
                            ?MODULE:update(?MODULE:skf_to_add_update(ToAdd)),
                            ?MODULE:update(?MODULE:skf_to_remove_update(ToRemove));
                        false ->
                            ok
                    end,
                    %% ok = forward_reconcile(Options, {ok, ToAdd, ToRemove}),
                    done_reconciling(Options);
                Err ->
                    ok = forward_reconcile(Options, Err),
                    ct:print("something went wrong: ~p", [Err])
            end
        end
    ),
    {noreply, State#state{reconciling = true}};
handle_cast(
    {remove_all_skf, Options},
    #state{route_id = RouteID, pubkey_bin = PubKeyBin, sig_fun = SigFun} = State
) ->
    ok = list_skf(
        RouteID,
        PubKeyBin,
        SigFun,
        fun(ListResults) ->
            case ListResults of
                {ok, Remote} ->
                    ToRemove = ?MODULE:skf_to_remove_update(Remote),
                    ?MODULE:update(ToRemove, Options),

                    ok;
                _Err ->
                    bad
            end
        end
    ),

    {noreply, State#state{}};
handle_cast(
    {?UPDATE, Updates0},
    State
) ->
    Updates1 = lists:map(
        fun
            (#iot_config_route_skf_update_v1_pb{} = Update) ->
                Update;
            ({Action, Devaddr, Key}) ->
                #iot_config_route_skf_update_v1_pb{
                    action = Action,
                    devaddr = Devaddr,
                    session_key = binary:encode_hex(Key)
                }
        end,
        Updates0
    ),

    case send_update_request(Updates1, State) of
        {ok, Resp} ->
            lager:info("updating skf good success: ~p", [Resp]);
        {error, Err} ->
            lager:error("updating skf bad failure: ~p", [Err])
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({headers, _StreamID, _Data}, State) ->
    {noreply, State};
handle_info({trailers, _StreamID, _Data}, State) ->
    {noreply, State};
handle_info({eos, _StreamID}, State) ->
    {noreply, State};
handle_info({'END_STREAM', _StreamID}, State) ->
    {noreply, State};
handle_info({'DOWN', _Ref, _Type, _Pid, _Reason}, State) ->
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ct:print("~p died: ~p", [?MODULE, _Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

send_update_request(Updates, #state{pubkey_bin = PubKeyBin, route_id = RouteID, sig_fun = SigFun}) ->
    Request = #iot_config_route_skf_update_req_v1_pb{
        route_id = RouteID,
        updates = Updates,
        timestamp = erlang:system_time(millisecond),
        signer = PubKeyBin
    },
    EncodedRequest = iot_config_pb:encode_msg(Request),
    SignedRequest = Request#iot_config_route_skf_update_req_v1_pb{
        signature = SigFun(EncodedRequest)
    },
    Res =
        case
            helium_iot_config_route_client:update_skfs(
                SignedRequest,
                #{channel => router_ics_utils:channel()}
            )
        of
            {ok, Resp, _Meta} ->
                lager:info("reconciling skfs good success: ~p", [Resp]),
                {ok, Resp};
            {error, Err} ->
                lager:error("reconciling skfs bad failure: ~p", [Err]),
                {error, Err};
            {error, Err, Meta} ->
                lager:error("reconciling skfs worst failure: ~p", [{Err, Meta}]),
                {error, {Err, Meta}}
        end,
    Res.

list_skf(RouteID, PubKeyBin, SigFun, Callback) ->
    Req = #iot_config_route_skf_list_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond),
        signer = PubKeyBin
    },
    EncodedReq = iot_config_pb:encode_msg(Req, iot_config_route_skf_list_req_v1_pb),
    SignedReq = Req#iot_config_route_skf_list_req_v1_pb{signature = SigFun(EncodedReq)},

    {ok, _Stream} = helium_iot_config_route_client:list_skfs(
        SignedReq,
        #{
            channel => router_ics_utils:channel(),
            callback_module => {router_ics_skf_list_handler, #{callback => Callback}}
        }
    ),
    ok.

-spec get_local_skfs(RouteID :: string()) ->
    [iot_config_pb:iot_config_session_key_filter_v1_pb()].
get_local_skfs(RouteID) ->
    Devices = router_device_cache:get(),
    lists:usort(
        lists:filtermap(
            fun(Device) ->
                case {router_device:devaddr(Device), router_device:nwk_s_key(Device)} of
                    {undefined, _} ->
                        false;
                    {_, undefined} ->
                        false;
                    %% devices store devaddrs reversed. Config service expects them BE.
                    {<<DevAddr:32/integer-unsigned-little>>, SessionKey} ->
                        {true, #iot_config_skf_v1_pb{
                            route_id = RouteID,
                            devaddr = DevAddr,
                            session_key = erlang:binary_to_list(binary:encode_hex(SessionKey))
                        }}
                end
            end,
            Devices
        )
    ).

-spec forward_reconcile(
    map(), Result :: {ok, list(), list()} | {error, any()}
) -> ok.
forward_reconcile(#{forward_pid := undefined}, _Result) ->
    ok;
forward_reconcile(#{forward_pid := Pid}, Result) when is_pid(Pid) ->
    catch Pid ! {?MODULE, Result},
    ok.
