[![Build status](https://badge.buildkite.com/e55c0afff2b3ae9f7a358846c8832947586fb5db7d8b33293a.svg)](https://buildkite.com/helium/routerv3)

# Router

## Docker

### Commands

```
# Build
sudo docker-compose build --force-rm

# Up
sudo docker-compose up -d

# Down
sudo docker-compose down

# Tail logs
sudo docker-compose logs -f --tail=20

# Get in container
sudo docker exec -it helium_router bash

# Run tests
sudo docker run --name router_test --rm  helium/router:latest ./rebar3 ct --suite=test/router_SUITE.erl
sudo docker run --name router_test --rm  helium/router:latest make test

```

### Data

Data is located in `/var/data`.

### Config

Config is in `.env`.
