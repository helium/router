# Helium Router ![CI](https://github.com/helium/routerv3/workflows/CI/badge.svg?branch=master) [![Docker Repository on Quay](https://quay.io/repository/team-helium/router/status "Docker Repository on Quay")](https://quay.io/repository/team-helium/router)

Helium's LoRa Network Server (LNS) backend.

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

Image hosted on https://quay.io/repository/team-helium/router.

> The `docker-compose` in this repo is an example and only runs `Router` and `metrics server` (via prometheus) please see https://github.com/helium/console to run full LNS stack. 
> It will build a local image and not use the latest from the registery.
```
# Replace this
build: .
image: quay.io/team-helium/router:local
```
```
# By this to use latest image
image: quay.io/team-helium/router:latest
```

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

> **WARNING**: The `swarm_key` file in the `blockchain` directory is router's identity and linked to your `OUI` (and routing table). **DO NOT DELETE THIS EVER**.

### Logs

Logs are contained in `/var/data/log/router.log`, by default logs will rotate every day and will remain for 7 days.
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

Full config is in `config/sys.config.src`.
## CLI
Commands are run in the `routerv3` directory using a docker container.
> **_NOTE:_**  `sudo` may be required

```
docker exec -it helium_router _build/default/rel/router/bin/router [CMD]
```
Following commands are appending to the docker command above.

### Device Worker `device`

#### All Devices
```
device all
```

#### Info for 1 Device
```
device --id=<id>
```
##### Id Option
`--id`
Device IDs are binaries, but should be provided plainly.
```
# good
device --id=1234-5678-890
# bad
device --id=<<"1234-5678-890">>
```

#### Single Device Queue
```
device queue --id=<id>
```
##### Options
[ID Options](#id-option)
#### Clear Device's Queue
```
device queue clear --id=<id>
```
##### Options
[ID Options](#id-option)

#### Add to Device's Queue
```
device queue add --id=<id> [--payload=<content> --channel-name=<name> --port=<port> --ack]
```
##### Options
`--id`
[ID Options](#id-option)
`--payload [default: "Test cli downlink message"]`
Set custom message for downlink to device.

`--channel-name [default: "CLI custom channel"]`
Channel name Console will show for Integration.

`--port [default: 1]`
Port to downlink on.

`--ack [default: false]`
Boolean flag for requiring acknowledgement from the device.
### DC Tracker `dc_tracker`

#### All Orgs
```
dc_tracker info all [--less 42] [--refetch]
```
##### Options
`--less <amount>`
Filter to Organizations that have a balance less than `<amount>`.

`--refetch`
Update Router information about organizations in list.

#### Info for 1 Org
```
dc_tracker info <org_id> [--refetch]
```
##### Options
`--refetch`
Update Router information about this organization.

#### Refill Org Balance
```
dc_tracker refill <org_id> balance=<balance> nonce=<nonce>
```

#### Helpers
```
dc_tracker info no-nonce
dc_tracker info no-balance
```
are aliases for

```
dc_tracker info nonce <amount=0>
dc_tracker info balance <balance=0>
```

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

## Metrics

Coming soon...
