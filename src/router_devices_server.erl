%%%-------------------------------------------------------------------
%% @doc
%% == Router Devices Server ==
%% @end
%%%-------------------------------------------------------------------
-module(router_devices_server).

-behavior(gen_server).

-include("device.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
         start_link/1,
         insert/1,
         update/2,
         get/1,
         get_all/0
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

-record(state, {
                db :: rocksdb:db_handle(),
                cf :: rocksdb:cf_handle()
               }).

-type device() :: #device{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec insert(device()) -> ok | {error, any()}.
insert(Device) ->
    gen_server:call(?SERVER, {insert, Device}).

-spec update(binary(), [{atom(), any()}]) -> ok | {error, any()}.
update(AppEUI, Updates) ->
    gen_server:call(?SERVER, {update, AppEUI, Updates}).

-spec get(binary()) -> {ok, device()} | {error, any()}.
get(AppEUI) ->
    gen_server:call(?SERVER, {get, AppEUI}).

-spec get_all() -> [device()].
get_all() ->
    gen_server:call(?SERVER, get_all).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("~p init with ~p", [?SERVER, _Args]),
    {ok, DB, [_DefaultCF, DevicesCF]} = router_db:get(),
    {ok, #state{db=DB, cf=DevicesCF}}.

handle_call({insert, Device}, _From, #state{db=DB, cf=CF}=State) ->
    Reply = insert_device(DB, CF, Device),
    {reply, Reply, State};
handle_call({update, AppEUI, Updates}, _From, #state{db=DB, cf=CF}=State) ->
    Reply = update_device(DB, CF, AppEUI, Updates),
    {reply, Reply, State};
handle_call({get, AppEUI}, _From, #state{db=DB, cf=CF}=State) ->
    Reply = get_device(DB, CF, AppEUI),
    {reply, Reply, State};
handle_call(get_all, _From, #state{db=DB, cf=CF}=State) ->
    Reply = get_devices(DB, CF),
    {reply, Reply, State};
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

terminate(_Reason, #state{db=DB}) ->
    catch rocksdb:close(DB).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec update_device(rocksdb:db_handle(), rocksdb:cf_handle(), binary(), [{atom(), any()}]) ->
          ok | {error, any()}.
update_device(DB, CF, AppEUI, Updates) ->
    case get_device(DB, CF, AppEUI) of
        {error, _}=Error ->
            Error;
        {ok, Device} ->
            insert_device(DB, CF, update_device(Device, Updates))
    end.

-spec update_device(device(), [{atom(), any()}]) -> device().
update_device(Device, []) ->
    Device;
update_device(Device, [{mac, Value}|Updates]) ->
    update_device(Device#device{mac=Value}, Updates);
update_device(Device, [{app_eui, Value}|Updates]) ->
    update_device(Device#device{app_eui=Value}, Updates);
update_device(Device, [{nwk_s_key, Value}|Updates]) ->
    update_device(Device#device{nwk_s_key=Value}, Updates);
update_device(Device, [{app_s_key, Value}|Updates]) ->
    update_device(Device#device{app_s_key=Value}, Updates);
update_device(Device, [{join_nonce, Value}|Updates]) ->
    update_device(Device#device{join_nonce=Value}, Updates);
update_device(Device, [{fcnt, Value}|Updates]) ->
    update_device(Device#device{fcnt=Value}, Updates);
update_device(Device, [{fcntdown, Value}|Updates]) ->
    update_device(Device#device{fcntdown=Value}, Updates);
update_device(Device, [{offset, Value}|Updates]) ->
    update_device(Device#device{offset=Value}, Updates);
update_device(Device, [{channel_correction, Value}|Updates]) ->
    update_device(Device#device{channel_correction=Value}, Updates);
update_device(Device, [{queue, Value}|Updates]) ->
    update_device(Device#device{queue=Value}, Updates).

-spec get_device(rocksdb:db_handle(), rocksdb:cf_handle(), binary()) ->
          {ok, device()} | {error, any()}.
get_device(DB, CF, AppEUI) ->
    case rocksdb:get(DB, CF, AppEUI, [{sync, true}]) of
        {ok, BinDevice} -> {ok, erlang:binary_to_term(BinDevice)};
        not_found -> {error, not_found};
        Error -> Error
    end.

-spec get_devices(rocksdb:db_handle(), rocksdb:cf_handle()) -> [device()].
get_devices(DB, CF) ->
    rocksdb:fold(
      DB,
      CF,
      fun({_Key, BinDevice}, Acc) ->
              [erlang:binary_to_term(BinDevice)|Acc]
      end,
      [{sync, true}],
      []
     ).

-spec insert_device(rocksdb:db_handle(), rocksdb:cf_handle(), device()) ->
          ok | {error, any()}.
insert_device(DB, CF, #device{app_eui=AppEUI}=Device) ->
    rocksdb:put(DB, CF, AppEUI, erlang:term_to_binary(Device), [{sync, true}]).
