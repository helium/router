%%%-------------------------------------------------------------------
%% @doc
%% == Router DB ==
%% @end
%%%-------------------------------------------------------------------
-module(router_db).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    get/0,
    get_xor_filter_devices/0
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
-define(DB_FILE, "router.db").
-define(CFS, ["default", "devices", "xor_filter_devices"]).

-record(state, {
    db :: rocksdb:db_handle(),
    cfs :: #{atom() => rocksdb:cf_handle()}
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec get() -> {ok, rocksdb:db_handle(), [rocksdb:cf_handle()]}.
get() ->
    gen_server:call(?SERVER, get).

-spec get_xor_filter_devices() -> {ok, rocksdb:db_handle(), rocksdb:cf_handle()}.
get_xor_filter_devices() ->
    gen_server:call(?SERVER, get_xor_filter_devices).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Dir] = Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, DB, CFs} = open_db(Dir),
    {ok, #state{db = DB, cfs = CFs}}.

handle_call(get, _From, #state{db = DB, cfs = CFs} = State) ->
    #{default := DefaultCF, devices := DevicesCF} = CFs,
    {reply, {ok, DB, [DefaultCF, DevicesCF]}, State};
handle_call(get_xor_filter_devices, _From, #state{db = DB, cfs = CFs} = State) ->
    CF = maps:get(xor_filter_devices, CFs),
    {reply, {ok, DB, CF}, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{db = DB}) ->
    catch rocksdb:close(DB),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec open_db(file:filename_all()) ->
    {ok, rocksdb:db_handle(), #{atom() => rocksdb:cf_handle()}} | {error, any()}.
open_db(Dir) ->
    DBDir = filename:join(Dir, ?DB_FILE),
    ok = filelib:ensure_dir(DBDir),

    GlobalOpts = application:get_env(rocksdb, global_opts, []),

    DBOptions = [{create_if_missing, true}, {atomic_flush, true}] ++ GlobalOpts,

    CFOpts = GlobalOpts,

    DefaultCFs = ?CFS,
    ExistingCFs =
        case rocksdb:list_column_families(DBDir, DBOptions) of
            {ok, CFs0} ->
                CFs0;
            {error, _} ->
                ["default"]
        end,

    {ok, DB, OpenedCFs} =
        rocksdb:open_with_cf(DBDir, DBOptions, [{CF, CFOpts} || CF <- ExistingCFs]),

    L1 = lists:zip(ExistingCFs, OpenedCFs),
    L2 = lists:map(
        fun(CF) ->
            {ok, CF1} = rocksdb:create_column_family(DB, CF, CFOpts),
            {CF, CF1}
        end,
        DefaultCFs -- ExistingCFs
    ),
    L3 = L1 ++ L2,

    CFs = maps:from_list([
        {erlang:list_to_atom(X), proplists:get_value(X, L3)}
        || X <- DefaultCFs
    ]),

    {ok, DB, CFs}.
