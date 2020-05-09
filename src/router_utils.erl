-module(router_utils).

-export([get_router_oui/0]).

-spec get_router_oui() -> integer() | undefined.
get_router_oui() ->
    case application:get_env(router, oui, undefined) of
        undefined ->
            undefined;
        L when is_list(L) ->
            erlang:list_to_integer(L);
        OUI ->
            OUI
    end.