#!/usr/bin/env python3
"""Simulated TTF gas feed.

Unlike power, this one has no free real-time replacement waiting. ENTSO-E is
power-only; EPEX/EEX charge from EUR 1,040/month for day-ahead read-only; the
free TTF sources are either trial keys or monthly-resolution history via
FRED/IMF. So this handler is the source, not a placeholder — swap it for a
replay of recorded prices if you want determinism in a demo.

Gas moves far less than power intraday, and slower, which is exactly why the
spread needs an as-of join rather than a plain join on time.
"""

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gazfeed as gf  # noqa: E402 - path must be set first

NAME = "sim_gas"
TABLE = "gas"

# Slower than power and not a multiple of it: the three cadences are
# deliberately unrelated so the as-of join has real work to do.
INTERVAL = float(os.environ.get("GAZ_GAS_INTERVAL", "4.3"))

HUBS = ["TTF", "NBP"]

# EUR/MWh. TTF is the European benchmark the spark spread is quoted against;
# NBP carried here mostly to prove the table handles more than one hub.
LEVEL = {"TTF": 32.0, "NBP": 30.5}
price = dict(LEVEL)


def make_batch():
    for h in HUBS:
        price[h] += 0.03 * (LEVEL[h] - price[h]) + random.gauss(0, 0.12)

    return (
        gf.SymbolVector(HUBS),
        gf.FloatVector([round(price[h], 3) for h in HUBS]),
        gf.SymbolVector(["SIM"] * len(HUBS)),
    )


if __name__ == "__main__":
    gf.run(NAME, TABLE, INTERVAL, make_batch)
