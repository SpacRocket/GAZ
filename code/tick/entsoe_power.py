#!/usr/bin/env python3
"""ENTSO-E Transparency day-ahead power prices — the real power feed.

Replaces sim_power.py: same table, same columns, src=`ENTSOE instead of `SIM.

Day-ahead prices are free here, which matters — EPEX SPOT's own API starts at
EUR 1,040/month, and these are the same auction results.

Cadence is nothing like a market feed. Prices for the whole of tomorrow are
published once a day (around 13:00 CET, after the auction clears), as a curve
of delivery periods. So this polls slowly and republishes nothing: each
(zone, delivery) pair is sent to the tickerplant exactly once, the first time
it is seen. `time` is when we ingested it; `delivery` is the period the price
is for. Those are genuinely different and both matter.

Requires ENTSOE_API_KEY. Get one by registering at transparency.entsoe.eu and
emailing transparency@entsoe.eu with "RESTful API access" in the subject.
"""

import datetime as dt
import os
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gazfeed as gf  # noqa: E402 - path must be set first

NAME = "entsoe_power"
TABLE = "power"

API = "https://web-api.tp.entsoe.eu/api"
API_KEY = os.environ.get("ENTSOE_API_KEY", "")

# Day-ahead publishes once a day; polling every 15 minutes catches it promptly
# without going anywhere near ENTSO-E's 400 requests/minute limit.
INTERVAL = float(os.environ.get("GAZ_ENTSOE_INTERVAL", "900"))

# Bidding zone -> EIC area code. The zone names match sim_power.py so the two
# are interchangeable downstream.
ZONES = {
    "DE_LU": "10Y1001A1001A82H",
    "FR": "10YFR-RTE------C",
    "NL": "10YNL----------L",
    "BE": "10YBE----------2",
    "ES": "10YES-REE------0",
}

NS = {"p": "urn:iec62325.351:tc57wg16:451-3:publicationdocument:7:3"}

RESOLUTION_MINUTES = {"PT15M": 15, "PT30M": 30, "PT60M": 60, "PT1H": 60}

# (zone, delivery) already published, so a repeated poll is a no-op. Pruned to
# a few days so a long-running process does not grow without bound.
_seen = set()


def _seed_from_rdb():
    """Recover what has already been published, so a restart is not a republish.

    _seen lives in memory, so every container restart used to re-ingest the
    whole window — the power table ended up holding several rows per delivery
    period, some of them genuinely disagreeing because ENTSO-E also revises
    prices. Asking the RDB what it already has makes the published data the
    source of truth rather than this process's uptime.

    Best effort: if the RDB is not up yet the feed simply starts cold, which is
    the old behaviour and no worse.
    """
    try:
        conn = gf.kx.SyncQConnection(
            os.environ.get("GAZ_RDB_HOST", "rdb"),
            int(os.environ.get("GAZ_RDB_PORT", "6002")),
            no_ctx=True,
        )
        rows = conn("select distinct zone, delivery from power where src=`ENTSOE", wait=True)
        zones = [str(z) for z in rows["zone"].py()]
        delivs = rows["delivery"].py()
        for z, d in zip(zones, delivs):
            _seen.add((z, d))
        print(f"{NAME}: seeded {len(_seen)} already-published points from the rdb", flush=True)
        conn.close()
    except BaseException as e:  # noqa: BLE001 - cold start is an acceptable fallback
        print(f"{NAME}: could not seed from rdb ({e}) - starting cold", flush=True)


def _fetch(zone_eic, start, end, attempts=3):
    """One A44 (day-ahead prices) request for a single bidding zone.

    ENTSO-E is flaky under load — 503s and dropped reads are routine, and both
    were observed in a single afternoon. Retries with a short backoff, and a
    timeout well above the 30s that was cutting NL and BE off mid-response.
    """
    params = {
        "securityToken": API_KEY,
        "documentType": "A44",
        "in_Domain": zone_eic,
        "out_Domain": zone_eic,
        "periodStart": start.strftime("%Y%m%d%H%M"),
        "periodEnd": end.strftime("%Y%m%d%H%M"),
    }
    url = f"{API}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": "gaz/entsoe-feed"})
    last = None
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read()
        except BaseException as e:  # noqa: BLE001 - retry any transport failure
            last = e
            if attempt + 1 < attempts:
                time.sleep(5 * (attempt + 1))
    raise last


def _parse(xml_bytes):
    """Yield (delivery, price) from a Publication_MarketDocument.

    The subtlety is curveType A03 ("variable sized block"): a position may be
    omitted, and an omitted position means *the previous price continues*, not
    that the period is missing. Real responses do contain gaps — a naive
    parser that only reads the Points present silently loses delivery periods.
    So the curve is expanded to every position up to the last one seen.
    """
    root = ET.fromstring(xml_bytes)

    # An error or an empty result comes back as a different root element.
    if not root.tag.endswith("Publication_MarketDocument"):
        reason = root.findtext(".//{*}Reason/{*}text") or root.tag
        raise RuntimeError(f"unexpected response: {reason}")

    for period in root.findall(".//p:Period", NS):
        start_text = period.findtext("p:timeInterval/p:start", namespaces=NS)
        resolution = period.findtext("p:resolution", namespaces=NS)
        step = RESOLUTION_MINUTES.get(resolution)
        if step is None:
            raise RuntimeError(f"unhandled resolution {resolution}")

        start = dt.datetime.strptime(start_text, "%Y-%m-%dT%H:%MZ")

        points = {}
        for pt in period.findall("p:Point", NS):
            pos = int(pt.findtext("p:position", namespaces=NS))
            points[pos] = float(pt.findtext("p:price.amount", namespaces=NS))

        if not points:
            continue

        last = None
        for pos in range(1, max(points) + 1):
            last = points.get(pos, last)   # carry forward across gaps
            if last is None:
                continue
            yield start + dt.timedelta(minutes=step * (pos - 1)), last


def make_batch():
    """Collect every unseen (zone, delivery) price across all zones."""
    if not API_KEY:
        raise RuntimeError("ENTSOE_API_KEY is not set")

    now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    # Yesterday through the day after tomorrow: wide enough to pick up
    # tomorrow's curve the moment it is published, and to backfill on restart.
    start = (now - dt.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + dt.timedelta(days=3)

    zones, deliveries, prices = [], [], []
    for zone, eic in ZONES.items():
        try:
            for delivery, price in _parse(_fetch(eic, start, end)):
                key = (zone, delivery)
                if key in _seen:
                    continue
                _seen.add(key)
                zones.append(zone)
                deliveries.append(delivery)
                prices.append(price)
        except BaseException as e:  # noqa: BLE001 - one bad zone must not stop the rest
            print(f"{NAME}: {zone} failed: {e}", flush=True)

    _prune(now)

    if not zones:
        return None

    print(f"{NAME}: publishing {len(zones)} new price points", flush=True)
    return (
        gf.SymbolVector(zones),
        gf.TimestampVector(deliveries),
        gf.FloatVector(prices),
        gf.SymbolVector(["ENTSOE"] * len(zones)),
    )


def _prune(now):
    cutoff = now - dt.timedelta(days=4)
    stale = [k for k in _seen if k[1] < cutoff]
    for k in stale:
        _seen.discard(k)


if __name__ == "__main__":
    if not API_KEY:
        print(f"{NAME}: ENTSOE_API_KEY is not set — refusing to start", flush=True)
        sys.exit(1)
    _seed_from_rdb()
    gf.run(NAME, TABLE, INTERVAL, make_batch)
