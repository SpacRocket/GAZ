# gaz

A kdb+ tick stack built on [TorQ](https://github.com/DataIntellectTech/TorQ), laid
out so the local development stack and the AWS deployment are the same code with
different environment variables.

```
feed handler ──► tickerplant ──► rdb        (in memory, today)
  code/tick      tplog on         │
                 LOCAL disk       └─► wdb ──► sort ──► hdb ──► hdb readers
                                      staging          shared filesystem
                                          gateway ◄────────────┘
```

## Quick start

```bash
make bootstrap     # fetch TorQ, create data dirs
make test          # unit suite — no stack needed
make start         # bring the stack up
make status        # what is running, on which ports
make test-integration
make stop
```

Then query through the gateway:

```bash
q
q) h:hopen 6007
q) h"select count i by sym from trade"
```

Requires kdb+ 4.0+ on `PATH` (developed against 5.0) and a license. If your
`QHOME` is not `~/Applications/q`, put it in `env.local.sh`:

```bash
echo 'export QHOME=/opt/kdb' > env.local.sh
```

## Layout

| Path | What it is |
|---|---|
| `env.sh` | **The portability layer.** Every path in the system resolves from here |
| `database.q` | Tick schema — the single source of truth |
| `appconfig/process.csv` | Which processes exist, their types and ports |
| `appconfig/settings/` | Config overrides, layered by proctype then procname |
| `code/common/` | App library — auto-loaded into **every** process |
| `code/tick/feed.q` | Synthetic feed handler; replace with your adapter |
| `bin/gaz` | Process launcher (portable replacement for `torq.sh`) |
| `tests/unit/` | k4unit CSVs — pure functions, no stack required |
| `tests/integration/` | k4unit CSVs — assert against a running stack |
| `vendor/TorQ` | The framework, pinned as a submodule |
| `infra/` | Cloud notes and the AWS storage layout |

TorQ is vendored rather than copied into the repo. `TORQAPPHOME` (this repo) is
its designed extension point, so upgrading the framework is a submodule bump,
not a merge.

### Config layering

For a process of type `rdb` named `rdb1`, TorQ loads, in order:

```
vendor/TorQ/config/settings/default.q     framework defaults
vendor/TorQ/config/settings/rdb.q
appconfig/settings/default.q              ours — everything below overrides above
appconfig/settings/rdb.q
appconfig/settings/rdb1.q                 (optional, per-instance)
```

Put anything process-type-wide in `appconfig/settings/<proctype>.q`. Reserve
per-name files for genuine one-offs.

## Local → cloud

Nothing in `code/` or `appconfig/` hardcodes a path. To move the data layer,
export different values before `make start`:

| Variable | Local | AWS |
|---|---|---|
| `GAZ_HDB` | `./data/hdb` | `/fsx/hdb` — FSx for OpenZFS, over NFS |
| `GAZ_WDB` | `./data/wdb` | `/mnt/wdb` — local NVMe or EBS |
| `GAZ_TPLOG` | `./data/tplogs` | `/mnt/tplog` — **EBS, never the shared FS** |
| `GAZ_LOG` | `./data/logs` | `/var/log/gaz` |
| `KDBBASEPORT` | `6000` | anything; the whole stack moves together |

See [infra/README.md](infra/README.md) for why the tickerplant log stays off the
shared filesystem, and how ZFS clones give each developer a writable HDB.

### A caveat about local parity

macOS uses a **case-insensitive** filesystem by default; ZFS and ext4 do not.
A sym or column name differing only in case will work locally and break in
production. `docker/` builds a Linux image for this reason — use it before you
trust a change that touches file naming or on-disk layout.

Local testing also cannot tell you anything about mmap coherency over NFS, or
how the EOD reload behaves under many concurrent readers. Budget for a
short-lived FSx filesystem as a staging step.

## Tests

`k4unit` (shipped inside TorQ at `vendor/TorQ/tests/k4unit.q`) is table-driven:
each test is a CSV row.

```csv
action,ms,bytes,lang,code,repeat,minver,comment
true,0,0,q,.t.eqf[.gaz.vwap[100 102f;100 200i];101.33333f],1,,vwap
fail,0,0,q,.gaz.mid[1f;2f;3f],1,,mid is rank 2
```

`action` is `true` (expect `1b`), `fail` (expect an error), `run` (expect it not
to crash), or one of the `before`/`after` lifecycle hooks. Results land in
`KUTR`; `make test` exits non-zero with the failure count.

Two rules learned the hard way, both enforced by the existing tests:

- **Never start a `code` field with `"`.** q's CSV reader treats it as a quoted
  field and eats the quote. Write `(first exec t from meta[x] where c=`time)="p"`,
  not `"p"~first exec ...`.
- **Never compare floats with `=`.** Use `.t.eqf`, which compares within 1e-9.

Assertions needing quotes, commas or multiple statements belong in
`tests/helpers.q` as a named function, called from the CSV.

## Adding a process

1. Add a row to `appconfig/process.csv` (port as `{KDBBASEPORT}+n`).
2. Add `appconfig/settings/<proctype>.q` if it needs config.
3. `make restart`.

`startwithall` in column 11 controls whether `make start` picks it up.
