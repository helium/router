Runbook
=======

For regular operations and maintenance of the Router back-end of the Console

## Once Per New Server

General installation instructions are available on the Helium documentation
website.

> Start here:
[Run a Network Server](https://docs.helium.com/use-the-network/run-a-network-server/)
which goes from `git clone` through to various initial `docker` commands
such as loading an initial snapshot and testing with a real or virtual device.

Syntax of **Bash** shell is used below.

Create shell aliases.

Router:

```bash
alias router='docker exec -it helium_router router'
alias wallet='~/helium-wallet-rs/target/release/helium-wallet'
```

Console:

```bash
alias console_down='docker-compose down'
alias console_psql='docker exec -it helium_postgres psql -U postgres'
alias console_restart='console_down && console_up'
alias console_up='docker-compose build && docker-compose up -d && docker-compose logs -f'
alias console_update='docker-compose build --pull && console_restart'
```

Miscellaneous:

```bash
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'
```

With the above set of aliases defined and available in your current shell,
confirm:

```bash
router --help
```

## Stop/Start

On production servers, Console versus Router run on different hosts to
isolate and distribute workloads.

Because staging has far less traffic, everything runs on one host.

```bash
docker-compose down
docker-compose up -d
```

## Install A Release

Published Docker images are
[tagged](https://quay.io/repository/team-helium/router?tab=tags)
as `production` or `staging` as appropriate.

Install:

```bash
router install production
```

Restart the service:

```bash
docker-compose down && docker-compose up -d
```

## File System Cleanup

Keep `blockchain` because it contains your swarm key.

Keep `router.db` because it contains device cache.

Everything else under `/var/data/` may be purged for reclaiming space on the
file system.

## Funding

The wallet address may be extracted from a running server instance:

```bash
router peer addr
```

Take only the long alphanumeric sequence from the results *without* `/p2p/`
prefix:

```
/p2p/LongAhphaNumeric...
```

Look at your history of Data Credit consumption for the server, and forecast
your target amount on that trend.  This example uses a nice round `1.0`
billion DC.

Convert HNT to DC via prevailing exchange rate from the
[price oracle](https://api.helium.io/v1/oracle/prices/current).

Optionally, get
[predicted HNT Oracle Prices](https://api.helium.io/v1/oracle/predictions).
"If no predictions are returned, the current HNT Oracle Price is valid for at
least 1 hour."

Calculate `$target_dc / $oracle_price / 1000` or as Lisp expression for
target of 1.0 billion DC with HNT price of 2425000000 resulting in 412:

```lisp
(let ((current-hnt-price (/ 2425000000 1000))
      (target-dc (* 1.0 1000 1000 1000)))
  (floor (/ target-dc current-hnt-price)))
```

Use the resulting value as the `amount`:

```bash
helium-wallet burn --amount 412 --payee 123abc... --commit
```

Use the [Helium Wallet CLI](https://github.com/helium/helium-wallet-rs/)
or its equivalent.

## Snapshots

Snapshots can be fetched by URL but as of early 2022 are approaching 300MiB.

Fetch its metadata:

```bash
wget -N https://snapshots.helium.wtf/mainnet/latest-snap.json
```

The resulting JSON contains `height`, which gets used for file name of
snapshot to download.

```json
{
    "compressed_hash": "SGflG0oH0TTbairR3JCbtXoGJMhl6pYW4dHExmydRIc",
    "compressed_size": 262995691,
    "file_hash": "k0Pp00Y2wIeDagvzFMz66RAbD73e2y8fisCibP2Au2M",
    "file_size": 427285643,
    "hash": "3MmAnIgap0AMXL8n9eixxvnN8U8Qwtc3X_N6XXY1oR0",
    "height": 1279441
}
```

Craft the new URL based upon that height:

```bash
wget -N https://snapshots.helium.wtf/mainnet/snap-1279441.gz
```

However, those are **generated** from the chain approximately **every 11 hours**.

Therefore, compare chain heights or file timestamps.

```bash
curl https://api.helium.io/v1/blocks/height
```

Or:

```bash
curl --head https://snapshots.helium.wtf/mainnet/snap-1279441.gz
TZ=Z date
```

Scripted version:

```bash
wget -N \
  $(curl https://snapshots.helium.wtf/mainnet/latest-snap.json | \
    jq .height | \
    sed 's%^\(.*\)$%https://snapshots.helium.wtf/mainnet/snap-\1.gz%)'
```

The base of that URL is specified by `blockchain` `->` `snap_source_base_url`
within
[`sys.config.src`](https://github.com/helium/router/config/sys.config.src)
with the filename being then-current block height.

Similarly, locally generated snapshots should be within the directory path
specified by `blockchain` `->` `base_dir`.

### Manual Snapshots

Start on a server confirmed to be current with respect to blockchain height.

Maybe start on a validator, which uses the `minor` command rather than
`router` but otherwise works the same.

```bash
miner snapshot take latest.snap
docker cp validator:/opt/miner/latest.snap /tmp/
rsync -a /tmp/latest.snap  192.168.123.123:/var/data/latest.snap
```

Once copied to the intended server, load that snapshot:

```bash
router snapshot load /var/data/latest.snap
```

## Tracing A Device

```bash
router device trace --id=abc12345-bbbb-cccc-dddd-eeeeeeeeeeee
tail -F /var/data/router/log/traces/abc12.log
```

## Erlang Expressions

For one-off expressions **not** intended to impact the running BEAM, use `eval`:

```bash
router eval 'B = blockchain_worker:blockchain(), blockchain:height(B).'
router eval 'application:get_env(blockchain, snapshot_memory_limit).'
```

For applying new values to application variables, use `remote_console`.

> Be sure to **exit via `C-c C-c`** (Control-C twice) because using `q()`
> will take down the node.


```bash
router remote_console
application:set_env(blockchain, snapshot_memory_limit, 2048).
^D
```

If you use a particular expression upon several occasions, suggest it as a
[feature request](https://github.com/helium/router/issues/new/choose)
of the CLI.
