-module(test_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
         tmp_dir/0, tmp_dir/1
        ]).

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory to be used as a scratch by eunit tests
%% @end
%%-------------------------------------------------------------------
tmp_dir() ->
    os:cmd("mkdir -p " ++ ?BASE_TMP_DIR),
    create_tmp_dir(?BASE_TMP_DIR_TEMPLATE).
tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path)->
    nonl(os:cmd("mktemp -d " ++  Path)).

nonl([$\n|T]) -> nonl(T);
nonl([H|T]) -> [H|nonl(T)];
nonl([]) -> [].


