-module(router_console_dc_tracker).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         refill/3,
         has_enough_dc/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS, router_console_dc_tracker_ets).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec refill(OrgID :: binary(), Nonce :: non_neg_integer(), Balance :: non_neg_integer()) -> ok.
refill(OrgID, Nonce, Balance) ->
    case lookup(OrgID) of
        {error, not_found} ->
            insert(OrgID, Balance, Nonce);
        {ok, OldBalance, _OldNonce} ->
            insert(OrgID, Balance + OldBalance, Nonce)
    end.

-spec has_enough_dc(OrgID :: binary(), PayloadSize :: non_neg_integer()) -> {true, non_neg_integer(), non_neg_integer()} | false.
has_enough_dc(OrgID, PayloadSize) ->
    case blockchain_worker:blockchain() of
        undefined ->
            false;
        Chain ->
            Ledger = blockchain:ledger(Chain),
            case blockchain_utils:calculate_dc_amount(Ledger, PayloadSize) of
                {error, _Reason} ->
                    lager:warning("failed to calculate dc amount ~p", [_Reason]),
                    false;
                DCAmount ->
                    case lookup(OrgID) of
                        {error, not_found} ->
                                false;
                        {ok, Balance0, Nonce} ->
                            Balance1 =  Balance0-DCAmount,
                            case Balance1 > 0 of
                                false ->
                                    false;
                                true ->
                                    ok = insert(OrgID, Balance1, Nonce),
                                    {true, Balance1, Nonce}
                            end

                    end
            end
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ets:new(?ETS, [public, named_table, set]),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

lookup(OrgID) ->
    case ets:lookup(?ETS, OrgID) of
        [] -> {error, not_found};
        [{OrgID, {Balance, Nonce}}] -> {ok, Balance, Nonce}
    end.

insert(OrgID, Balance, Nonce) ->
    true = ets:insert(?ETS, {OrgID, {Balance, Nonce}}),
    ok.
