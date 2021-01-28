# Helium Router ![CI](https://github.com/helium/routerv3/workflows/CI/badge.svg?branch=master)

Helium's LoRa Network Server (backend of https://github.com/helium/console).

## Usage

### Testing / Local

```
# Build
make docker-build

# Run
make docker-run

# Running tests
make docker-test

```

### Production

Image repository coming soon.

```
# Build
docker-compose build --force-rm

# Up
docker-compose up -d

# Down
docker-compose down

# Tail logs
docker-compose logs -f --tail=20

# Get in container
docker exec -it helium_router bash

```

### Data

Data is stored in `/var/data`.

**WARNING**: The `sawrm_key` file in the `blockchain` directory is router's indentity and linked to your `OUI` (and routing table). **DO NOT DELETE THIS EVER**

### Config

Config is in `.env`.

```
# Default Helium's seed nodes
ROUTER_SEED_NODES=/ip4/34.222.64.221/tcp/2154,/ip4/34.208.255.251/tcp/2154

# OUI used by router (see https://developer.helium.com/blockchain/blockchain-cli#oui)
ROUTER_OUI=22

# Default devaddr if we fail to allocate one
ROUTER_DEFAULT_DEVADDR=AAQASA==

# State Channel Open amount
ROUTER_SC_OPEN_DC_AMOUNT=100000

# State Channel block expiration
ROUTER_SC_EXPIRATION_INTERVAL=45

# Console's connection info (see https://github.com/helium/console)
ROUTER_CONSOLE_ENDPOINT=http://helium_console:4000
ROUTER_CONSOLE_WS_ENDPOINT=ws://helium_console:4000/socket/router/websocket
ROUTER_CONSOLE_SECRET=XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

Router's deafult port for blockchain connection is `2154`.

## Integrations Data

Data payload example sent to integrations

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
    "payload_size": 22,
     // ONLY if payload is decoded
    "decoded": {
        "status": "success | error",
        "error": "...",
        "payload": "..."
    },
    "port": 1,
    "devaddr": "devaddr",
    "hotspots": [
        {
            "id": "hotspot_id",
            "name": "hotspot name",
            "reported_at": 123,
            "status": "success | error",
            "rssi": -30,
            "snr": 0.2,
            "spreading": "SF9BW125",
            "frequency": 923.3,
            "channel": 12,
            "lat" => 37.00001962582851,
            "long" => -120.9000053210367
        }
    ],
    "dc" : {
        "balance": 3000,
        "nonce": 2
    }
}
```
## CLI

Coming soon...

## Metrics

Coming soon...