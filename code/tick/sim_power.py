#!/usr/bin/env python3
"""Simulated power price feed — the slot the ENTSO-E adapter replaces.

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
INTERVAL = float(os.environ.get("GAZ_POWER_INTERVAL", "1.7"))

# ENTSO-E bidding-zone names, so the real adapter maps straight onto these.
ZONES = ["DE_LU", "FR", "NL", "BE"]

# EUR/MWh. Plausible mid-2026 European day-ahead levels; France sits lower on
# nuclear availability, DE_LU carries more renewable-driven variance.
LEVEL = {"DE_LU": 92.0, "FR": 78.0, "NL": 95.0, "BE": 97.0}
price = dict(LEVEL)


def make_batch():
    """One tick per zone, mean-reverting around the reference level.

    Power is the most volatile of the three legs, which is what makes it the
    series the spread is computed *on* — gas and carbon are joined onto it.
    """
    n = len(ZONES)
    for z in ZONES:
        # Ornstein-Uhlenbeck-ish: pull back toward the level, plus noise.
        price[z] += 0.05 * (LEVEL[z] - price[z]) + random.gauss(0, 0.9)

    # Delivery period is the current hour. A real day-ahead feed would publish
    # tomorrow's 24 hours in one burst; the shape of the column is the same.
    hour = dt.datetime.now(dt.timezone.utc).replace(
        minute=0, second=0, microsecond=0, tzinfo=None
    )

    return (
        gf.SymbolVector(ZONES),
        gf.TimestampVector([hour] * n),
        gf.FloatVector([round(price[z], 2) for z in ZONES]),
        gf.SymbolVector(["SIM"] * n),
    )


if __name__ == "__main__":
    gf.run(NAME, TABLE, INTERVAL, make_batch)
