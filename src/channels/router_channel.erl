-module(router_channel).

-export([new/6, new/7,
         id/1,
         handler/1,
         name/1,
         dupes/1,
         args/1,
         device_id/1,
         device_worker/1,
         hash/1]).

-export([start_link/0,
         add/3, delete/2, update/3,
         handle_data/2]).

-record(channel, {id :: binary(),
                  handler :: atom(),
                  name :: binary(),
                  dupes=false :: boolean(),
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

-spec new(binary(), atom(), binary(), boolean(), map(), binary(), pid()) -> channel().
new(ID, Handler, Name, Dupes, Args, DeviceID, DeviceWorkerPid) ->
    #channel{id=ID,
             handler=Handler,
             name=Name,
             dupes=Dupes,
             args=Args,
             device_id=DeviceID,
             device_worker=DeviceWorkerPid}.

-spec id(channel()) -> binary().
id(Channel) ->
    Channel#channel.id.

-spec handler(channel()) -> atom().
handler(Channel) ->
    Channel#channel.handler.

-spec name(channel()) -> binary().
name(Channel) ->
    Channel#channel.name.

-spec dupes(channel()) -> boolean().
dupes(Channel) ->
    Channel#channel.dupes.

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
    ChannelID = ?MODULE:id(Channel),
    gen_event:add_sup_handler(Pid, {Handler, ChannelID}, {[Channel, Device], ok}).

-spec delete(pid(), channel()) -> ok.
delete(Pid, Channel) ->
    Handler = ?MODULE:handler(Channel),
    ChannelID = ?MODULE:id(Channel),
    _ = gen_event:delete_handler(Pid, {Handler, ChannelID}, []),
    ok.

-spec update(pid(), channel(), router_device:device()) -> ok | {error, term()}.
update(Pid, Channel, Device) ->
    Handler = ?MODULE:handler(Channel),
    ChannelID = ?MODULE:id(Channel),
    EventHandler = {Handler, ChannelID},
    gen_event:swap_sup_handler(Pid, {EventHandler, swapped}, {EventHandler, [Channel, Device]}).

-spec handle_data(pid(), map()) -> ok.
handle_data(Pid, Data) ->
    gen_event:notify(Pid, {data, Data}).
