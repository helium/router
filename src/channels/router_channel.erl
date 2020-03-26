-module(router_channel).

-export([new/6,
         id/1,
         handler/1,
         name/1,
         args/1,
         device_id/1,
         device_worker/1,
         hash/1]).

-export([start_link/0,
         add/3, delete/2, update/3,
         handle_data/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(channel, {id :: binary(),
                  handler :: atom(),
                  name :: binary(),
                  args :: map(),
                  device_id  :: binary(),
                  device_worker :: pid() | undefined}).


-type channel() :: #channel{}.

-export_type([channel/0]).

-spec new(binary(), atom(), binary(), map(), binary(), pid()) -> channel().
new(ID, Handler, Name, Args, DeviceID, DeviceWorkerPid) ->
    #channel{id=ID,
             handler=Handler,
             name=Name,
             args=Args,
             device_id=DeviceID,
             device_worker=DeviceWorkerPid}.

-spec id(channel()) -> binary().
id(Channel) ->
    Channel#channel.id.

-spec handler(channel()) -> {atom(), binary()}.
handler(Channel) ->
    {Channel#channel.handler, ?MODULE:id(Channel)}.

-spec name(channel()) -> binary().
name(Channel) ->
    Channel#channel.name.

-spec args(channel()) -> map().
args(Channel) ->
    Channel#channel.args.

-spec device_id(channel()) -> binary().
device_id(Channel) ->
    Channel#channel.device_id.

-spec device_worker(channel()) -> pid().
device_worker(Channel) ->
    Channel#channel.device_worker.

-spec hash(channel()) -> binary().
hash(Channel0) ->
    Channel1 = Channel0#channel{device_worker=undefined},
    crypto:hash(sha256, erlang:term_to_binary(Channel1)).

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    gen_event:start_link().

-spec add(pid(), channel(), router_device:device()) -> ok | {'EXIT', term()} | {error, term()}.
add(Pid, Channel, Device) ->
    Handler = ?MODULE:handler(Channel),
    gen_event:add_sup_handler(Pid, Handler, {[Channel, Device], ok}).

-spec delete(pid(), channel()) -> ok.
delete(Pid, Channel) ->
    Handler = ?MODULE:handler(Channel),
    _ = gen_event:delete_handler(Pid, Handler, []),
    ok.

-spec update(pid(), channel(), router_device:device()) -> ok | {error, term()}.
update(Pid, Channel, Device) ->
    Handler = ?MODULE:handler(Channel),
    gen_event:call(Pid, Handler, {update, Channel, Device}).

-spec handle_data(pid(), map()) -> ok.
handle_data(Pid, Data) ->
    gen_event:notify(Pid, {data, Data}).

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    Channel = #channel{
                 id= <<"channel_id">>,
                 handler=router_http_channel,
                 name= <<"channel_name">>,
                 args=[],
                 device_id= <<"device_id">>,
                 device_worker=self()
                },
    ?assertEqual(Channel, new(<<"channel_id">>, router_http_channel, <<"channel_name">>,
                              [], <<"device_id">>, self())).

id_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(<<"channel_id">>, id(Channel)).

handler_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual({router_http_channel, <<"channel_id">>}, handler(Channel)).

name_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(<<"channel_name">>, name(Channel)).

args_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual([], args(Channel)).

device_id_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(<<"device_id">>, device_id(Channel)).

device_worker_test() ->
    Channel = new(<<"channel_id">>, router_http_channel,
                  <<"channel_name">>, [], <<"device_id">>, self()),
    ?assertEqual(self(), device_worker(Channel)).

hash_test() ->
    Channel0 = new(<<"channel_id">>, router_http_channel,
                   <<"channel_name">>, [], <<"device_id">>, self()),
    Channel1 = Channel0#channel{device_worker=undefined},
    Hash = crypto:hash(sha256, erlang:term_to_binary(Channel1)),
    ?assertEqual(Hash, hash(Channel0)).

-endif.
