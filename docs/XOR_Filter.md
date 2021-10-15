# XOR Filters

XOR Filters are part of the OUI purchased when running an instance of Router.
The maximum allowed under an OUI is a [chain variable `max_xor_filter_num`](https://api.helium.io/v1/vars/max_xor_filter_num) (default: 5).

Device credentials are hashed (DevEUI, AppEUI) into the filters to allow gateways to check where to send Join Requests.

There is a fee to submit XOR txns with the chain based on the byte_size of the filter up to the [`max_xor_filter_size`](https://api.helium.io/v1/vars/max_xor_filter_size).

`router_xor_filter_worker` checks for new devices every 10 minutes. If there are new devices, it will pick the smallest filter in the OUI by size and add the new devices to it. 

Eventually, as the number of devices in Console grow, the filters will even out in size, and adding a single device to any one will start to cost more than expected.

The router CLI has 2 commands to help with this situation.

``` sh
router filter migrate --from=4 --to=0
```

This will remove all devices from filter 4 and merge them into filter 0.
Causing 2 txns to be submitted.
- New larger filter 0
- Empty filter 4

> NOTE: XOR Filters are 0-indexed 

``` sh
router filter move_to_front 2
```

Running this will take all known devices and distribute them evenly between the first 2 filters, and empty the remaining 3.

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
