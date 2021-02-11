%%%-------------------------------------------------------------------
%% @doc
%% == Lorawan Location ==
%%
%% Stores information when a band is handled different in different regions.
%%
%% @end
%%%-------------------------------------------------------------------
-module(lorawan_location).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/0,
    get_country_code/1,
    maybe_fetch_offer_location/1,
    as923_region_from_country_code/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(ETS, lorawan_region_location_ets).

-type country_code() :: {binary(), binary()}.

-record(state, {}).

%% ------------------------------------------------------------------
%% API
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec maybe_fetch_offer_location(blockchain_state_channel_offer_v1:offer()) -> ok.
maybe_fetch_offer_location(Offer) ->
    case blockchain_state_channel_offer_v1:region(Offer) of
        'AS923' -> gen_server:cast(?SERVER, {fetch, Offer});
        _ -> ok
    end.

-spec get_country_code(libp2p_crypto:pubkey_bin()) -> {ok, country_code()} | {error, any()}.
get_country_code(PubKeyBin) ->
    case ets:lookup(?ETS, PubKeyBin) of
        [{PubKeyBin, CountryCode, _}] -> {ok, CountryCode};
        [] -> {error, pubkey_not_present}
    end.

store(PubKeyBin, CountryCode, Offer) ->
    %% TODO: What else do we want to store from the offer?
    true = ets:insert_new(?ETS, {PubKeyBin, CountryCode, Offer}),
    ok.

-spec as923_region_from_country_code(country_code()) -> 'AS923_AS1' | 'AS923_AS2'.
as923_region_from_country_code(CountryCode) ->
    %% TODO: We probably only need one of these
    case CountryCode of
        {<<"JP">>, <<"Japan">>} -> 'AS923_AS1';
        {<<"MY">>, <<"Malaysia">>} -> 'AS923_AS1';
        {<<"SG">>, <<"Singapore">>} -> 'AS923_AS1';
        {<<"BN">>, <<"Brunei">>} -> 'AS923_AS2';
        {<<"KH">>, <<"Cambodia">>} -> 'AS923_AS2';
        {<<"HK">>, <<"Hong Kong">>} -> 'AS923_AS2';
        {<<"ID">>, <<"Indonesia">>} -> 'AS923_AS2';
        {<<"LA">>, <<"Laos">>} -> 'AS923_AS2';
        {<<"TW">>, <<"Taiwan">>} -> 'AS923_AS2';
        {<<"TH">>, <<"Thailand">>} -> 'AS923_AS2';
        {<<"VN">>, <<"Vietnam">>} -> 'AS923_AS2';
        _ -> 'AS923_AS2'
    end.

%% ------------------------------------------------------------------
%% gen_server callbacks
%% ------------------------------------------------------------------

init([]) ->
    ?ETS = etw:new(?ETS, [public, named_table, set]),
    %% TODO: ok = init_ets(),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({fetch, Offer}, State) ->
    PubKeyBin = blockchain_state_channel_offer_v1:hotspot(Offer),
    B58 = libp2p_crypto:bin_to_b58(PubKeyBin),

    Url = <<"https://api.helium.io/v1/hotspots/", B58/binary>>,
    case hackney:get(Url, [], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            Map = jsx:decode(Body, [return_maps]),
            ShortCountry = kvc:path('data.geocode.short_country', Map),
            LongCountry = kvc:path('data.geocode.long_country', Map),
            %% TODO: Some geocode information is NULL
            ok = store(PubKeyBin, {ShortCountry, LongCountry}, Offer),
            ok;
        _Other ->
            error
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    true = ets:delete(?ETS),
    ok.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
