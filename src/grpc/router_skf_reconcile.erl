-module(router_skf_reconcile).

-export([
    new/1,
    %% Getters
    update_chunks/1,
    local/1,
    %% Counts
    update_chunks_count/1,
    remote_count/1,
    local_count/1,
    updates_count/1,
    add_count/1,
    remove_count/1
]).

-record(reconcile, {
    remote :: router_ics_skf_worker:skfs(),
    remote_count :: non_neg_integer(),
    %%
    local :: router_ics_skf_worker:skfs(),
    local_count :: non_neg_integer(),
    %%
    updates :: router_ics_skf_worker:skf_updates(),
    updates_count :: non_neg_integer(),
    update_chunks :: list(router_ics_skf_worker:skf_updates()),
    update_chunks_count :: non_neg_integer(),
    %%
    add_count :: non_neg_integer(),
    remove_count :: non_neg_integer()
}).

-type reconcile() :: #reconcile{}.

%% ------------------------------------------------------------------
%% Exports
%% ------------------------------------------------------------------

-spec new(#{
    remote := router_ics_skf_worker:skfs(),
    local := router_ics_skf_worker:skfs(),
    chunk_size := non_neg_integer()
}) ->
    reconcile().
new(#{remote := Remote, local := Local, chunk_size := ChunkSize}) ->
    Diff = router_ics_skf_worker:diff_skf_to_updates(#{remote => Remote, local => Local}),
    DiffChunks = chunk(ChunkSize, Diff),

    #{
        to_add := ToAdd,
        to_remove := ToRemove
    } = router_ics_skf_worker:partition_updates_by_action(Diff),

    #reconcile{
        remote = Remote,
        remote_count = erlang:length(Remote),

        local = Local,
        local_count = erlang:length(Local),

        updates = Diff,
        updates_count = erlang:length(Diff),
        update_chunks = DiffChunks,
        update_chunks_count = erlang:length(DiffChunks),

        add_count = erlang:length(ToAdd),
        remove_count = erlang:length(ToRemove)
    }.

-spec update_chunks(reconcile()) -> list(router_ics_skf_worker:skf_updates()).
update_chunks(#reconcile{update_chunks = UpdateChunks}) ->
    UpdateChunks.

-spec local(reconcile()) -> router_ics_skf_worker:skfs().
local(#reconcile{local = Local}) ->
    Local.

-spec update_chunks_count(reconcile()) -> non_neg_integer().
update_chunks_count(#reconcile{update_chunks_count = UpdateChunksCount}) ->
    UpdateChunksCount.

-spec remote_count(reconcile()) -> non_neg_integer().
remote_count(#reconcile{remote_count = RemoteCount}) ->
    RemoteCount.

-spec local_count(reconcile()) -> non_neg_integer().
local_count(#reconcile{local_count = LocalCount}) ->
    LocalCount.

-spec updates_count(reconcile()) -> non_neg_integer().
updates_count(#reconcile{updates_count = UpdatesCount}) ->
    UpdatesCount.

-spec add_count(reconcile()) -> non_neg_integer().
add_count(#reconcile{add_count = AddCount}) ->
    AddCount.

-spec remove_count(reconcile()) -> non_neg_integer().
remove_count(#reconcile{remove_count = RemoveCount}) ->
    RemoveCount.

%% ------------------------------------------------------------------
%% Internal
%% ------------------------------------------------------------------

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
