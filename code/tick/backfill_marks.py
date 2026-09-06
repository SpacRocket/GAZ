#!/usr/bin/env python3
"""Generate historical gas and carbon marks and save them straight into the HDB.

    backfill_marks.py 2026-08-07 2026-09-05

WHY THIS DOES NOT GO THROUGH THE TICKERPLANT, unlike backfill_power.py.

`power` carries `delivery`, a time axis independent of `time`. The tickerplant
stamps `time` on arrival, so a backfilled power row lands in today's partition
with a meaningless `time` and a correct `delivery` — and every query that
matters reads `delivery` (see the note in backfill_power.py).

`gas` and `carbon` have no such column. Look at database.q: their only time
column IS `time`. Push a month of marks through the tickerplant and every row
is stamped now — the whole series collapses onto a single instant,
.gv.markbucket folds it into one bucket, and the marginal-cost chart is exactly
as empty as it was before. There is no second axis to rescue it.

So these are written as partitions directly, which has a consequence worth
being explicit about: while it runs, THIS is the single writer against
GAZ_HDB (infra/README.md, rule 1). That is why it is a bootstrap tool and not
something the running stack ever invokes — run it against a quiet stack. It
reloads the HDB processes when it is done (rule 3), because they hold mmaps and
will not see a new partition otherwise.

Determinism: the walk is seeded, so the same range and seed regenerate byte
identical partitions. Re-running overwrites rather than appending, which is
what makes it safe to repeat — there is no ledger to keep, unlike the power
loader, because a partition write is naturally idempotent.

No copy of the price model lives here. sim_gas.make_batch and
sim_carbon.make_batch ARE the model, imported and driven at their own INTERVAL,
so a change to a level or a mean-reversion coefficient shows up in history and
in the live feed together. Generating at the native tick rate rather than a
coarser step is deliberate for the same reason: the mean-reversion coefficient
is per tick, so a 5-minute step would need k and sigma rescaled by the step
ratio to produce a statistically comparable series, and an unrescaled coarse
walk looks nothing like the feed it is supposed to be the history of.
"""

import argparse
import datetime as dt
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402
import pykx as kx  # noqa: E402

import sim_carbon  # noqa: E402
import sim_gas  # noqa: E402

HDB = os.environ.get("GAZ_HDB", "/fsx/hdb")

# Default seed. Fixed rather than random so a repeat run reproduces the same
# history: a chart that changes shape every time you reload the database is
# worse than useless for eyeballing a calculation against.
SEED = int(os.environ.get("GAZ_MARKS_SEED", "20260101"))

# (module, table, key column, key values). The key column differs per table —
# `hub` for gas, `contract` for carbon — and is the only structural difference
# between the two loads, so they share everything else.
DATASETS = {
    "gas": (sim_gas, "gas", "hub", None),
    "carbon": (sim_carbon, "carbon", "contract", None),
}


def _parse_date(s):
    try:
        return dt.date.fromisoformat(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a YYYY-MM-DD date: {s}")


def _reset(mod):
    """Put a sim module back to its cold-start state.

    Both modules hold the walk's position in a module-global `price` seeded
    from LEVEL. Without this a second date would continue from wherever the
    first one ended, which is right, and a second RUN would not, which is not.
    """
    if isinstance(mod.LEVEL, dict):
        mod.price = dict(mod.LEVEL)
    else:
        mod.price = mod.LEVEL


def _day(mod, day, key_col, not_after=None):
    """One partition's worth of marks: (times, keys, prices, srcs) as lists.

    Drives the live handler's own make_batch at its own INTERVAL, so the row
    count and the dynamics match what the feed would have produced had it been
    running that day.
    """
    step_ns = int(mod.INTERVAL * 1_000_000_000)
    base = np.datetime64(day.isoformat(), "ns").astype("int64")
    n = int(86_400_000_000_000 // step_ns)

    # Generating a whole day for TODAY runs the walk past the current time and
    # writes marks for hours that have not happened. On a chart that is worse
    # than the gap it fills: the line simply continues into the future, and
    # nothing downstream distinguishes a generated mark from a recorded one.
    # The walk is still advanced over the clipped tail so the price path stays
    # the one this seed produces — only the WRITING stops at `not_after`.
    times, keys, prices, srcs = [], [], [], []
    for i in range(n):
        keyv, pricev, srcv = mod.make_batch()
        t = base + i * step_ns
        if not_after is not None and t > not_after:
            continue
        k = keyv.py()
        times.extend([t] * len(k))
        keys.extend(k)
        prices.extend(pricev.py())
        srcs.extend(srcv.py())

    return times, keys, prices, srcs, key_col


def _table(times, keys, prices, srcs, key_col):
    """Build the tick table in the column order database.q declares."""
    return kx.Table(
        data={
            "time": np.array(times, dtype="datetime64[ns]"),
            key_col: kx.SymbolVector(keys),
            "price": np.array(prices, dtype="float64"),
            "src": kx.SymbolVector(srcs),
        }
    )


# Enumerate against the HDB's sym file and write the splayed table into the
# partition. .Q.en is what maps the symbol columns into `sym` — writing them
# unenumerated produces a partition the HDB cannot read back.
#
# No attribute is applied. The existing partitions carry none (the wdb's
# writedown does not add them either — check `meta gas` on the hdb), and a
# loader that silently disagreed with the daily path about on-disk layout is a
# difference that would surface much later as a puzzling query plan.
_SAVE = kx.q(
    "{[hdb;d;tbl;t] p:` sv hdb,(`$string d),tbl,`; p set .Q.en[hdb;t]; count t}"
)

# A partition must hold EVERY table in the database, not just the ones written
# into it. Writing gas and carbon into a new date leaves it with no `power` and
# no `bid` directory, and then any query spanning that date dies with
#   ./2026.08.08/power/time. OS reports: No such file or directory
# — not just for the new partitions but for the whole table, since one bad
# partition fails the lot. .gv.refreshhist traps that and returns 0, so the
# power chart quietly freezes on its last good pull with no error anywhere.
#
# .Q.chk fills the gaps with empty tables. It needs the schema, so the database
# has to be loaded for it to know what `power` and `bid` look like — hence
# loading the db first rather than calling .Q.chk against a bare path.
_CHK = kx.q("{[hdb] system\"l \",1_string hdb; .Q.chk hdb; :count key hdb}")

# Merge-write: keep whatever the partition already holds and fill only AROUND
# it. Used for a partition that is partly real — today's, typically, where the
# live feed recorded a couple of hours and the rest of the day is a hole.
#
# The span kept is [min time; max time] of the existing rows, so generated rows
# are dropped wherever real ones already exist and kept outside. That fills a
# hole before or after a contiguous block of real data, which is the shape a
# stack that was down for part of a day actually produces. It does NOT fill
# holes INSIDE that span — if the feed stopped and restarted mid-day, the
# middle stays empty rather than being spliced with synthetic prices, which is
# the conservative reading: never invent a price in a window we were up for.
#
# `sym` has to be in the workspace before `get` can resolve the enumerated
# columns, hence loading the database rather than reading the path cold.
# `select from get p`, not a bare `get p`. `get` on a splayed directory hands
# back a MEMORY-MAPPED table over those files, and the line below overwrites
# exactly those files — so a mapped `old` silently starts reading the new
# contents mid-function. It reported "39982 existing kept, 0 generated" for a
# partition that held 4092 rows. The select forces a copy into memory; the row
# counts are also taken BEFORE the write rather than after, so the summary
# cannot be retroactively rewritten by the thing it is summarising.
_MERGE = kx.q(
    "{[hdb;d;tbl;new]"
    " p:` sv hdb,(`$string d),tbl,`;"
    " old:$[() ~ key p; 0#new; select from get p];"
    " no:count old;"
    " t:$[no;"
    "     (select from new where not time within (min old`time;max old`time)),old;"
    "     new];"
    " nt:count t;"
    " p set .Q.en[hdb;`time xasc t];"
    " (nt;no)}"
)

_LOADDB = kx.q("{[hdb] @[{system\"l \",1_string x; 1b};hdb;{[e] 0b}]}")


# Partition directories are kdb dates — 2026.09.01, dotted — NOT the dashed
# ISO form. Checking isoformat() here looked right, matched nothing, and made
# --force a no-op: every run silently rewrote every partition it was pointed at.
def _partdir(day):
    return day.strftime("%Y.%m.%d")


def _existing(hdb, day, table):
    return os.path.isdir(os.path.join(hdb, _partdir(day), table))


def main(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Dates are UTC and both ends are inclusive.",
    )
    p.add_argument("start", type=_parse_date, help="first day, YYYY-MM-DD")
    p.add_argument("end", type=_parse_date, help="last day, YYYY-MM-DD")
    p.add_argument(
        "--tables",
        default="gas,carbon",
        help="comma separated subset of gas,carbon (default: both)",
    )
    p.add_argument("--hdb", default=HDB, help=f"database root (default: {HDB})")
    p.add_argument("--seed", type=int, default=SEED, help="walk seed")
    p.add_argument(
        "--force",
        action="store_true",
        help="overwrite partitions that already hold this table",
    )
    p.add_argument(
        "--fill",
        action="store_true",
        help="merge into partitions that already hold this table, keeping the "
        "existing rows and generating only outside their time span",
    )
    p.add_argument(
        "--allow-today",
        action="store_true",
        help="also write today's partition — the wdb owns it and may rewrite "
        "it at the next EOD, so anything written here can be lost",
    )
    p.add_argument(
        "--dry-run", action="store_true", help="report the plan, write nothing"
    )
    p.add_argument(
        "--reload",
        default=os.environ.get("GAZ_RELOAD_TARGETS", ""),
        help="comma separated host:port of hdb processes to reload afterwards",
    )
    args = p.parse_args(argv)

    if args.end < args.start:
        p.error("end is before start")

    names = [t.strip() for t in args.tables.split(",") if t.strip()]
    unknown = set(names) - set(DATASETS)
    if unknown:
        p.error(f"unknown table(s): {','.join(sorted(unknown))}")

    hdb = os.path.abspath(args.hdb)
    if not os.path.isdir(hdb):
        p.error(f"no database at {hdb}")

    # UTC, not the host's local date. Everything else in this stack is UTC —
    # the partition dates, the ENTSO-E windows, the Grafana dashboards — and a
    # loader running in a container an hour behind would otherwise decide a day
    # was still "today" and refuse to write it.
    today = dt.datetime.now(dt.timezone.utc).date()
    days = [
        args.start + dt.timedelta(days=i)
        for i in range((args.end - args.start).days + 1)
    ]

    # Today's partition belongs to the wdb, which rewrites it wholesale at EOD.
    # Anything written here would be silently replaced a few hours later, and
    # in the meantime the live marks and these would sit in the same partition
    # at two different densities.
    live = [d for d in days if d >= today]
    if live and args.allow_today:
        print(
            f"backfill_marks: WARNING writing {len(live)} day(s) from {live[0]} "
            f"— the wdb owns today's partition and may rewrite it at the next "
            f"EOD, losing this",
            flush=True,
        )
    elif live:
        print(
            f"backfill_marks: skipping {len(live)} day(s) from {live[0]} "
            f"— the live feed and the wdb own today's partition "
            f"(--allow-today to override)",
            flush=True,
        )
        days = [d for d in days if d < today]
    if not days:
        p.error("nothing to do: the whole range is today or later")

    plan = []
    for name in names:
        for d in days:
            if _existing(hdb, d, name) and not (args.force or args.fill):
                continue
            plan.append((name, d))

    skipped = len(names) * len(days) - len(plan)
    print(
        f"backfill_marks: {hdb} | {days[0]}..{days[-1]} | "
        f"{','.join(names)} | seed {args.seed}",
        flush=True,
    )
    if skipped:
        print(
            f"backfill_marks: {skipped} partition(s) already populated, "
            f"skipping (--force to overwrite)",
            flush=True,
        )
    if not plan:
        print("backfill_marks: nothing to write", flush=True)
        return 0

    if args.fill and not args.dry_run:
        # `get` on a splayed path returns enumerated symbol columns, which only
        # resolve once `sym` is in the workspace. Load once, not per partition.
        if not bool(_LOADDB(kx.SymbolAtom(f":{hdb}")).py()):
            p.error(f"--fill needs a loadable database at {hdb}")

    # Nanoseconds since the epoch, matching the datetime64[ns] the table uses.
    now_ns = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1_000_000_000)

    planned = set(plan)
    total = 0
    for name in names:
        mod, table, key_col, _ = DATASETS[name]
        # Seed and reset per TABLE, not per day, so the walk runs continuously
        # across the range the way the live feed would have, while a repeat run
        # of the same range still reproduces itself exactly.
        random.seed(args.seed + sum(map(ord, name)))
        _reset(mod)

        for d in days:
            rows = _day(mod, d, key_col, not_after=now_ns if d >= today else None)
            if (name, d) not in planned:
                # Still generated, so the walk stays continuous: skipping the
                # WRITE must not skip the days the price moved through, or
                # every partition after a gap starts from the wrong level.
                continue
            if args.dry_run:
                print(f"  would write {table} {d}: {len(rows[0])} rows", flush=True)
                total += len(rows[0])
                continue
            if args.fill:
                n, kept = (
                    int(x)
                    for x in _MERGE(
                        kx.SymbolAtom(f":{hdb}"), d, kx.SymbolAtom(table), _table(*rows)
                    ).py()
                )
                print(
                    f"  {table} {d}: {n} rows ({kept} existing kept, "
                    f"{n - kept} generated)",
                    flush=True,
                )
            else:
                n = int(
                    _SAVE(
                        kx.SymbolAtom(f":{hdb}"), d, kx.SymbolAtom(table), _table(*rows)
                    ).py()
                )
                print(f"  {table} {d}: {n} rows", flush=True)
            total += n

    verb = "would write" if args.dry_run else "wrote"
    print(f"backfill_marks: done — {verb} {total} rows", flush=True)

    if not args.dry_run:
        # Before the reload, never after: a reader told to reload a database
        # with a half-populated partition just caches the error.
        n = int(_CHK(kx.SymbolAtom(f":{hdb}")).py())
        print(
            f"backfill_marks: .Q.chk filled missing tables across {n} partitions",
            flush=True,
        )

    if args.dry_run or not args.reload:
        if not args.dry_run:
            print(
                "backfill_marks: no --reload targets given; hdb processes hold "
                "mmaps and will not see these partitions until they reload",
                flush=True,
            )
        return 0

    for target in [t.strip() for t in args.reload.split(",") if t.strip()]:
        try:
            host, _, port = target.partition(":")
            with kx.SyncQConnection(host, int(port)) as h:
                h(f"reload[{days[-1].isoformat().replace('-', '.')}]")
            print(f"backfill_marks: reloaded {target}", flush=True)
        except BaseException as e:  # noqa: BLE001 - a failed reload is not fatal
            print(f"backfill_marks: could not reload {target} ({e})", flush=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
