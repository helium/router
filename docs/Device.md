# Device CLI Commands

Router maintains a database in RocksDB of Devices, but the paired Console instance should always be viewed as the source of truth for a Device.

> XOR Filter commands have been relocated under `router filter`.

> **NOTE: Commands in these docs assume an alias for `router`.**

```sh
alias router="docker exec -it helium_router _build/default/rel/router/bin/router"
```

## Commands

### List

```sh
router device all
```

Queries Console to report all devices.

### Info

```sh
router device --id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Simple information for a device. `<id>` is the device ID from Console, not the `app_eui` or `dev_eui`.

### Tracing

```sh
router device trace --id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx [--stop]
```

Tracing a device will set all logs related to a device to debug level for `240 minutes`, writing to the file `{BASE_DIR}/traces/{first-5-chars-of-device-id}.log`.

Information about the device considered for logging
- `device_id` 
- `dev_eui`
- `app_eui`
- `devaddr`

> **NOTE:** `devaddr` may result in some logs from other devices in places where the device cannot be accurately determined.

Pass the `--stop` option to stop the trace before the `240 minutes` is over.

Traces will not survive through restart.

### Device Queue

```sh
router device queue --id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Print out the downlink queue of a device.

```sh
router device queue clear --id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Empty the downlink queue of a device.

```sh
router device add --id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --payload=<payload> [--channel-name=<name> --ack=<ack> --port=<port>]
```

| Option           | Type    | Default                       | Description                                |
|------------------|---------|-------------------------------|--------------------------------------------|
| `--payload`      | string  | None                          | Content to queue for the device            |
| `--channel-name` | string  | `"Test cli downlink message"` | Name of integration to report in Console   |
| `--port`         | number  | `1`                           | Port to send downlink (`0` is not allowed) |
| `--ack`          | boolean | `false`                       | Confirmed or Unconfirmed downlink          |

### Prune

Router keeps a copy of devices in Rocksdb. If devices are removed from Console but not Router, this command will remove them from Router.

> **NOTE:** This can take a while if you have a lot of devices in your Console.

```sh
router device prune [--commit]
```
