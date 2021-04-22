#!/usr/bin/env bash
set -euo pipefail

alias router='sudo docker exec -it helium_router _build/default/rel/router/bin/router'

INTERVAL=30

for arg in "$@"
do
    case $arg in
        -i|--interval)
            INTERVAL="$2"
            shift # remove argument name from processing
            shift # remove argument value from processing
    esac
done

while true;
  do
      chain_head=$(curl --silent https://api.helium.io/v1/blocks/height | cut -c"19-24");
      router_head=$(router info height | cut -c"8-13");
      echo "$(date) -- $router_head / $chain_head == $(($chain_head - $router_head)) behind";
      sleep $INTERVAL;
done
