# Organizations CLI

Router only cares about organizations from Console insofar as it can use DC for a device.

Similar to Devices, Console is the source of truth for an organization's DC balance.

> **NOTE: Commands in these docs assume an alias for `router`.**

```sh
alias router="docker exec -it helium_router _build/default/rel/router/bin/router"
```

## Commands

### List

```sh
router organization info all [--less=<less> --more=<more>]
```

List all organizations, their `dc_balance` and `nonce`.

### Info

```sh
router organization info <org_id> 
```

Single listing of `dc_balance` and `nonce` for `<org_id>`.

### Refill

```sh
router organization update <org_id> -b <balance> [--commit]
```

A way to update an organization's DC balance in Console from Router.
