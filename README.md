[![Build status](https://badge.buildkite.com/e55c0afff2b3ae9f7a358846c8832947586fb5db7d8b33293a.svg?branch=master)](https://buildkite.com/helium/routerv3)

# Router

## Data

### Sent to channels

```
{
    "id": "device_uuid",
    "name": "device_name",
    "dev_eui": "dev_eui",
    "app_eui": "app_eui",
    "metadata": {},
    "fcnt": 2,
    "reported_at": 123,
    "payload": "base64 encoded payload",
     // ONLY if payload is decoded
    "decoded": {
        "status": "success | error",
        "error": "...",
        "payload": "..."
    },
    "fport": 1,
    "dev_addr": "dev_addr",
    "hotspots": [
        {
            "id": "hotspot_id",
            "name": "hotspot name",
            "reported_at": 123,
            "status": "success | error",
            "rssi": -30,
            "snr": 0.2,
            "spreading": "SF9BW125",
            "frequency": 923.3
        }
    ]
}
```

### Console

```
{
    "category": "up | down | activation | ack | channel_crash | channel_start_error",
    "description": "any specific description ie.correcting channel mask, otherwise null",
    "reported_at": 123,
    "device_id": "device_uuid",
    "fcnt_up": 2,
    "fcnt_down": 2,
    "payload": "base64 payload", // ONLY ON DEBUG MODE
    "payload_size": 12,
    "fport": 1,
    "dev_addr": "dev_addr",
    "hotspots": [
        {
            "id": "hotspot_id",
            "name": "hotspot name",
            "reported_at": 123,
            "status": "success | error",
            "rssi": -30,
            "snr": 0.2,
            "spreading": "SF9BW125",
            "frequency": 923.3
        }
    ],
    "channels": [
        {
            "id": "uuid",
            "name": "channel name",
            "reported_at": 123,
            "status": "success | error | no_channel",
            "description": "what happened",
            // ONLY ON DEBUG MODE
            "debug": {req: {}, res: {}}
        }
    ]
}
```

## Docker Install

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
