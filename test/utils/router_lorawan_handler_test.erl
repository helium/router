-module(router_lorawan_handler_test).

-behavior(libp2p_framed_stream).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4,
    client/2,
    version/0
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3,
    handle_data/3,
    handle_info/3
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {
    pid :: pid(),
    key = undefined :: binary() | undefined,
    port,
    joined = false,
    channel_mask = [],
    region
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

-spec version() -> string().
version() ->
    "simple_http/1.0.0".

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------

init(server, _Conn, _Args) ->
    lager:info("server started with ~p", [_Args]),
    {ok, #state{}};
init(client, _Conn, [Pid, Pubkeybin, Region] = _Args) ->
    lager:info("client started with ~p", [_Args]),
    ct:pal("~p", [file:get_cwd()]),
    Port = erlang:open_port(
        {spawn_executable, io_lib:format("../../../../priv/LoRaMac-classA_~s", [Region])},
        [
            {line, 65535},
            stream,
            binary,
            exit_status
        ]
    ),
    {ok, #state{pid = Pid, key = Pubkeybin, port = Port, region = Region}}.

handle_data(client, Data, #state{pid = Pid, key = Pubkeybin} = State) ->
    try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
        #blockchain_state_channel_message_v1_pb{msg = {response, Resp}} ->
            #blockchain_state_channel_response_v1_pb{accepted = true, downlink = Packet} = Resp,
            case Packet of
                undefined ->
                    port_command(State#state.port, <<"\r\n">>);
                _ ->
                    TxPk = jsx:encode(#{
                        txpk => #{
                            data => base64:encode(Packet#packet_pb.payload),
                            size => byte_size(Packet#packet_pb.payload),
                            freq => Packet#packet_pb.frequency,
                            datr => Packet#packet_pb.datarate
                        }
                    }),
                    lager:info("Transmitting packet ~s", [TxPk]),
                    port_command(State#state.port, <<TxPk/binary, "\r\n">>),
                    lager:info("Resp ~p", [Packet])
            end,
            ok;
        _Else ->
            lager:info("Client data ~p", [Data])
    catch
        _:_ ->
            lager:info("Client data ~p", [Data])
    end,
    Pid ! {client_data, Pubkeybin, Data},
    {noreply, State};
handle_data(_Type, _Data, State) ->
    lager:warning("~p got data ~p", [_Type, _Data]),
    {noreply, State}.

handle_info(client, {send, Data}, State) ->
    {noreply, State, Data};
handle_info(
    client,
    {Port, {data, {eol, <<"{\"rxpk\"", _/binary>> = JSONBin}}},
    State = #state{port = Port}
) ->
    #{<<"rxpk">> := [JSON]} = jsx:decode(JSONBin, [return_maps]),
    lager:info("got packet ~p", [JSON]),
    State#state.pid ! rx,
    HeliumPacket = #packet_pb{
        type = lorawan,
        payload = base64:decode(maps:get(<<"data">>, JSON)),
        signal_strength = maps:get(<<"rssi">>, JSON),
        frequency = maps:get(<<"freq">>, JSON),
        datarate = maps:get(<<"datr">>, JSON)
    },
    Packet = #blockchain_state_channel_packet_v1_pb{
        packet = HeliumPacket,
        hotspot = State#state.key,
        region = State#state.region
    },
    Msg = #blockchain_state_channel_message_v1_pb{msg = {packet, Packet}},
    {noreply, State, blockchain_state_channel_v1_pb:encode_msg(Msg)};
%% handle_info(client, {Port, {data,{eol,<<"###### ===== JOINED ==== ######">>}}},
%%             State = #state{port=Port}) ->
%% {noreply, State#state{joined=true}};
%% handle_info(client, {Port, {data,{eol,<<"###### ===== JOINED ==== ######">>}}},
%%             State = #state{port=Port}) ->
%% {noreply, State#state{joined=true}};
%% handle_info(client, {Port, {data,{eol,<<"Radio Rx with timeout 0">>}}},
%%            State = #state{port=Port, joined=true}) ->
handle_info(client, unblock, State) ->
    lager:info("unblocking"),
    port_command(State#state.port, <<"\r\n">>),
    {noreply, State};
handle_info(client, {Port, {data, {eol, <<>>}}}, State = #state{port = Port}) ->
    {noreply, State};
handle_info(client, {Port, {data, {eol, LogMsg}}}, State = #state{port = Port}) ->
    State1 =
        case LogMsg of
            <<"###### ===== JOINED ==== ######">> ->
                State#state.pid ! joined,
                State;
            <<"###### ===== JOINING ==== ######">> ->
                State#state.pid ! joining,
                State;
            <<"CHANNEL MASK: ", Rest/binary>> ->
                %% 0,8,16,24,32,40,48,56,64,72
                Mask = parse_channel_mask(Rest, State#state.region),
                lager:info("channel mask ~w", [Mask]),
                State#state{channel_mask = Mask};
            <<"RX CONFIRMED DATA     : ", HexPort:2/binary, " ", HexPayload/binary>> ->
                Payload = lorawan_utils:hex_to_binary(
                    binary:replace(HexPayload, <<" ">>, <<>>, [global])
                ),
                lager:info("Device got payload ~p", [Payload]),
                <<FramePort:8/integer-unsigned>> = lorawan_utils:hex_to_binary(HexPort),
                State#state.pid ! {tx, FramePort, true, Payload},
                State;
            <<"RX DATA     : ", HexPort:2/binary, " ", HexPayload/binary>> ->
                Payload = lorawan_utils:hex_to_binary(
                    binary:replace(HexPayload, <<" ">>, <<>>, [global])
                ),
                lager:info("Device got payload ~p", [Payload]),
                <<FramePort:8/integer-unsigned>> = lorawan_utils:hex_to_binary(HexPort),
                State#state.pid ! {tx, FramePort, false, Payload},
                State;
            _ ->
                State
        end,
    lager:info("[Device] ~s", [LogMsg]),
    {noreply, State1};
handle_info(client, get_channel_mask, State) ->
    State#state.pid ! {channel_mask, State#state.channel_mask},
    {noreply, State};
handle_info(_Type, _Msg, State) ->
    lager:warning("test ~p got info ~p", [_Type, _Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

parse_channel_mask(
    <<A:4/binary, " ", B:4/binary, " ", C:4/binary, " ", D:4/binary, " ", E:4/binary, _/binary>>,
    Region
) when Region == 'US915'; Region == 'AU915'; Region == 'CN470' ->
    {_, R} = lists:foldl(
        fun(Byte, {Offset, Channels}) ->
            NewChannels = [
                Offset * (Byte band 2#1),
                (Offset + 1) * ((Byte band 2#10) bsr 1),
                (Offset + 2) * ((Byte band 2#100) bsr 2),
                (Offset + 3) * ((Byte band 2#1000) bsr 3),
                (Offset + 4) * ((Byte band 2#10000) bsr 4),
                (Offset + 5) * ((Byte band 2#100000) bsr 5),
                (Offset + 6) * ((Byte band 2#1000000) bsr 6),
                (Offset + 7) * ((Byte band 2#10000000) bsr 7)
            ],
            {Offset + 8, Channels ++ NewChannels}
        end,
        {1, []},
        binary_to_list(<<
            <<Y:8/integer, X:8/integer>>
            || <<X:8/integer, Y:8/integer>> <= lorawan_utils:hex_to_binary(
                   <<A/binary, B/binary, C/binary, D/binary, E/binary>>
               )
        >>)
    ),
    [F - 1 || F <- R, F /= 0];
parse_channel_mask(<<A:4/binary, _/binary>>, _) ->
    %% XXX assume AS923 form
    [Byte, _] = binary_to_list(<<
        <<Y:8/integer, X:8/integer>>
        || <<X:8/integer, Y:8/integer>> <= lorawan_utils:hex_to_binary(<<A/binary>>)
    >>),
    ct:pal("byte ~p", [Byte]),
    R = [
        (Byte band 2#1),
        1 + ((Byte band 2#10) bsr 1),
        2 + ((Byte band 2#100) bsr 2),
        3 + ((Byte band 2#1000) bsr 3),
        4 + ((Byte band 2#10000) bsr 4),
        5 + ((Byte band 2#100000) bsr 5),
        6 + ((Byte band 2#1000000) bsr 6),
        7 + ((Byte band 2#10000000) bsr 7)
    ],

    ct:pal("R ~p", [R]),
    [E - 1 || E <- R, E /= 0].

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-endif.
