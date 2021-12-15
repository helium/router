# XOR Filters CLI 

XOR Filters are part of the OUI purchased when running an instance of Router.
The maximum allowed under an OUI is a [chain variable `max_xor_filter_num`](https://api.helium.io/v1/vars/max_xor_filter_num) (default: 5).

Device credentials are hashed (DevEUI, AppEUI) into the filters to allow gateways to check where to send Join Requests.

There is a fee to submit XOR txns with the chain based on the byte_size of the filter up to the [`max_xor_filter_size`](https://api.helium.io/v1/vars/max_xor_filter_size).

> **NOTE: Commands in these docs assume an alias for `router`.**

```sh
alias router="docker exec -it helium_router _build/default/rel/router/bin/router"
```

## Commands

### When is the next update?

```sh
router filter timer
```

Tells you how long until router checks for new devices with the paired Console.

`router_xor_filter_worker` periodically checks for new devices. If there are new devices, it will pick the smallest filter in the OUI by size and add the new devices to it. 

By default, it will check every `10 minutes`. This can be adjusted with the application var `router_xor_filter_worker_timer` in ms. 

### Force an update

```sh
router filter update [--commit]
```

Checks with Console and reports any devices to be added to the XOR filters. 

If `--commit` is provided, it will add the devices to the XOR filters immediately, ignoring the timer.

### Report

```sh
router filter report [--id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx]
```

Reports the binary size, and number of devices in each XOR filter.

If `--id=<device-id>` is passed, it will tell you which filter that device stored.

### RocksDB out of sync
```sh
router filter reset_db [--commit]
```

Devices are stored in rocksdb to help determine existing residence of devices in the filters when router is started. If rocks becomes out of sync with the devices in Console, this command will re-insert only existing devices into the database.
### Moving devices around

#### Migrate to another filter

```sh
router filter migrate --from=<from> --to=<to> [--commit]
```

> **NOTE: XOR filters are 0-indexed.**

Results in 2 txns.

1. Emptying the `<from>` filter.
2. Combining devices in `<from>` and `<to>` into the `<to>` filter.

If you have 2 filters, you can use this command to move all devices to a single filter to reduce subsequent XOR txn fees.

``` sh
router filter migrate --from=4 --to=0 --commit
```

This will remove all devices from filter 4 and merge them into filter 0.
Causing 2 txns to be submitted.
- New larger filter 0
- Empty filter 4

#### Move to Front

```sh
filter move_to_front <number_of_groups> [--commit]
```

`router_xor_filter_worker` tries to put new devices into the smallest available filter, eventually this will result in equally distributed filters. 

This command will take all devices from Console and split them amongst `<number_of_groups>` filters.

``` sh
router filter move_to_front 2 --commit
```

If you ran this command with the following filters...

| Filter | Num Devices |
|--------|-------------|
| 0      | 876         |
| 1      | 368         |
| 2      | 360         |
| 3      | 378         |
| 4      | 366         |

You would end up with... 

| Filter | Num Devices |
|--------|-------------|
| 0      | 1174        |
| 1      | 1174        |
| 2      | 0           |
| 3      | 0           |
| 4      | 0           |

This would allow the XOR Filters to be updated with new devices without incuring large txn fees.

#### Rebalancing

> **NOTE: Not recommended, this will result in every filter having the same txn fee.**

```sh
router filter rebalance [--commit]
```

Evenly distribute devices amongst existing filters.

