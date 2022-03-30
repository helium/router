%%%-------------------------------------------------------------------
%%% @doc
%%% == Router Deny List ==
%%% @end
%%%-------------------------------------------------------------------
-module(router_hotspot_deny_list).

-define(ETS, router_hotspot_deny_list_ets).
-define(DEFAULT_FILE, "hotspot_deny_list.json").

%% ------------------------------------------------------------------
%% API Exports
%% ------------------------------------------------------------------
-export([
    enabled/0,
    init/1,
    ls/0,
    denied/1,
    deny/1,
    approve/1
]).

%% ------------------------------------------------------------------
%% API Functions
%% ------------------------------------------------------------------

-spec enabled() -> boolean().
enabled() ->
    case application:get_env(router, hotspot_deny_list_enabled, false) of
        "true" -> true;
        true -> true;
        _ -> false
    end.

-spec init(BaseDir :: string()) -> ok.
init(BaseDir) ->
    case ?MODULE:enabled() of
        false ->
            lager:info("router_hotspot_deny_list disabled");
        true ->
            lager:info("router_hotspot_deny_list enabled"),
            Opts = [
                public,
                named_table,
                set,
                {read_concurrency, true}
            ],
            _ = ets:new(?ETS, Opts),
            ok = load_from_file(BaseDir),
            ok
    end.

-spec ls() -> [].
ls() ->
    ets:tab2list(?ETS).

-spec denied(libp2p_crypto:pubkey_bin()) -> boolean().
denied(PubKeyBin) ->
    case ets:lookup(?ETS, PubKeyBin) of
        [] -> false;
        [{PubKeyBin, _}] -> true
    end.

-spec deny(libp2p_crypto:pubkey_bin()) -> ok.
deny(PubKeyBin) ->
    true = ets:insert(?ETS, {PubKeyBin, 0}),
    ok.

-spec approve(libp2p_crypto:pubkey_bin()) -> ok.
approve(PubKeyBin) ->
    true = ets:delete(?ETS, PubKeyBin),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec load_from_file(BaseDir :: string()) -> ok.
load_from_file(BaseDir) ->
    FileName = application:get_env(router, hotspot_deny_list, ?DEFAULT_FILE),
    File = BaseDir ++ "/" ++ FileName,
    case file:read_file(File) of
        {error, Error} ->
            lager:warning("failed to read deny list ~p: ~p", [File, Error]);
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
                    lager:warning("failed to decode deny list ~p: ~p", [File, {_E, _R}])
            end
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

all_test() ->
    application:ensure_all_started(lager),
    application:set_env(router, hotspot_deny_list_enabled, true),

    BaseDir = test_utils:tmp_dir("router_hotspot_deny_list_all_test"),
    #{public := PubKey0} = libp2p_crypto:generate_keys(ecc_compact),
    B580 = libp2p_crypto:pubkey_to_b58(PubKey0),
    PubKeyBin0 = libp2p_crypto:pubkey_to_bin(PubKey0),
    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    B581 = libp2p_crypto:pubkey_to_b58(PubKey1),
    PubKeyBin1 = libp2p_crypto:pubkey_to_bin(PubKey1),
    Content =
        <<"[\"", (erlang:list_to_binary(B580))/binary, "\",\"",
            (erlang:list_to_binary(B581))/binary, "\"]">>,
    ok = file:write_file(BaseDir ++ "/hotspot_deny_list.json", Content),

    ok = init(BaseDir),

    ?assertEqual(true, ?MODULE:denied(PubKeyBin0)),
    ?assertEqual(true, ?MODULE:denied(PubKeyBin1)),
    ?assertEqual(false, ?MODULE:denied(<<"random">>)),

    DenyList = ?MODULE:ls(),
    ?assert(proplists:is_defined(PubKeyBin0, DenyList)),
    ?assert(proplists:is_defined(PubKeyBin1, DenyList)),

    ?assertEqual(ok, ?MODULE:approve(PubKeyBin0)),
    ?assertEqual(false, ?MODULE:denied(PubKeyBin0)),

    ets:delete(?ETS),
    application:stop(lager),
    ok.

-endif.
