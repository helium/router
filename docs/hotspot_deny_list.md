# Hotspot Deny List

The Hotspot Deny List allows to reject any offer from unwanted hotspots.

## Config

- By default the deny list is **disabled**, to enable set env variablable `ROUTER_HOTSPOT_DENY_LIST_ENABLED=true` in your `.env`.
- Config file `hotspot_deny_list.json` (by default) should be placed in data root directory by default `/var/data`.
- `hotspot_deny_list.json` should only be a simple array:
```json
["112NiuFH2rJmeTTvr84Tov6tkXnWEQEVqHaJEu2qsQBxPvYuzw4c", "1121pS286YsPR6fohpLkzXA99gAkQpwftiGdoteqzn4rbEzoZCWy"]
```

*Note: default file can be change via `sys.config` `{hotspot_deny_list, "alternarive_hotspot_deny_list.json"}`*

## Usage

### CLI

`router hotspot_deny_list`

#### Display list

`router hotspot_deny_list ls`

#### Add to list

`router hotspot_deny_list add 112NiuFH2rJmeTTvr84Tov6tkXnWEQEVqHaJEu2qsQBxPvYuzw4c`

#### Remove from list

`router hotspot_deny_list remove 112NiuFH2rJmeTTvr84Tov6tkXnWEQEVqHaJEu2qsQBxPvYuzw4c`


**Note: any add/remove does not get saved to config file, `hotspot_deny_list.json` will need to be updated indifidually**