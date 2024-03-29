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
    %% Reconcile/Remove All
    pre_reconcile/0,
    reconcile/2,
    pre_remove_all/0,
    remove_all/2,
    %% Worker
    add_device_ids/1,
    remove_device_ids/1,
    update/1,
    remote_skf/0,
    local_skf/0,
    send_request/1,
    set_update_batch_size/1,
    %% SKF/Upates
    diff_skf_to_updates/1,
    partition_updates_by_action/1,
    skf_to_add_update/1,
    skf_to_remove_update/1
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
-define(UPDATE, update).
-define(SKF_UPDATE_BATCH_SIZE, 100).

-ifdef(TEST).
-define(BACKOFF_MIN, 100).
-else.
-define(BACKOFF_MIN, timer:seconds(10)).
-endif.
-define(BACKOFF_MAX, timer:minutes(5)).

-record(state, {
    conn_backoff :: backoff:backoff(),
    route_id :: string()
}).

-type skf() :: #iot_config_skf_v1_pb{}.
-type skfs() :: list(skf()).
-type skf_update() :: #iot_config_route_skf_update_v1_pb{}.
-type skf_updates() :: list(#iot_config_route_skf_update_v1_pb{}).
-type skf_update_tuple() :: {
    Action :: add | remove,
    DevaddrInt :: non_neg_integer(),
    NwkSKey :: binary(),
    MultiBuy :: non_neg_integer()
}.

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

%% ------------------------------------------------------------------
%% Reconcile/Remove All API
%% ------------------------------------------------------------------

-spec pre_reconcile() -> router_skf_reconcile:reconcile().
pre_reconcile() ->
    {ok, Remote} = router_ics_skf_worker:remote_skf(),
    {ok, Local} = router_ics_skf_worker:local_skf(),
    ChunkSize = skf_update_batch_size(),
    router_skf_reconcile:new(#{remote => Remote, local => Local, chunk_size => ChunkSize}).

-spec reconcile(router_skf_reconcile:reconcile(), reconcile_progress_fun()) -> ok.
reconcile(Reconcile, ProgressFun) ->
    UpdateChunksCount = router_skf_reconcile:update_chunks_count(Reconcile),
    Requests = router_skf_reconcile:update_chunks(Reconcile),
    lists:foreach(
        fun({Idx, Request}) ->
            Resp = router_ics_skf_worker:send_request(Request),
            ProgressFun({progress, {Idx, UpdateChunksCount}, Resp})
        end,
        router_utils:enumerate_1(Requests)
    ),
    ProgressFun(done).

-spec pre_remove_all() -> router_skf_reconcile:reconcile().
pre_remove_all() ->
    {ok, Remote} = router_ics_skf_worker:remote_skf(),
    ChunkSize = skf_update_batch_size(),
    router_skf_reconcile:new(#{remote => Remote, local => [], chunk_size => ChunkSize}).

%% Alias for reconcile to keep with naming convention.
-spec remove_all(router_skf_reconcile:reconcile(), reconcile_progress_fun()) -> ok.
remove_all(Reconcile, ProgressFun) ->
    ?MODULE:reconcile(Reconcile, ProgressFun).

-spec startup_reconcile() -> ok.
startup_reconcile() ->
    Reconcile = ?MODULE:pre_reconcile(),
    ?MODULE:reconcile(
        Reconcile,
        fun
            ({progress, {Curr, Total}, {error, {{GRPCStatus, Message}, _Meta}}}) ->
                lager:error(
                    "~w/~w failed with code ~w: ~w",
                    [Curr, Total, GRPCStatus, uri_string:percent_decode(Message)]
                );
            ({progress, {Curr, Total}, {ok, _}}) ->
                lager:info("~w/~w succeeded", [Curr, Total]);
            (done) ->
                lager:info("startup reconcile complete")
        end
    ).

%% ------------------------------------------------------------------
%% Worker API
%% ------------------------------------------------------------------

-spec update(
    Updates :: list({
        add | remove,
        DevaddrInt :: non_neg_integer(),
        NwkSKey :: binary(),
        MultiBuy :: non_neg_integer()
    })
) ->
    ok.
update([]) ->
    ok;
update(Updates0) ->
    Limit = skf_update_batch_size(),
    Updates1 = ensure_skf_update(Updates0),
    Updates2 = dedup_updates(Updates1),
    case erlang:length(Updates2) > Limit of
        true ->
            {Update, Rest} = lists:split(Limit, Updates2),
            gen_server:cast(?SERVER, {?UPDATE, Update}),
            ?MODULE:update(Rest);
        false ->
            gen_server:cast(?SERVER, {?UPDATE, Updates2})
    end.

-spec add_device_ids(DeviceIDs :: [binary()]) -> ok.
add_device_ids(DeviceIDs) ->
    gen_server:cast(?SERVER, {add_device_ids, DeviceIDs}).

-spec remove_device_ids(DeviceIDs :: [binary()]) -> ok.
remove_device_ids(DeviceIDs) ->
    gen_server:cast(?SERVER, {remove_device_ids, DeviceIDs}).

-spec remote_skf() -> {ok, skfs()} | {error, any()}.
remote_skf() ->
    gen_server:call(?MODULE, remote_skf, timer:seconds(60)).

-spec local_skf() -> {ok, skfs()} | {error, any()}.
local_skf() ->
    gen_server:call(?MODULE, local_skf, timer:seconds(60)).

-spec send_request(skf_updates()) -> ok | error.
send_request(Updates) ->
    gen_server:call(?MODULE, {send_request, Updates}).

-spec set_update_batch_size(non_neg_integer()) -> ok.
set_update_batch_size(BatchSize) ->
    gen_server:call(?MODULE, {set_update_batch_size, BatchSize}).

%% ------------------------------------------------------------------
%% SKF/Updates API
%% ------------------------------------------------------------------

-spec partition_updates_by_action(skf_updates()) ->
    #{to_add := skf_updates(), to_remove := skf_updates()}.
partition_updates_by_action(Updates) ->
    {ToAdd, ToRemove} = lists:partition(
        fun(#iot_config_route_skf_update_v1_pb{action = Action}) -> Action == add end,
        Updates
    ),
    #{to_add => ToAdd, to_remove => ToRemove}.

-spec diff_skf_to_updates(#{remote := skfs(), local := skfs()}) -> skf_updates().
diff_skf_to_updates(#{remote := _, local := _} = Diff) ->
    do_skf_diff(Diff).

-spec skf_to_add_update
    (skf()) -> skf_update();
    (skfs()) -> skf_updates().
skf_to_add_update(SKFs) when erlang:is_list(SKFs) ->
    lists:map(fun skf_to_add_update/1, SKFs);
skf_to_add_update(#iot_config_skf_v1_pb{
    devaddr = Devaddr,
    session_key = SessionKey,
    max_copies = MaxCopies
}) ->
    #iot_config_route_skf_update_v1_pb{
        action = add,
        devaddr = Devaddr,
        session_key = SessionKey,
        max_copies = MaxCopies
    }.

-spec skf_to_remove_update
    (skf()) -> skf_update();
    (skfs()) -> skf_updates().
skf_to_remove_update(SKFs) when erlang:is_list(SKFs) ->
    lists:map(fun skf_to_remove_update/1, SKFs);
skf_to_remove_update(#iot_config_skf_v1_pb{
    devaddr = Devaddr,
    session_key = SessionKey,
    max_copies = MaxCopies
}) ->
    #iot_config_route_skf_update_v1_pb{
        action = remove,
        devaddr = Devaddr,
        session_key = SessionKey,
        max_copies = MaxCopies
    }.

-spec ensure_skf_update
    (skf_update_tuple()) -> skf_update();
    (skf_update()) -> skf_update();
    (list(skf_update_tuple())) -> skf_updates().
ensure_skf_update(Updates) when erlang:is_list(Updates) ->
    lists:map(fun ensure_skf_update/1, Updates);
ensure_skf_update(#iot_config_route_skf_update_v1_pb{} = Update) ->
    Update;
ensure_skf_update({Action, Devaddr, SessionKey, MaxCopies}) ->
    #iot_config_route_skf_update_v1_pb{
        action = Action,
        devaddr = Devaddr,
        session_key = binary:encode_hex(SessionKey),
        max_copies = MaxCopies
    }.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(#{route_id := RouteID} = Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Backoff = backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),

    case maps:get(reconcile_on_startup, Args, false) of
        true ->
            erlang:spawn(fun() ->
                WaitSeconds = router_utils:get_env_int(reconcile_on_startup_wait_sec, 15),
                timer:sleep(timer:seconds(WaitSeconds)),
                lager:info("startup reconcile"),
                startup_reconcile()
            end);
        false ->
            ok
    end,

    {ok, #state{
        conn_backoff = Backoff,
        route_id = RouteID
    }}.

handle_call(
    remote_skf,
    From,
    #state{route_id = RouteID} = State
) ->
    Callback = fun(Response) -> gen_server:reply(From, Response) end,
    ok = list_skf(RouteID, Callback),

    {noreply, State};
handle_call(local_skf, _From, #state{route_id = RouteID} = State) ->
    Local = get_local_skfs(RouteID),
    {reply, {ok, Local}, State};
handle_call({send_request, Updates}, _From, #state{route_id = RouteID} = State) ->
    Reply = send_update_request(RouteID, Updates),
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({add_device_ids, DeviceIDs}, #state{route_id = RouteID} = State) ->
    lager:info("adding devices: ~p", [DeviceIDs]),
    SKFs = get_add_local_devices_skfs(DeviceIDs, RouteID),
    Updates = ?MODULE:skf_to_add_update(SKFs),
    ok = ?MODULE:update(Updates),
    {noreply, State};
handle_cast({remove_device_ids, DeviceIDs}, #state{route_id = RouteID} = State) ->
    lager:info("removing devices: ~p", [DeviceIDs]),
    SKFs = get_remove_local_devices_skfs(DeviceIDs, RouteID),
    Updates = ?MODULE:skf_to_remove_update(SKFs),
    ok = ?MODULE:update(Updates),
    {noreply, State};
handle_cast(
    {?UPDATE, Updates},
    #state{route_id = RouteID} = State
) ->
    %% logging is already done in send_update_request/2
    _ = send_update_request(RouteID, Updates),
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
    lager:warning("~p died: ~p", [?MODULE, _Reason]),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec do_skf_diff(#{local := skfs(), remote := skfs()}) -> skf_updates().
do_skf_diff(#{local := Local, remote := Remote}) ->
    ToAdd = Local -- Remote,
    ToRemove = Remote -- Local,

    AddUpdates = ?MODULE:skf_to_add_update(ToAdd),
    RemUpdates = ?MODULE:skf_to_remove_update(ToRemove),

    AddUpdates ++ RemUpdates.

%% We have to do this because the call to `helium_iot_config_gateway_client:location` can return
%% `{error, {Status, Reason}, _}` but is not in the spec...
-dialyzer({nowarn_function, send_update_request/2}).

send_update_request(RouteID, Updates) ->
    Request = #iot_config_route_skf_update_req_v1_pb{
        route_id = RouteID,
        updates = Updates,
        timestamp = erlang:system_time(millisecond),
        signer = router_blockchain:pubkey_bin()
    },
    SigFun = router_blockchain:sig_fun(),
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

list_skf(RouteID, Callback) ->
    Req = #iot_config_route_skf_list_req_v1_pb{
        route_id = RouteID,
        timestamp = erlang:system_time(millisecond),
        signer = router_blockchain:pubkey_bin()
    },
    SigFun = router_blockchain:sig_fun(),
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

-spec get_add_local_devices_skfs(DeviceIDs :: [binary()], RouteID :: string()) ->
    [iot_config_pb:iot_config_session_key_filter_v1_pb()].
get_add_local_devices_skfs(DeviceIDs, RouteID) ->
    Devices = lists:filtermap(
        fun(DeviceID) ->
            case router_device_cache:get(DeviceID) of
                {error, _} -> false;
                {ok, Device} -> {true, Device}
            end
        end,
        DeviceIDs
    ),
    %% Don't send adds for unfunded orgs devices
    %% Or inactive devices
    Devices0 = remove_unfunded_devices(Devices),
    Devices1 = remove_inactive_devices(Devices0),
    devices_to_skfs(Devices1, RouteID).

-spec get_remove_local_devices_skfs(DeviceIDs :: [binary()], RouteID :: string()) ->
    [iot_config_pb:iot_config_session_key_filter_v1_pb()].
get_remove_local_devices_skfs(DeviceIDs, RouteID) ->
    Devices = lists:filtermap(
        fun(DeviceID) ->
            case router_device_cache:get(DeviceID) of
                {error, _} -> false;
                {ok, Device} -> {true, Device}
            end
        end,
        DeviceIDs
    ),
    Removes = lists:flatmap(fun router_device:make_skf_removes/1, Devices),
    lists:map(
        fun({remove, DevAddrInt, NwkSKeyBin, MaxCopies}) ->
            #iot_config_skf_v1_pb{
                route_id = RouteID,
                devaddr = DevAddrInt,
                session_key = erlang:binary_to_list(binary:encode_hex(NwkSKeyBin)),
                max_copies = MaxCopies
            }
        end,
        Removes
    ).

%% This is the list of devices that should exist in the config service.
-spec get_local_skfs(RouteID :: string()) ->
    [iot_config_pb:iot_config_session_key_filter_v1_pb()].
get_local_skfs(RouteID) ->
    Devices0 = router_device_cache:get(),
    Devices1 = remove_unfunded_devices(Devices0),
    Devices2 = remove_inactive_devices(Devices1),
    devices_to_skfs(Devices2, RouteID).

-spec remove_unfunded_devices(list(router_device:device())) -> list(router_device:device()).
remove_unfunded_devices(Devices) ->
    UnfundedOrgs = router_console_dc_tracker:list_unfunded(),
    lists:filter(
        fun(D) ->
            OrgId = maps:get(organization_id, router_device:metadata(D), undefined),
            not lists:member(OrgId, UnfundedOrgs)
        end,
        Devices
    ).

-spec remove_inactive_devices(list(router_device:device())) -> list(router_device:device()).
remove_inactive_devices(Devices) ->
    lists:filter(fun(D) -> router_device:is_active(D) end, Devices).

-spec devices_to_skfs(Devices :: [router_device:device()], RouteID :: string()) ->
    [iot_config_pb:iot_config_session_key_filter_v1_pb()].
devices_to_skfs(Devices, RouteID) ->
    lists:usort(
        lists:filtermap(
            fun(Device) ->
                MultiBuy = maps:get(multi_buy, router_device:metadata(Device), 0),

                case
                    {
                        router_device:devaddr(Device),
                        router_device:nwk_s_key(Device)
                    }
                of
                    %% Unjoined device
                    {undefined, _} ->
                        false;
                    %% Unjoined device
                    {_, undefined} ->
                        false;
                    %% devices store devaddrs reversed. Config service expects them BE.
                    {<<DevAddr:32/integer-unsigned-little>>, SessionKey} ->
                        {true, #iot_config_skf_v1_pb{
                            route_id = RouteID,
                            devaddr = DevAddr,
                            session_key = erlang:binary_to_list(binary:encode_hex(SessionKey)),
                            max_copies = MultiBuy
                        }}
                end
            end,
            Devices
        )
    ).

-spec skf_update_batch_size() -> non_neg_integer().
skf_update_batch_size() ->
    router_utils:get_env_int(update_skf_batch_size, ?SKF_UPDATE_BATCH_SIZE).

-spec dedup_updates(skf_updates()) -> skf_updates().
dedup_updates(Updates) ->
    #{to_add := Adds, to_remove := Removes} = partition_updates_by_action(Updates),

    Keyed = fun(
        #iot_config_route_skf_update_v1_pb{
            devaddr = Devaddr,
            session_key = SessionKey
        } = Update
    ) ->
        {{Devaddr, SessionKey}, Update}
    end,

    AddMap = maps:from_list([Keyed(Update) || Update <- Adds]),
    RemoveMap = maps:from_list([Keyed(Update) || Update <- Removes]),

    Deduped = maps:merge(RemoveMap, AddMap),
    maps:values(Deduped).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

dedup_updates_test() ->
    MakeUpdate = fun(Action, Devaddr, SessionKey, MaxCopies) ->
        #iot_config_route_skf_update_v1_pb{
            action = Action,
            devaddr = Devaddr,
            session_key = SessionKey,
            max_copies = MaxCopies
        }
    end,
    ?assertEqual(
        [MakeUpdate(add, 1, <<>>, 5)],
        dedup_updates([MakeUpdate(add, 1, <<>>, 5)]),
        "adds are untouched"
    ),

    ?assertEqual(
        [MakeUpdate(add, 1, <<>>, 5)],
        dedup_updates([MakeUpdate(add, 1, <<>>, 5), MakeUpdate(remove, 1, <<>>, 9999)]),
        "removes that match an add are removed"
    ),

    ?assertEqual(
        [MakeUpdate(add, 1, <<>>, 5)],
        dedup_updates([MakeUpdate(remove, 1, <<>>, 9999), MakeUpdate(add, 1, <<>>, 5)]),
        "removes that match an add are removed regardless of order"
    ),

    ok.

-endif.
