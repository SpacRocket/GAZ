#!/usr/bin/env python3
"""Backfill historical ENTSO-E day-ahead power prices over a date range.

    backfill_power.py 2026-01-01 2026-06-30

entsoe_power.py only ever looks at a four-day window around now, because that
is all a live feed needs. This is the same data through the same pipe, for a
range you name — for standing up a fresh HDB, or filling a gap left by a stack
that was down.

WHAT IT DOES NOT DO IS WRITE TO THE HDB. It publishes to the tickerplant like
any other feed, so the rows travel the ordinary tp -> wdb -> sort -> hdb path.
That is not laziness: infra/README.md's layout depends on the sort process
being the *only* writer against the shared filesystem, which in AWS is what
lets every other process mount it read-only. A loader that wrote partitions
itself would need the HDB read-write and break that rule.

Two consequences of going through the tickerplant, both worth knowing before
you read the data back:

  * `time` is stamped by the tickerplant (stplog.q:53), so every backfilled row
    is stamped NOW, not when the price was published. `delivery` is the real
    time axis and always was — a live poll at 13:00 also lands tomorrow's whole
    curve under today's `time`. Nothing new, just more of it.
  * Therefore the rows land in TODAY's HDB partition, however old the prices
    are. Query power on `delivery`, never on `date`.

`src` is `ENTSOE`, the same as the live feed. Downstream prefers ENTSOE over
SIM and falls back (grafanaviews.q:62, spread.q:65) — a distinct src would
silently drop backfilled history out of every one of those views.

Reads ENTSOE_API_KEY, like the live feed. Needs PyKX, so run it in the stp
container where PyKX and the tickerplant both are:

    make backfill FROM=2026-01-01 TO=2026-06-30
"""

import argparse
import datetime as dt
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gazfeed as gf  # noqa: E402 - path must be set first

# The A44 request, the curveType A03 gap carry-forward and the zone -> EIC map
# are shared with the live feed on purpose. That parser is the subtle part of
# this integration (an omitted position means "the previous price continues",
# not "no data"), and a second copy of it would drift.
import entsoe_power as ep  # noqa: E402

NAME = "backfill_power"
TABLE = "power"

# Which (zone, delivery) pairs this loader has already published. Separate from
# the live feed's state file because the two have opposite retention needs:
# entsoe_power prunes its set to four days so a long-running process does not
# grow without bound, which would drop every historical key here and make a
# repeat run duplicate everything it did last time.
LEDGER = os.environ.get("GAZ_BACKFILL_STATE", "/mnt/state/backfill_seen.txt")

# Days of delivery per API request. ENTSO-E allows up to a year in one A44
# call, but a month keeps each response small enough to fail cheaply and
# retry, and keeps progress output meaningful on a multi-year load.
CHUNK_DAYS = int(os.environ.get("GAZ_BACKFILL_CHUNK_DAYS", "30"))

# Courtesy pause between requests. The published limit is 400 requests/minute
# and a year of five zones is 60 requests, so this is nowhere near it — it just
# keeps a long run from looking like a scraper.
PAUSE = float(os.environ.get("GAZ_BACKFILL_PAUSE", "1"))


def _load_ledger(path):
    """Read a `zone|iso` state file into a set. Missing file means cold start.

    Same format as entsoe_power.STATE, so the live feed's file can be read with
    this too — see _seen_from_disk for why that matters.
    """
    seen = set()
    try:
        with open(path) as fh:
            for line in fh:
                zone, _, iso = line.strip().partition("|")
                if zone and iso:
                    seen.add((zone, dt.datetime.fromisoformat(iso)))
    except FileNotFoundError:
        pass
    except BaseException as e:  # noqa: BLE001 - a cold start is always safe
        print(f"{NAME}: could not read {path} ({e}) - ignoring it", flush=True)
    return seen


def _seen_from_disk():
    """Everything already published, by this loader OR by the live feed.

    Reading entsoe_power's file too is what stops a backfill whose range runs
    up to the present from duplicating points the live feed published minutes
    ago. It is read only, never written: the live feed rewrites that file
    wholesale from its own in-memory set on every save, so anything added here
    would be erased by its next publish.
    """
    mine = _load_ledger(LEDGER)
    live = _load_ledger(ep.STATE)
    print(
        f"{NAME}: {len(mine)} points from previous backfills, "
        f"{len(live)} from the live feed",
        flush=True,
    )
    return mine | live


def _append_ledger(keys):
    """Record published points, appending rather than rewriting.

    Append because a backfill is long and interruptible. Rewriting the whole
    file at the end would mean a run killed at 90% has published nine months of
    prices and remembers none of them, so the retry duplicates all nine.
    """
    try:
        os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
        with open(LEDGER, "a") as fh:
            for zone, delivery in keys:
                fh.write(f"{zone}|{delivery.isoformat()}\n")
    except BaseException as e:  # noqa: BLE001 - persistence is best effort
        print(f"{NAME}: could not write {LEDGER} ({e})", flush=True)


def _chunks(start, end, days):
    """Split [start, end) into request-sized [a, b) windows."""
    a = start
    while a < end:
        b = min(a + dt.timedelta(days=days), end)
        yield a, b
        a = b


def _live_floor(now):
    """The first delivery period the live feed owns.

    entsoe_power polls from midnight yesterday forward, so anything at or after
    this instant is its job. Backfilling into that window races it and produces
    duplicate delivery periods, because neither process can see the other's
    in-memory state until it next writes its file.
    """
    return (now - dt.timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )


def _parse_date(s):
    try:
        return dt.datetime.strptime(s, "%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a YYYY-MM-DD date: {s}")


def _collect(zones, lo, hi, seen):
    """Fetch one window and return the unseen (zone, delivery, price) rows.

    Rows outside [lo, hi) are kept, not dropped. ENTSO-E answers in whole
    market days and day-ahead days are CET, so a UTC-bounded request returns an
    hour or two either side; those points are real prices and the ledger stops
    the neighbouring chunk from sending them twice.
    """
    rows = []
    for zone in zones:
        try:
            for delivery, price in ep._parse(ep._fetch(ep.ZONES[zone], lo, hi)):
                key = (zone, delivery)
                if key in seen:
                    continue
                seen.add(key)
                rows.append((zone, delivery, price))
        except BaseException as e:  # noqa: BLE001 - one bad zone must not stop the rest
            # Routine, not fatal: ENTSO-E answers "No matching data found" for
            # any period before a bidding zone existed, and 503s under load.
            print(
                f"{NAME}: {zone} {lo:%Y-%m-%d}.."
                f"{(hi - dt.timedelta(days=1)):%Y-%m-%d} failed: {e}",
                flush=True,
            )
        time.sleep(PAUSE)
    return rows


def main(argv=None):
    p = argparse.ArgumentParser(
        description="Backfill ENTSO-E day-ahead power prices through the tickerplant.",
        epilog="Dates are UTC and both ends are inclusive: 2026-01-01 2026-01-31 "
        "loads all of January.",
    )
    p.add_argument("start", type=_parse_date, help="first delivery day, YYYY-MM-DD")
    p.add_argument("end", type=_parse_date, help="last delivery day, YYYY-MM-DD")
    p.add_argument(
        "--zones",
        default=",".join(ep.ZONES),
        help=f"comma separated subset of {','.join(ep.ZONES)} (default: all)",
    )
    p.add_argument(
        "--chunk-days", type=int, default=CHUNK_DAYS, help="delivery days per request"
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="fetch and report, publishing nothing and recording nothing",
    )
    p.add_argument(
        "--allow-live-window",
        action="store_true",
        help="do not clamp the range short of what the live feed is polling",
    )
    p.add_argument(
        "--strict-range",
        action="store_true",
        help="publish only deliveries inside the requested range, discarding "
        "the neighbouring market days ENTSO-E returns with them",
    )
    args = p.parse_args(argv)

    if not ep.API_KEY:
        print(f"{NAME}: ENTSOE_API_KEY is not set — refusing to start", flush=True)
        return 1

    zones = [z.strip() for z in args.zones.split(",") if z.strip()]
    unknown = [z for z in zones if z not in ep.ZONES]
    if unknown:
        print(f"{NAME}: unknown zone(s) {','.join(unknown)}", flush=True)
        return 2

    if args.end < args.start:
        print(f"{NAME}: end {args.end:%Y-%m-%d} is before start", flush=True)
        return 2

    # Inclusive end date, exclusive internal bound: "to the 31st" means through
    # the whole of the 31st, which is the reading anyone typing a date expects.
    lo = args.start
    hi = args.end + dt.timedelta(days=1)

    floor = _live_floor(dt.datetime.now(dt.timezone.utc).replace(tzinfo=None))
    if hi > floor and not args.allow_live_window:
        if lo >= floor:
            print(
                f"{NAME}: the whole range is inside the live feed's window "
                f"(from {floor:%Y-%m-%d}) — entsoe_power.py already covers it. "
                f"Nothing to do.",
                flush=True,
            )
            return 0
        print(
            f"{NAME}: clamping end to {floor:%Y-%m-%d}; from there on the live "
            f"feed is publishing the same periods (--allow-live-window to override)",
            flush=True,
        )
        hi = floor

    seen = _seen_from_disk()
    conn = None
    if not args.dry_run:
        try:
            # Bounded, unlike a live handler: this is interactive, and hanging
            # for ever against a stopped stack helps nobody.
            conn = gf.connect(NAME, attempts=10)
        except BaseException as e:  # noqa: BLE001
            print(f"{NAME}: no tickerplant ({e}) — is the stack up?", flush=True)
            return 3

    total = 0
    print(
        f"{NAME}: {'planning' if args.dry_run else 'loading'} "
        f"{lo:%Y-%m-%d}..{(hi - dt.timedelta(days=1)):%Y-%m-%d} "
        f"for {','.join(zones)}",
        flush=True,
    )

    for a, b in _chunks(lo, hi, args.chunk_days):
        # Half-open internally, inclusive on screen — the same dates the
        # operator typed, so progress lines can be compared with the request.
        span = f"{a:%Y-%m-%d}..{(b - dt.timedelta(days=1)):%Y-%m-%d}"
        rows = _collect(zones, a, b, seen)
        if args.strict_range:
            # ENTSO-E answers in whole CET market days, so a request for one
            # day comes back with an hour or two of its neighbours attached.
            # Normally those are kept — they are real prices and the ledger
            # stops the next chunk resending them. But when you are REPAIRING a
            # single day, the neighbours are days that already loaded fine, and
            # keeping them republishes hundreds of rows that are already in the
            # database purely as duplicates.
            #
            # The discarded keys are removed from `seen` as well as from `rows`:
            # _collect adds every key it yields, and leaving them marked as seen
            # would tell a later run those neighbours are done when they were
            # never published.
            keep, drop = [], []
            for r in rows:
                (keep if a.replace(tzinfo=None) <= r[1] < b.replace(tzinfo=None) else drop).append(r)
            for r in drop:
                seen.discard((r[0], r[1]))
            if drop:
                print(
                    f"{NAME}: {span} discarding {len(drop)} point(s) outside "
                    f"the requested range (--strict-range)",
                    flush=True,
                )
            rows = keep
        if not rows:
            print(f"{NAME}: {span} nothing new", flush=True)
            continue

        if args.dry_run:
            print(f"{NAME}: {span} {len(rows)} points", flush=True)
            total += len(rows)
            continue

        # Synchronous: back-pressure is wanted here. A bulk load sending
        # thousands of rows as fast as it can parse them would otherwise queue
        # up inside the tickerplant behind the live feeds.
        gf.publish(
            conn,
            TABLE,
            (
                gf.SymbolVector([r[0] for r in rows]),
                gf.TimestampVector([r[1] for r in rows]),
                gf.FloatVector([r[2] for r in rows]),
                gf.SymbolVector(["ENTSOE"] * len(rows)),
            ),
            wait=True,
        )
        _append_ledger([(r[0], r[1]) for r in rows])
        total += len(rows)
        print(f"{NAME}: {span} published {len(rows)}", flush=True)

    verb = "would publish" if args.dry_run else "published"
    print(f"{NAME}: done — {verb} {total} price points", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
