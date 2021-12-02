# Helium Router ![CI](https://github.com/helium/routerv3/workflows/CI/badge.svg?branch=master) ![BUILD_AND_PUSH_IMG](https://github.com/helium/routerv3/workflows/BUILD_AND_PUSH_IMG/badge.svg)

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

Config is in `.env`. See `.env-template` for details.

Full config is in `config/sys.config.src`.

Router's deafult port for blockchain connection is `2154`.

Prometheus template config file in `prometheus-template.yaml`.
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

#### Info for a single device
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

#### Trace a device's logs
```
device trace --id=<id>
```
##### Options
[ID Options](#id-option)

#### Stop trancing  device's logs
```
device trace stop --id=<id>
```
##### Options
[ID Options](#id-option)

#### Force XOR Filter push
```
device xor
```
##### Options
XOR will only happen if `--commit` is used, otherwise it will be a dry run.

### Organization `organization`

#### All Orgs
```
organization info all [--less 42] [--more 42]
```
##### Options
`--less <amount>`
Filter to Organizations that have a balance less than `<amount>`.

`--more <amount>`
Filter to Organizations that have a balance more than `<amount>`.

#### Info for 1 Org
```
organization info <org_id>
```

#### Update Org Balance
```
organization update <org_id> -b <balance> [--commit]
```

##### Options
`-b`
Balance to update to

Balance update will only happen if `--commit` is used, otherwise it will be a dry run.

## Integrations Data

Data payload example sent to integrations

```
{
    "type": "uplink / join",
    "replay": false,
    "id": "device_uuid",
    "name": "device_name",
    "dev_eui": "dev_eui",
    "app_eui": "app_eui",
    "metadata": {},
    "fcnt": 2,
    "reported_at": 1619562788361,
    "payload": "base64 encoded payload",
    "payload_size": 22,
    "raw_packet": "base64 encoded (full) lora packet",
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
            "reported_at": 1619562788361,
            "hold_time": 250,
            "status": "success | error",
            "rssi": -30,
            "snr": 0.2,
            "spreading": "SF9BW125",
            "frequency": 923.3,
            "channel": 12,
            // WARNING: if the hotspot is not found (or asserted) in the chain the lat/long will come in as a string "unknown"
            "lat": 37.00001962582851,
            "long": -120.9000053210367
        }
    ],
    "dc" : {
        "balance": 3000,
        "nonce": 2
    }
}
```

### Clearing a Device Queue from an Integration

If the **payload_raw** field is the base64 encoded value `'__clear_downlink_queue__'` any downlinks queued for that device will be removed.


## Metrics

Router includes metrics that can be retrieved via [prometheus](https://prometheus.io/docs/introduction/overview/).

### Enable metrics

To enable Router's metrics you will need to add a new container for Prometheus, you can find an example of the setup in any of the `docker-compose` files.
You can also get a basic configuration for prometheus in `prometheus-template.yml`, [more config here](https://prometheus.io/docs/prometheus/latest/configuration/configuration/).

### Available metrics

See `include/metrics.hrl`

Note that any [histogram](https://prometheus.io/docs/concepts/metric_types/#histogram) will include `_count`, `_sum` and `_bucket`.
### Displaying metrics

##### Grafana

Here are some of the most commun queries that can be added into grafana.

`sum(rate(router_device_routing_packet_duration_count{type="packet", status="accepted"}[5m]))` Rate of accepted packet.

`rate(router_device_routing_offer_duration_sum{status="accepted"}[5m])/rate(router_device_routing_offer_duration_count{status="accepted"}[5m])` Time (in ms) to handle offer (accepted)

`router_dc_balance{}` Simple count of your Router's balance

`sum(rate(router_console_api_duration_count{status="ok"}[5m])) / (sum(rate(router_console_api_duration_count{status="error"}[5m])) + sum(rate(router_console_api_duration_count{status="ok"}[5m]))) * 100` API success rate

## Supported Countries/Frequencies

### US915
**Uplink**
- 902.3 MHz increment by 200 Hz
- 903.0 MHz increment by 1600 Hz

**Downlink**
- 923.3 MHz increment by 600 Hz (RX1)
- 923.3 MHz (RX2)

### CN470
**Uplink**
- 470.3 MHz increment by 200 Hz

**Downlink**
- 500.3 MHz increment by 600 Hz (RX1)
- 505.3 MHz (RX2)

### AU915
**Uplink**
- 915.2 MHz increment by 200 Hz
- 915.9 MHz increment by 1600 Hz

**Downlink**
- 923.3 MHz increment by 600 Hz (RX1)
- 923.3 MHz (RX2)

### EU868
**Uplink**
- 867.1 MHz
- 867.3 MHz
- 867.5 MHz
- 867.7 MHz
- 867.9 MHz

**Downlink**
- Same as uplink (RX1)
- 869.525 MHz (RX2)

### AS923

**Default Frequencies**
- 923.2 MHz (uplink/downlink)
- 923.4 MHz (uplink/downlink)
- 923.2 MHz (RX2 downlink)

##### AS923_1
- 923.6 MHz
- 923.8 MHz
- 924.0 MHz
- 924.2 MHz
- 924.4 MHz

##### AS923_2
- 921.8 MHz
- 922.0 MHz
- 922.2 MHz
- 922.4 MHz
- 922.6 MHz

##### AS923_3
- 917.0 MHz
- 917.2 MHz
- 917.4 MHz
- 917.6 MHz
- 917.8 MHz

##### AS923_4
- 917.7 MHz
- 917.9 MHz
- 918.1 MHz
- 918.3 MHz
- 918.5 MHz
 
