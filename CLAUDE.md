# gaz — working notes for Claude Code

kdb+ tick stack on TorQ (vendored submodule at `vendor/TorQ`). Designed so the
local stack and the AWS deployment are the same code with different env vars.

## Commands

```bash
make bootstrap        # submodule init + data dirs
make test             # unit suite, no stack needed. Exits non-zero on failure
make test-integration # starts stack, tests, tears down (trap on EXIT)
make start / stop / restart / status
make start P=rdb1     # single process
bin/gaz print <proc>  # show the generated q command line — first debugging step
bin/gaz tail <proc>

make backfill FROM=2026-01-01 TO=2026-06-30   # load ENTSO-E history (inclusive)
```

Query the gateway on port 6007. Base port is `KDBBASEPORT` (6000); every
process is `{KDBBASEPORT}+n` so the stack relocates as a unit.

## Environment

`env.sh` is the single source of truth for paths — nothing under `code/` or
`appconfig/` hardcodes one. Machine-specific overrides go in `env.local.sh`
(gitignored). `QHOME` defaults to `~/Applications/q`.

`TORQHOME` = the framework, `TORQAPPHOME` = this repo. Config layers as
`$KDBCONFIG/settings/{default,proctype,procname}.q` then the same under
`$KDBAPPCONFIG/settings/`, later overriding earlier.

`$KDBAPPCODE/common/` is auto-loaded into **every** process — that is how
`code/common/gaz.q` reaches the feed, rdb, hdb and gateway without being
listed anywhere.

## Gotchas found the hard way

These are all encoded in the code with comments; listed here so they are not
rediscovered.

- **The tickerplant prepends its own `time` column** (`stplog.q:53`). A feed
  that publishes `time` sends one column too many and the STP rejects the
  batch with `Bad message received, error: length`. `code/tick/feed.q`
  generates time locally for validation, then strips it on publish.
- **TorQ's `torq.sh` does not run on macOS** — it uses `hostname -I`,
  `hostname -A` and `envsubst`, all GNU-only. `bin/gaz` is a portable
  replacement building the identical command line.
- **Do not disable `.timer`.** `subscriptions.q:174` treats a non-zero
  `.sub.checksubscriptionperiod` with the timer off as a *fatal* init error.
  TorQ's own tickerplant config trips this; `appconfig/settings/segmentedtickerplant.q`
  fixes it by zeroing the subscription check instead.
- **A feed needs `.servers.CONNECTIONS`.** Without it `.servers.startup[]`
  dials nothing and `startupdepcycles` blocks forever — the process looks
  alive and publishes nothing. Same trap caught the integration test proc,
  which is why `itest` is a separate proctype from `test` rather than a
  command-line override: `.servers` has four interlocking flags.
- **Never pass `0W` as the cycle count** to `startupdepcycles` in a test. Bound
  it so a broken stack fails loudly instead of hanging CI.
- **k4unit CSV: never start a `code` field with `"`** — q's CSV reader eats the
  quote. Flip the comparison: `(first exec t from meta[x] where c=`time)="p"`.
- **Never compare floats with `=` in tests.** Use `.t.eqf` (1e-9 tolerance).
- **Parenthesise a cast on the left of `~`.** `` `date$()~f[x] `` parses right to
  left as `` `date$(()~f[x]) `` — it casts a boolean to a date and yields
  `2000.01.01`, so a `true` row reports as an *error*, not a failure. Write
  `` (`date$())~f[x] ``.
- **Don't assert against `GAZ_TPLOG`/`GAZ_HDB` for "empty directory" cases.**
  Both hold files once the stack has run, so the test passes only on a fresh
  checkout. Use `.t.emptydir` (a path that cannot exist).
- **qsql resolves names against the root namespace at runtime**, not the `\d`
  context the file was loaded under. Inside a `select`, fully qualify:
  `.gaz.bucket[...]`, not `bucket[...]`.
- **The `host` column in `process.csv` is how TorQ identifies a process**, and
  it matches `.z.h` *exactly* (case-insensitively, `torq.q:421`) — a process
  whose row says `gaz-tp` on a box where `.z.h` is `gaz-tp.internal` exits with
  "Current host does not match host specified in". `bin/gaz` matches on the
  short name so it stays usable on macOS (`.z.h` is `<name>.local` there), but
  TorQ is the strict one. Check `.z.h` on the target box, not `hostname`.
- **`TORQPROCESSES` selects the deployment topology**, so `env.sh` must not set
  it unconditionally. It used to, which silently made the containers use
  `appconfig/process.csv` instead of `docker/process.csv`.
- **`set` takes a SYMBOL on the left.** `` `.gv.hist set x `` assigns;
  `.gv.hist set x` — the bare name, so the table's *value* — neither assigns
  nor errors. It silently does nothing, so the only symptom is a view that
  stays empty for ever.
- **`@[f;(a;b);err]` passes the pair as ONE argument.** To apply a two-argument
  function with an error trap use `.[f;(a;b);err]`. Written with `@`,
  `.servers.gethandlebytype` returns a *projection* rather than a handle — no
  error, and `null` on it is false, so every guard downstream passes and the
  failure surfaces somewhere else entirely.
- **Backfilled prices land in TODAY's partition.** `code/tick/backfill_power.py`
  publishes through the tickerplant like every other feed — deliberately, since
  writing the HDB directly would break the single-writer rule the cloud layout
  depends on. But the STP stamps `time` itself, so a year of history all gets
  stamped now. `delivery` is the real time axis for `power`; query on it, never
  on `date`. Idempotent via `/mnt/state/backfill_seen.txt`, and it reads
  `entsoe_seen.txt` too so it cannot duplicate what the live feed published.
- **The image copies `/app` at build time**, so a new or edited Python handler
  is not in a running container. `make backfill` against a stale image silently
  runs the old code — rebuild, or `docker cp` while iterating.
- **A fresh stack has every plant at zero fuel, and that is correct.**
  `physical` is `sum DELIVERY - sum BURN` over the `fuelmove` ledger, and no
  feed ever publishes a DELIVERY row — `.bid.submit` only writes RESERVE and
  RELEASE. Gas has to be booked in with `.bid.refuel[plant;mwh]` (or
  `.bid.fill`/`.bid.fillall`), the `POST /gaz/refuel` and `POST /gaz/fillall`
  endpoints, or the "Refuel storage" panel on the bidding dashboard, before an
  offer of any size clears the reservation check. `fuelcap` in `plants.csv` is
  the ceiling, not the level.
- **A row you publish is not visible to you until the STP echoes it.** The
  tickerplant batches, so `.bid.state` still reports the pre-publish level for
  a beat afterwards — and two refuels of one plant inside that window both read
  it, both pass the fuelcap check and both land. Five requests in 40ms put the
  live stack at 575001 MWh against a 267000 ceiling. `.bid.pending` holds a
  delivery from publish until it is seen coming back (or a 30s TTL expires,
  because EOD clears `fuelmove` and the echo may never arrive) and `state`
  counts it as already in the tank. Anything else that publishes then re-reads
  has the same exposure.
- **HTTP writes are POST-only** (`w:\`POST~m` in `.gz.route2`). Matching on the
  path alone let a GET — a browser prefetch, an uptime probe, the URL pasted
  out of a comment — fill every tank. `/gaz/submit` was safe only by accident:
  a GET carries no body, so its JSON parse failed first.
- TorQ processes redirect stdout/stderr to timestamped files in `$KDBLOG`; the
  un-suffixed `out_<proc>.log` is a symlink that can point at a stale run.
  `ls -t data/logs/out_<proc>_*.log | head -1` when a log looks empty.

## Testing

k4unit ships inside TorQ (`vendor/TorQ/tests/k4unit.q`). `KDBTESTS` must point
at **TorQ's** tests dir — `-test` makes `torq.q:708` load the framework from
there. Our CSVs live in `GAZ_TESTS` and are named by `-test`.

Assertions needing quotes, commas or multiple statements go in
`tests/helpers.q` as named functions, called from the CSV.

`test` proctype = isolated (discovery off), `itest` = connected to the stack.

## Cloud

`infra/README.md` holds the AWS storage decisions and the reasoning. The two
rules the design depends on: the tickerplant log never goes on the shared
filesystem, and only the sort process mounts the HDB read-write.
