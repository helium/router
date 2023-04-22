-module(router_skf_remove).

-behavior(gen_server).
-include("./autogen/iot_config_pb.hrl").

-export([
    start_link/0,
    fetch/1,
    remote_count/1,
    remove_all/2
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

-record(state, {
    route_id :: string(),
    pubkey_bin :: libp2p_crypto:pubkey_bin(),
    sig_fun :: litp2p_crypto:sig_fun(),
    chunk_size = 100 :: non_neg_integer(),
    remove_progress_callback :: remove_progress_callback(),
    remote = [] :: [#iot_config_skf_v1_pb{}]
}).

-type skf() :: #iot_config_skf_v1_pb{}.
-type api_resp() :: #iot_config_route_skf_update_res_v1_pb{}.
-type remove_progress_callback() :: fun(
    (done | {progress, Removed :: list(skf()), APIResp :: api_resp()}) -> ok
).

%% ------------------------------------------------------------------
%% API
%% ------------------------------------------------------------------

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec fetch(pid()) -> ok.
fetch(Pid) ->
    gen_server:call(Pid, fetch).

-spec remote_count(pid()) -> non_neg_integer().
remote_count(Pid) ->
    gen_server:call(Pid, remote_count).

-spec remove_all(pid(), remove_progress_callback()) -> ok.
remove_all(Pid, ProgressCallback) ->
    gen_server:call(Pid, {remove_all, ProgressCallback}, timer:seconds(20)).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    {ok, #state{
        route_id = "route_id",
        pubkey_bin = router_blockchain:pubkey_bin(),
        sig_fun = router_blockchain:sig_fun(),
        chunk_size = application:get_env(router, update_skf_batch_size, 100),
        remove_progress_callback = fun(_) -> ok end
    }}.

handle_call(fetch, _From, State) ->
    case router_ics_skf_worker:list_skf() of
        {ok, List} ->
            {reply, ok, State#state{remote = List}};
        {error, _Reason} = Err ->
            {reply, Err, State}
    end;
handle_call(remote_count, _From, #state{remote = Remote} = State) ->
    {reply, erlang:length(Remote), State};
handle_call(
    {remove_all, RemoveProgressCallback},
    From,
    #state{
        remote = Remote, chunk_size = ChunkSize
    } = State
) ->
    Self = self(),
    erlang:spawn(fun() ->
        Chunks = chunk(ChunkSize, Remote),

        Results = lists:map(
            fun(Chunk) ->
                ToRemove = router_ics_skf_worker:skf_to_remove_update(Chunk),
                case send_update_request(ToRemove, State) of
                    {ok, Resp} -> gen_server:cast(Self, {removed, Chunk, Resp});
                    Err -> gen_server:cast(Self, {removed, [], Err})
                end
            end,
            Chunks
        ),
        ok = RemoveProgressCallback(done),
        case lists:usort(Results) of
            [ok] -> gen_server:reply(From, ok);
            Other -> gen_server:reply(From, Other)
        end
    end),
    {noreply, State#state{remove_progress_callback = RemoveProgressCallback}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(
    {removed, Removed, Resp},
    #state{remote = Remote0, remove_progress_callback = RemoveProgressCallback} = State
) ->
    ok = RemoveProgressCallback({progress, Removed, Resp}),
    Remote1 = Remote0 -- Removed,
    {noreply, State#state{remote = Remote1}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ct:print("~p died: ~p", [?MODULE, _Reason]),
    ok.

%% -------------------------------------------------------------------

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
