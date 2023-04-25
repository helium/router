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
    %%
    pre_reconcile/0,
    reconcile/2,
    pre_remove_all/0,
    remove_all/2,
    %%
    update/1,
    skf_to_add_update/1,
    skf_to_remove_update/1,
    %%
    remote_skf/0,
    local_skf/0,
    diff/1,
    chunk/1,
    send_request/1,
    set_update_batch_size/1,
    partition_updates_by_action/1
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

-record(state, {
    oui :: non_neg_integer(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: function(),
    conn_backoff :: backoff:backoff(),
    route_id :: string(),
    request_chunk_size = 100 :: non_neg_integer()
}).

-record(reconcile, {
    remote :: skfs(),
    remote_count :: non_neg_integer(),
    %%
    local :: skfs(),
    local_count :: non_neg_integer(),
    %%
    updates :: skf_updates(),
    updates_count :: non_neg_integer(),
    update_chunks :: list(skf_updates()),
    update_chunks_count :: non_neg_integer(),
    %%
    add_count :: non_neg_integer(),
    remove_count :: non_neg_integer()
}).

-type skf() :: #iot_config_skf_v1_pb{}.
-type skfs() :: list(skf()).
-type skf_update() :: #iot_config_route_skf_update_v1_pb{}.
-type skf_updates() :: list(#iot_config_route_skf_update_v1_pb{}).

-type reconcile_progress_fun() :: fun(
    (
        done
        | {progress, {CurrentRequest :: non_neg_integer(), TotalRequests :: non_neg_integer()},
            Response :: #iot_config_route_skf_update_res_v1_pb{}}
    ) -> any()
).

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

-spec pre_reconcile() -> #reconcile{}.
pre_reconcile() ->
    {ok, Remote} = router_ics_skf_worker:remote_skf(),
    {ok, Local} = router_ics_skf_worker:local_skf(),
    Diff = router_ics_skf_worker:diff(#{remote => Remote, local => Local}),
    Chunks = ?MODULE:chunk(Diff),

    #{to_add := ToAdd, to_remove := ToRemove} = ?MODULE:partition_updates_by_action(Diff),

    #reconcile{
        remote = Remote,
        remote_count = erlang:length(Remote),

        local = Local,
        local_count = erlang:length(Local),

        updates = Diff,
        updates_count = erlang:length(Diff),
        update_chunks = Chunks,
        update_chunks_count = erlang:length(Chunks),

        add_count = erlang:length(ToAdd),
        remove_count = erlang:length(ToRemove)
    }.

-spec reconcile(#reconcile{}, reconcile_progress_fun()) -> ok.
reconcile(
    #reconcile{update_chunks = Requests, update_chunks_count = UpdateChunksCount},
    ProgressFun
) ->
    lists:foreach(
        fun({Idx, Request}) ->
            Resp = router_ics_skf_worker:send_request(Request),
            ProgressFun({progress, {Idx, UpdateChunksCount}, Resp})
        end,
        router_utils:enumerate_1(Requests)
    ),
    ProgressFun(done).

-spec pre_remove_all() -> #reconcile{}.
pre_remove_all() ->
    Reconcile = ?MODULE:pre_reconcile(),
    Reconcile#reconcile{local = [], local_count = 0}.

%% Alias for reconcile to keep with naming convention.
-spec remove_all(#reconcile{}, reconcile_progress_fun()) -> ok.
remove_all(Reconcile, ProgressFun) ->
    ?MODULE:reconcile(Reconcile, ProgressFun).

-spec partition_updates_by_action(skf_updates()) ->
    #{to_add := skf_updates(), to_remove := skf_updates()}.
partition_updates_by_action(Updates) ->
    {ToAdd, ToRemove} = lists:partition(
        fun(#iot_config_route_skf_update_v1_pb{action = Action}) -> Action == add end, Updates
    ),
    #{to_add => ToAdd, to_remove => ToRemove}.

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

-spec remote_skf() -> {ok, list(skf())} | {error, any()}.
remote_skf() ->
    gen_server:call(?MODULE, remote_skf).

-spec local_skf() -> {ok, list(skf())} | {error, any()}.
local_skf() ->
    gen_server:call(?MODULE, local_skf).

-spec diff(#{remote := list(skf()), local := list(skf())}) -> list(skf_update()).
diff(#{remote := _, local := _} = Diff) ->
    gen_server:call(?MODULE, {diff, Diff}).

-spec chunk(list(skf_update())) -> list(list(skf_update())).
chunk(Updates) ->
    gen_server:call(?MODULE, {chunk, Updates}).

-spec send_request(list(skf_update())) -> ok | error.
send_request(Updates) ->
    gen_server:call(?MODULE, {send_request, Updates}).

-spec set_update_batch_size(non_neg_integer()) -> ok.
set_update_batch_size(BatchSize) ->
    gen_server:call(?MODULE, {set_update_batch_size, BatchSize}).

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
        route_id = RouteID,
        request_chunk_size = application:get_env(router, update_skf_batch_size, 100)
    }}.

handle_call({set_update_batch_size, BatchSize}, _From, State) ->
    {reply, ok, State#state{request_chunk_size = BatchSize}};
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
    remote_skf,
    From,
    #state{route_id = RouteID, pubkey_bin = PubKeyBin, sig_fun = SigFun} = State
) ->
    Callback = fun(Response) -> gen_server:reply(From, Response) end,
    ok = list_skf(RouteID, PubKeyBin, SigFun, Callback),

    {noreply, State};
handle_call(local_skf, _From, #state{route_id = RouteID} = State) ->
    Local = get_local_skfs(RouteID),
    {reply, {ok, Local}, State};
handle_call({diff, #{remote := Remote, local := Local}}, _From, State) ->
    ToAdd = Local -- Remote,
    ToRemove = Remote -- Local,

    AddUpdates = ?MODULE:skf_to_add_update(ToAdd),
    RemUpdates = ?MODULE:skf_to_remove_update(ToRemove),

    Reply = AddUpdates ++ RemUpdates,
    {reply, Reply, State};
handle_call(
    {diff_skfs, RemoteSKFs},
    _From,
    #state{route_id = RouteID} = State
) ->
    LocalSKFs = get_local_skfs(RouteID),

    ToAdd = LocalSKFs -- RemoteSKFs,
    ToRemove = RemoteSKFs -- LocalSKFs,

    {reply, {ToAdd, ToRemove}, State};
handle_call({chunk, Updates}, _From, #state{request_chunk_size = RequestChunkSize} = State) ->
    Chunks = chunk(RequestChunkSize, Updates),
    {reply, Chunks, State};
handle_call({send_request, Updates}, _From, State) ->
    Reply =
        case send_update_request(Updates, State) of
            {ok, _Resp} -> ok;
            {error, _Err} -> error
        end,
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

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

%% We have to do this because the call to `helium_iot_config_gateway_client:location` can return
%% `{error, {Status, Reason}, _}` but is not in the spec...
-dialyzer({nowarn_function, send_update_request/2}).

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

chunk(Limit, Els) ->
    chunk(Limit, Els, []).

chunk(_, [], Acc) ->
    lists:reverse(Acc);
chunk(Limit, Els, Acc) ->
    case erlang:length(Els) > Limit of
        true ->
            {Chunk, Rest} = lists:split(Limit, Els),
            chunk(Limit, Rest, [Chunk | Acc]);
        false ->
            chunk(Limit, [], [Els | Acc])
    end.

%% -spec forward_reconcile(
%%     map(), Result :: {ok, list(), list()} | {error, any()}
%% ) -> ok.
%% forward_reconcile(#{forward_pid := undefined}, _Result) ->
%%     ok;
%% forward_reconcile(#{forward_pid := Pid}, Result) when is_pid(Pid) ->
%%     catch Pid ! {?MODULE, Result},
%%     ok.
