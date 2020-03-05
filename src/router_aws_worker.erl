%%%-------------------------------------------------------------------
%% @doc
%% == Router AWS Worker ==
%% @end
%%%-------------------------------------------------------------------
-module(router_aws_worker).

-behavior(gen_server).


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
         start_link/1
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
-define(HEADERS, [{"content-type", "application/json"}]).
-define(THING_TYPE, <<"Helium-Thing">>).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?SERVER, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    AccessKey = maps:get(aws_access_key, Args),
    SecretKey = maps:get(aws_secret_key, Args),
    Region = maps:get(aws_region, Args),
    DeviceId = maps:get(device_id, Args),
    {ok, AWS} = httpc_aws:start_link(),
    httpc_aws:set_credentials(AWS, AccessKey, SecretKey),
    httpc_aws:set_region(AWS, Region),
    ok = ensure_policy(AWS),
    ok = ensure_thing_type(AWS),
    ok = ensure_thing(AWS, DeviceId),
    {ok, #state{}}.

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

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec ensure_policy(pid()) -> ok | {error, any()}.
ensure_policy(AWS) ->
    case httpc_aws:get(AWS, "iot", "/policies/Helium-Policy", []) of
        {error, "Not Found", _} ->
            Policy = #{
                       <<"Version">> => <<"2012-10-17">>,
                       <<"Statement">> => #{
                                            <<"Action">> => [
                                                             <<"iot:Publish">>,
                                                             <<"iot:Subscribe">>,
                                                             <<"iot:Connect">>,
                                                             <<"iot:Receive">>
                                                            ],
                                            <<"Effect">> => <<"Allow">>,
                                            <<"Resource">> => [<<"*">>]
                                           }
                      },
            PolicyString =  jsx:encode(Policy),
            Body = binary_to_list(jsx:encode(#{policyDocument => PolicyString})),
            case httpc_aws:post(AWS, "iot", "/policies/Helium-Policy", Body, ?HEADERS) of
                {error, _Reason, _} -> {error, _Reason};
                {ok, _} -> ok
            end;
        {error, _Reason, _} ->
            {error, _Reason};
        {ok, _} ->
            ok
    end.

-spec ensure_thing_type(pid()) -> ok | {error, any()}.
ensure_thing_type(AWS) ->
    case httpc_aws:get(AWS, "iot", binary_to_list(<<"/thing-types/", ?THING_TYPE/binary>>), []) of
        {error, "Not Found", _} ->
            Type = #{
                     <<"thingTypeProperties">> => #{
                                                    <<"searchableAttributes">> => [<<"Helium">>, <<"IoT">>],
                                                    <<"thingTypeDescription">> => ?THING_TYPE
                                                   }
                    },
            Body = binary_to_list(jsx:encode(Type)),
            case httpc_aws:post(AWS, "iot", "/thing-types/Helium-Thing", Body, ?HEADERS) of
                {error, _Reason, _} -> {error, _Reason};
                {ok, _} -> ok
            end;
        {error, _Reason, _} ->
            {error, _Reason};
        {ok, _} ->
            ok
    end.

-spec ensure_thing(pid(), binary()) -> ok | {error, any()}.
ensure_thing(AWS, DeviceId) ->
    case httpc_aws:get(AWS, "iot", binary_to_list(<<"/things/", DeviceId/binary>>), []) of
        {error, "Not Found", _} ->
            Thing = #{<<"thingTypeName">> => ?THING_TYPE},
            Body = binary_to_list(jsx:encode(Thing)),
            case httpc_aws:post(AWS, "iot", binary_to_list(<<"/things/", DeviceId/binary>>), Body, ?HEADERS) of
                {error, _Reason, _} -> {error, _Reason};
                {ok, _} -> ok
            end;
        {error, _Reason, _} ->
            {error, _Reason};
        {ok, _} ->
            ok
    end.

                                                % ensure_certificate(AWS, Device, Mac, Pid) ->
                                                %     lager:info("Device ~p", [Device]),
                                                %     {ok, {_, [{"principals", Principals}]}} = httpc_aws:get(AWS, "iot", io_lib:format("/things/~.16b/principals", [Mac])),
                                                %     case Principals of
                                                %         [] ->
                                                %             CSR = get_csr(Mac, Pid),
                                                %             CSRPEM = public_key:pem_encode([public_key:pem_entry_encode('CertificationRequest', CSR)]),
                                                %             Res = httpc_aws:post(AWS, "iot", "/certificates?setAsActive=true", binary_to_list(jsx:encode([{<<"certificateSigningRequest">>, CSRPEM}])), [{"content-type", "application/json"}]),
                                                %             {ok, {_, Attrs}} = Res,
                                                %             Res2 = httpc_aws:put(AWS, "iot", "/principal-policies/Helium-Policy", "", [{"x-amzn-iot-principal", proplists:get_value("certificateArn", Attrs)}, {"content-type", "text/plain"}]),
                                                %             lager:info("Attach Response ~p", [Res2]),
                                                %             Res3 = httpc_aws:put(AWS, "iot", io_lib:format("/things/~.16b/principals", [Mac]), "", [{"x-amzn-principal", proplists:get_value("certificateArn", Attrs)}, {"content-type", "text/plain"}]),
                                                %             lager:info("Attach Response ~p", [Res3]),
                                                %             proplists:get_value("certificatePem", Attrs);
                                                %         [CertificateARN] ->
                                                %             %"arn:aws:iot:us-west-2:217417705465:cert/1494179d50be24e8ff70f5305fff5d152cefea184dc82998cf873c3c6b928878"
                                                %             ["arn", _Partition, "iot", _Region, _Account, Resource] = string:tokens(CertificateARN, ":"),
                                                %             ["cert", CertificateId] = string:tokens(Resource, "/"),
                                                %             {ok, {_, [{"certificateDescription", Attrs}]}} = httpc_aws:get(AWS, "iot", "/certificates/"++CertificateId),
                                                %             proplists:get_value("certificatePem", Attrs)
                                                %     end.
