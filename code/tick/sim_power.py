#!/usr/bin/env python3
"""Simulated power price feed — fallback for when ENTSO-E is unavailable.

Runs ALONGSIDE entsoe_power rather than instead of it. ENTSO-E returns 503 for
sustained periods (observed across a whole morning), and a demo that dies
because a third party is down is not much of a demo. Both publish to `power`;
`src` tells them apart, and .spread.curve prefers ENTSOE and falls back to SIM.

ENTSO-E Transparency is the real source for this table: day-ahead prices are
free there (they are the EPEX/Nord Pool auction results), unlike EPEX's own
API. It needs a security token, requested by emailing transparency@entsoe.eu
with "RESTful API access" in the subject; access is granted in a few working
days. Until then this stands in.

When the token arrives, the replacement publishes the same columns to the same
table with src=`ENTSOE, and nothing downstream changes. Two differences to
plan for: ENTSO-E returns XML rather than JSON, and day-ahead prices land once
a day for the following 24 delivery hours, so a real adapter polls slowly and
publishes a burst of `delivery` periods rather than one row at a time.
"""

import datetime as dt
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gazfeed as gf  # noqa: E402 - path must be set first

NAME = "sim_power"
TABLE = "power"

# Deliberately not a round number relative to the gas and carbon handlers: the
# three series must arrive at unrelated times for the as-of join to be doing
# real work rather than lining up by accident.
INTERVAL = float(os.environ.get("GAZ_POWER_INTERVAL", "60"))

# ENTSO-E bidding-zone names, so the real adapter maps straight onto these.
ZONES = ["DE_LU", "FR", "NL", "BE", "ES"]

# EUR/MWh. Plausible mid-2026 European day-ahead levels; France sits lower on
# nuclear availability, DE_LU carries more renewable-driven variance.
LEVEL = {"DE_LU": 92.0, "FR": 78.0, "NL": 95.0, "BE": 97.0, "ES": 84.0}
price = dict(LEVEL)


# Already-published (zone, delivery), so re-polling is a no-op — the same
# contract entsoe_power has. Without it the table fills with duplicates.
_seen = set()


def _shape(hour):
    """Crude diurnal shape: cheap overnight, morning and evening peaks.

    Enough structure that a spark spread has periods in and out of the money,
    which is the whole point of a fallback for the demo.
    """
    if 0 <= hour < 6:
        return 0.72
    if 6 <= hour < 9:
        return 1.18
    if 9 <= hour < 16:
        return 0.94
    if 16 <= hour < 21:
        return 1.30
    return 0.88


def make_batch():
    """A day-ahead style curve: 96 quarter-hours per zone, today and tomorrow.

    Mirrors what ENTSO-E delivers rather than emitting a single live tick, so
    .spread.curve gets a real curve when ENTSO-E is unreachable. Publishes each
    (zone, delivery) once, so this settles to a no-op until the date rolls.
    """
    today = dt.datetime.now(dt.timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0, tzinfo=None
    )

    zones, deliveries, prices = [], [], []
    for day in (today, today + dt.timedelta(days=1)):
        for z in ZONES:
            for q in range(96):
                delivery = day + dt.timedelta(minutes=15 * q)
                key = (z, delivery)
                if key in _seen:
                    continue
                _seen.add(key)
                px = LEVEL[z] * _shape(delivery.hour) * (1.0 + random.gauss(0, 0.06))
                zones.append(z)
                deliveries.append(delivery)
                prices.append(round(px, 2))

    # Drop anything older than a few days so the set cannot grow without bound.
    cutoff = today - dt.timedelta(days=3)
    for k in [k for k in _seen if k[1] < cutoff]:
        _seen.discard(k)

    if not zones:
        return None

    print(f"{NAME}: publishing {len(zones)} simulated price points", flush=True)
    return (
        gf.SymbolVector(zones),
        gf.TimestampVector(deliveries),
        gf.FloatVector(prices),
        gf.SymbolVector(["SIM"] * len(zones)),
    )


if __name__ == "__main__":
    gf.run(NAME, TABLE, INTERVAL, make_batch)
