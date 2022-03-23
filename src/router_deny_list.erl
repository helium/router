%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Deny List ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_deny_list).

-define(ETS, router_deny_list_ets).

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([
    enabled/0,
    init/1,
    approved/1,
    deny/1
]).

%% ------------------------------------------------------------------
%% API Functions
%% ------------------------------------------------------------------

-spec enabled() -> boolean().
enabled() ->
    case application:get_env(router, deny_list_enabled, false) of
        "true" -> true;
        true -> true;
        _ -> false
    end.

-spec init(BaseDir :: string()) -> ok.
init(BaseDir) ->
    Opts = [
        public,
        named_table,
        set,
        {read_concurrency, true}
    ],
    case ?MODULE:enabled() of
        false ->
            lager:info("router_deny_list disabled");
        true ->
            lager:info("router_deny_list enabled"),
            _ = ets:new(?ETS, Opts),
            ok = load_from_file(BaseDir),
            ok
    end.

-spec approved(libp2p_crypto:pubkey_bin()) -> boolean().
approved(PubKeyBin) ->
    case ets:lookup(?ETS, PubKeyBin) of
        [] -> true;
        [{PubKeyBin, _}] -> false
    end.

-spec deny(libp2p_crypto:pubkey_bin()) -> ok.
deny(PubKeyBin) ->
    true = ets:insert(?ETS, {PubKeyBin, 0}),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec load_from_file(BaseDir :: string()) -> ok.
load_from_file(BaseDir) ->
    FileName = application:get_env(router, deny_list, "deny_list.json"),
    File = BaseDir ++ "/" ++ FileName,
    case file:read_file(File) of
        {error, Error} ->
            lager:info("failed to read deny list ~p: ~p", [File, Error]);
        {ok, Binary} ->
            try jsx:decode(Binary) of
                DenyList ->
                    lists:foreach(
                        fun(B58Bin) ->
                            B58 = erlang:binary_to_list(B58Bin),
                            ?MODULE:deny(libp2p_crypto:b58_to_bin(B58))
                        end,
                        DenyList
                    )
            catch
                _E:_R ->
                    lager:info("failed to decode deny list ~p: ~p", [File, {_E, _R}])
            end
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test() ->
    application:ensure_all_started(lager),
    application:set_env(router, deny_list_enabled, true),

    BaseDir = test_utils:tmp_dir("router_deny_list_all_test"),
    #{public := PubKey0} = libp2p_crypto:generate_keys(ecc_compact),
    B580 = libp2p_crypto:pubkey_to_b58(PubKey0),
    PubKeyBin0 = libp2p_crypto:pubkey_to_bin(PubKey0),
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    B581 = libp2p_crypto:pubkey_to_b58(PubKey1),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    Content =
        <<"[\"", (erlang:list_to_binary(B580))/binary, "\",\"",
            (erlang:list_to_binary(B581))/binary, "\"]">>,
    ok = file:write_file(BaseDir ++ "/deny_list.json", Content),

    ok = init(BaseDir),

    ?assertEqual(false, ?MODULE:approved(PubKeyBin0)),
    ?assertEqual(false, ?MODULE:approved(PubKeyBin1)),
    ?assertEqual(true, ?MODULE:approved(<<"random">>)),

    ets:delete(?ETS),
    application:stop(lager),
    ok.

-endif.
